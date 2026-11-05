/++
Internal - Authentication plugins.

Implements the client side of the authentication methods ("plugins") that
MySQL and MariaDB servers ask for:

$(UL
$(LI `mysql_native_password`: the SHA-1 based method used by MySQL 5.x and
     MariaDB.)
$(LI `caching_sha2_password`: the SHA-256 based default of MySQL 8.0 and
     later. When the server has the account's password hash cached, a scramble
     is enough ("fast authentication"). Otherwise the server asks for the
     password itself ("full authentication"). Without TLS the password is
     encrypted with the server's RSA public key (RSA-OAEP with SHA-1), which
     the client asks the server for. Over TLS it goes in clear through the
     encrypted channel.)
$(LI `sha256_password`: the older SHA-256 method of MySQL 5.6 to 8.x. It
     always sends the password: in clear over TLS, otherwise encrypted with the
     server's RSA public key.)
$(LI `mysql_clear_password`: sends the password in clear, for accounts
     checked by an external service (PAM, LDAP). Allowed only over TLS.)
)

See_Also:
$(LINK https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html),
$(LINK https://dev.mysql.com/doc/dev/mysql-server/latest/page_caching_sha2_authentication_exchanges.html)
+/
module mysql.protocol.auth;

import std.digest.sha;
import std.exception : enforce;

import mysql.exceptions;

@safe:

/// Name of the `mysql_native_password` authentication plugin.
package(mysql) enum nativePasswordPlugin = "mysql_native_password";

/// Name of the `caching_sha2_password` authentication plugin.
package(mysql) enum cachingSha2Plugin = "caching_sha2_password";

/// Name of the `sha256_password` authentication plugin.
package(mysql) enum sha256Plugin = "sha256_password";

/// Name of the `mysql_clear_password` authentication plugin.
package(mysql) enum clearPasswordPlugin = "mysql_clear_password";

/// What `sha256_password` sends to ask for the server's RSA public key.
package(mysql) enum ubyte sha256RequestPublicKey = 1;

/// Bytes the client and the server exchange in `caching_sha2_password`.
package(mysql) enum CachingSha2 : ubyte
{
	requestPublicKey = 2, /// Client: send me your RSA public key.
	fastAuthSuccess = 3,  /// Server: the scramble matched the cached hash.
	performFullAuth = 4,  /// Server: send the password (encrypted, without TLS).
}

/++
Whether this client implements the authentication plugin `name`.
+/
package(mysql) bool isSupportedAuthPlugin(const(char)[] name) pure nothrow
{
	return name == nativePasswordPlugin || name == cachingSha2Plugin
		|| name == sha256Plugin || name == clearPasswordPlugin;
}

/++
The first authentication response of plugin `plugin` for `password`, given the
server's random `nonce` (the 20-byte scramble, without the trailing zero byte).
`secure` tells whether the connection is encrypted with TLS.

$(UL
$(LI `mysql_native_password`, `caching_sha2_password`: the scramble; empty
     for an empty password.)
$(LI `sha256_password`: a zero byte for an empty password, the password and
     a zero byte over TLS, otherwise a request for the server's public key.)
$(LI `mysql_clear_password`: the password and a zero byte; throws `MYX`
     without TLS.)
)
+/
package(mysql) ubyte[] authResponse(const(char)[] plugin, const(char)[] password, const(ubyte)[] nonce,
	bool secure)
{
	if (plugin == cachingSha2Plugin)
		return cachingSha2Token(password, nonce);
	if (plugin == nativePasswordPlugin)
		return nativePasswordToken(password, nonce);
	if (plugin == sha256Plugin)
	{
		if (password.length == 0)
			return [0];
		if (secure)
			return clearPassword(password);
		return [sha256RequestPublicKey];
	}
	if (plugin == clearPasswordPlugin)
	{
		enforce!MYX(secure, "The server asks for the password in clear (mysql_clear_password), "
			~ "which is allowed only over TLS (see SSLOptions)");
		return clearPassword(password);
	}
	throw new MYX("Authentication plugin '" ~ plugin.idup ~ "' is not supported");
}

/// The password followed by a zero byte, as sent in clear over TLS.
package(mysql) ubyte[] clearPassword(const(char)[] password) pure nothrow
{
	return cast(ubyte[]) password.dup ~ cast(ubyte) 0;
}

/++
`mysql_native_password`: `SHA1(password) XOR SHA1(nonce, SHA1(SHA1(password)))`.
+/
package(mysql) ubyte[] nativePasswordToken(const(char)[] password, const(ubyte)[] nonce)
{
	if (password.length == 0)
		return null;

	auto stage1 = sha1Of(cast(const(ubyte)[]) password);
	auto stage2 = sha1Of(stage1);

	SHA1 sha;
	sha.start();
	sha.put(nonce);
	sha.put(stage2[]);
	auto result = sha.finish();
	foreach (i; 0 .. result.length)
		result[i] ^= stage1[i];
	return result[].dup;
}

/++
`caching_sha2_password` scramble:
`SHA256(password) XOR SHA256(SHA256(SHA256(password)), nonce)`.
+/
package(mysql) ubyte[] cachingSha2Token(const(char)[] password, const(ubyte)[] nonce)
{
	if (password.length == 0)
		return null;

	auto stage1 = sha256Of(cast(const(ubyte)[]) password);
	auto stage2 = sha256Of(stage1);

	SHA256 sha;
	sha.start();
	sha.put(stage2[]);
	sha.put(nonce);
	auto result = sha.finish();
	foreach (i; 0 .. result.length)
		result[i] ^= stage1[i];
	return result[].dup;
}

/++
The password as `caching_sha2_password` sends it during full authentication
without TLS: `password` plus a zero byte, XORed with the repeated `nonce`, then
encrypted with the server's RSA public key `pem` (RSA-OAEP with SHA-1).
+/
package(mysql) ubyte[] encryptPassword(const(char)[] password, const(ubyte)[] nonce, const(char)[] pem)
{
	enforce!MYXProtocol(nonce.length > 0, "Empty authentication nonce");
	auto key = parsePublicKeyPem(pem);

	auto message = new ubyte[password.length + 1];
	message[0 .. password.length] = cast(const(ubyte)[]) password;
	message[$ - 1] = 0;
	foreach (i, ref b; message)
		b ^= nonce[i % nonce.length];

	ubyte[20] seed;
	secureRandom(seed[]);
	return rsaOaepSha1Encrypt(key, message, seed[]);
}

/// An RSA public key: big-endian modulus and exponent, without leading zeros.
package(mysql) struct RsaPublicKey
{
	ubyte[] modulus;  /// n
	ubyte[] exponent; /// e
}

/++
Read an RSA public key in PEM form: `-----BEGIN PUBLIC KEY-----` (X.509
SubjectPublicKeyInfo, what MySQL sends) or `-----BEGIN RSA PUBLIC KEY-----`
(PKCS #1).

Throws: `MYXProtocol` if the text is not such a key.
+/
package(mysql) RsaPublicKey parsePublicKeyPem(const(char)[] pem)
{
	import std.algorithm : countUntil, startsWith;
	import std.base64 : Base64;
	import std.string : lineSplitter, strip;

	enum spkiHeader = "-----BEGIN PUBLIC KEY-----";
	enum pkcs1Header = "-----BEGIN RSA PUBLIC KEY-----";

	bool inside, pkcs1, done;
	char[] base64;
	foreach (line; pem.lineSplitter)
	{
		auto l = line.strip;
		if (!inside)
		{
			if (l == spkiHeader || l == pkcs1Header)
			{
				inside = true;
				pkcs1 = l == pkcs1Header;
			}
		}
		else if (l.startsWith("-----END"))
		{
			done = true;
			break;
		}
		else
			base64 ~= l;
	}
	enforce!MYXProtocol(done, "The server's RSA public key is not in PEM form");

	ubyte[] der;
	try
		der = Base64.decode(base64);
	catch (Exception e)
		throw new MYXProtocol("The server's RSA public key is not valid base64", __FILE__, __LINE__);

	auto outer = DerReader(der);
	auto keySequence = outer.read(DerTag.sequence);
	if (!pkcs1)
	{
		// SubjectPublicKeyInfo: SEQUENCE { SEQUENCE { OID, params }, BIT STRING }
		auto spki = DerReader(keySequence);
		auto algorithm = DerReader(spki.read(DerTag.sequence));
		static immutable ubyte[] rsaEncryption = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01];
		enforce!MYXProtocol(algorithm.read(DerTag.objectId) == rsaEncryption,
				"The server's public key is not an RSA key");
		auto bits = spki.read(DerTag.bitString);
		enforce!MYXProtocol(bits.length > 1 && bits[0] == 0, "Malformed RSA public key");
		auto inner = DerReader(bits[1 .. $]);
		keySequence = inner.read(DerTag.sequence);
	}

	// RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER publicExponent }
	auto rsa = DerReader(keySequence);
	RsaPublicKey key;
	key.modulus = stripLeadingZeros(rsa.read(DerTag.integer)).dup;
	key.exponent = stripLeadingZeros(rsa.read(DerTag.integer)).dup;
	enforce!MYXProtocol(key.modulus.length >= 64 && key.exponent.length > 0,
			"Malformed RSA public key");
	return key;
}

/++
RSA encryption with OAEP padding, SHA-1 and MGF1-SHA-1 (RFC 8017, section
7.1.1), with an empty label. `seed` is the 20 random bytes OAEP needs.
+/
package(mysql) ubyte[] rsaOaepSha1Encrypt(in RsaPublicKey key, const(ubyte)[] message, const(ubyte)[] seed)
in
{
	assert(seed.length == 20);
}
do
{
	enum hashLength = 20;
	const k = key.modulus.length;
	enforce!MYX(k >= 2 * hashLength + 2 && message.length <= k - 2 * hashLength - 2,
			"The password is too long for the server's RSA key");

	// DB = lHash || PS (zeros) || 0x01 || M
	auto db = new ubyte[k - hashLength - 1];
	db[0 .. hashLength] = sha1Of(cast(ubyte[]) null)[];
	db[$ - message.length - 1] = 0x01;
	db[$ - message.length .. $] = message[];

	auto dbMask = mgf1Sha1(seed, db.length);
	foreach (i, ref b; db)
		b ^= dbMask[i];
	auto seedMask = mgf1Sha1(db, hashLength);
	auto maskedSeed = seed.dup;
	foreach (i, ref b; maskedSeed)
		b ^= seedMask[i];

	auto em = new ubyte[k];
	em[1 .. 1 + hashLength] = maskedSeed[];
	em[1 + hashLength .. $] = db[];
	return modPow(em, key.exponent, key.modulus);
}

/// Fills `buffer` with random bytes from the operating system's CSPRNG.
package(mysql) void secureRandom(ubyte[] buffer) @trusted
{
	if (buffer.length == 0)
		return;
	version (Windows)
	{
		enforce!MYX(BCryptGenRandom(null, buffer.ptr, cast(uint) buffer.length,
				bcryptUseSystemPreferredRng) == 0, "BCryptGenRandom failed");
	}
	else version (Posix)
	{
		import std.stdio : File;

		auto f = File("/dev/urandom", "rb");
		enforce!MYX(f.rawRead(buffer).length == buffer.length, "Cannot read /dev/urandom");
	}
	else
		static assert(false, "No secure random source for this platform");
}

private:

version (Windows)
{
	pragma(lib, "bcrypt");
	enum uint bcryptUseSystemPreferredRng = 0x00000002;
	extern (Windows) int BCryptGenRandom(void* algorithm, ubyte* buffer, uint length, uint flags) nothrow @nogc;
}

enum DerTag : ubyte
{
	integer = 0x02,
	bitString = 0x03,
	objectId = 0x06,
	sequence = 0x30,
}

// Reads DER elements one after another; every length is checked.
struct DerReader
{
	const(ubyte)[] data;

	const(ubyte)[] read(DerTag tag)
	{
		enforce!MYXProtocol(data.length >= 2 && data[0] == tag, "Malformed RSA public key");
		size_t length = data[1];
		size_t pos = 2;
		if (length & 0x80)
		{
			const n = length & 0x7F;
			enforce!MYXProtocol(n >= 1 && n <= 3 && data.length >= 2 + n, "Malformed RSA public key");
			length = 0;
			foreach (i; 0 .. n)
				length = (length << 8) | data[2 + i];
			pos = 2 + n;
		}
		enforce!MYXProtocol(data.length - pos >= length, "Malformed RSA public key");
		auto content = data[pos .. pos + length];
		data = data[pos + length .. $];
		return content;
	}
}

const(ubyte)[] stripLeadingZeros(const(ubyte)[] value) pure nothrow
{
	while (value.length > 1 && value[0] == 0)
		value = value[1 .. $];
	return value;
}

// MGF1 with SHA-1 (RFC 8017, appendix B.2.1).
ubyte[] mgf1Sha1(const(ubyte)[] seed, size_t length)
{
	ubyte[] mask;
	mask.reserve(length + 20);
	for (uint counter = 0; mask.length < length; counter++)
	{
		ubyte[4] c = [cast(ubyte)(counter >> 24), cast(ubyte)(counter >> 16),
			cast(ubyte)(counter >> 8), cast(ubyte) counter];
		SHA1 sha;
		sha.start();
		sha.put(seed);
		sha.put(c[]);
		mask ~= sha.finish()[];
	}
	return mask[0 .. length];
}

// base ^^ exponent mod modulus, all big-endian; the result has modulus.length bytes.
ubyte[] modPow(const(ubyte)[] base, const(ubyte)[] exponent, const(ubyte)[] modulus) @trusted
{
	import std.bigint : BigInt;

	const m = toBigInt(modulus);
	const b = toBigInt(base) % m;
	BigInt r = 1;
	foreach (byteValue; exponent)
		foreach_reverse (bit; 0 .. 8)
		{
			r = (r * r) % m;
			if ((byteValue >> bit) & 1)
				r = (r * b) % m;
		}
	return fromBigInt(r, modulus.length);
}

auto toBigInt(const(ubyte)[] bytes) @trusted
{
	import std.bigint : BigInt;

	static immutable hexDigits = "0123456789abcdef";
	auto hex = new char[2 + 2 * bytes.length + 1];
	hex[0 .. 3] = "0x0";
	foreach (i, b; bytes)
	{
		hex[3 + 2 * i] = hexDigits[b >> 4];
		hex[4 + 2 * i] = hexDigits[b & 0xF];
	}
	return BigInt(hex);
}

ubyte[] fromBigInt(T)(const T value, size_t length) @trusted
{
	import std.array : replace;
	import std.format : format;

	// BigInt groups its hex digits with underscores
	auto hex = format("%x", value).replace("_", "");
	if (hex.length % 2)
		hex = "0" ~ hex;
	enforce!MYX(hex.length / 2 <= length, "RSA result longer than the modulus");
	auto result = new ubyte[length];
	const offset = length - hex.length / 2;
	foreach (i; 0 .. hex.length / 2)
		result[offset + i] = cast(ubyte)((hexValue(hex[2 * i]) << 4) | hexValue(hex[2 * i + 1]));
	return result;
}

uint hexValue(char c) pure nothrow
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return c - 'A' + 10;
}

// Values from Python: hashlib.sha1 / hashlib.sha256 over the same inputs.
unittest
{
	import std.digest : toHexString, LetterCase;

	const ubyte[] nonce = cast(const(ubyte)[]) "abcdefghij0123456789";
	assert(nativePasswordToken("", nonce) is null);
	assert(cachingSha2Token("", nonce) is null);
	assert(toHexString!(LetterCase.lower)(nativePasswordToken("secret", nonce))
			== "99db25ccb2a625f0e7cf4ce2e895ef9609dfe5e4");
	assert(toHexString!(LetterCase.lower)(cachingSha2Token("secret", nonce))
			== "bd7d89fc1c297010da753d08822e9e48d3eafbb6e68e1f9b403be12dc5687a40");
	assert(isSupportedAuthPlugin("caching_sha2_password"));
	assert(!isSupportedAuthPlugin("client_ed25519"));
}

// First responses of sha256_password and mysql_clear_password
unittest
{
	import std.exception : assertThrown;

	auto nonce = cast(const(ubyte)[]) "abcdefghij0123456789";
	assert(isSupportedAuthPlugin("sha256_password") && isSupportedAuthPlugin("mysql_clear_password"));

	// The scramble plugins don't depend on TLS
	assert(authResponse(cachingSha2Plugin, "secret", nonce, true) == cachingSha2Token("secret", nonce));
	assert(authResponse(nativePasswordPlugin, "secret", nonce, true) == nativePasswordToken("secret", nonce));

	assert(authResponse(sha256Plugin, "", nonce, false) == [0]);
	assert(authResponse(sha256Plugin, "", nonce, true) == [0]);
	assert(authResponse(sha256Plugin, "pw", nonce, true) == ['p', 'w', 0]);
	assert(authResponse(sha256Plugin, "pw", nonce, false) == [sha256RequestPublicKey]);

	assert(authResponse(clearPasswordPlugin, "pw", nonce, true) == ['p', 'w', 0]);
	assertThrown!MYX(authResponse(clearPasswordPlugin, "pw", nonce, false));
	assertThrown!MYX(authResponse("client_ed25519", "pw", nonce, true));
}

// RSA-OAEP round trip with a 1024-bit test key: encrypt, then decrypt with the
// private exponent and undo the padding.
unittest
{
	enum pem = "-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC8a+9uasQbgzCxDfG67+78vrff
WEiZ/RdPfQ3IdhrAolEHJawWbmKeRWZ2q6m1KUftAbRvLJqUuWNg71FN8NGXYzdh
hVGmoeoIm/qyXU7H8JiTHs1POv1UuJgnuwGms4jLrl7MgFIzbTtroeFUpYhbdg2h
a6LcRkULg/sPOf+vQwIDAQAB
-----END PUBLIC KEY-----
";
	enum privateExponent = "a65dff38d558769a6d81c7b82ac0f39982a443b665d4619e15776b9616822498"
		~ "ad46cc429843bb1bd857526cdc19b36b689f5abbd6fc5e591aa05a6ec58cdee1"
		~ "7101c67819db25a6732ef4fe0615dfc6f302eb04488279c6819aa8a9b3bf9158"
		~ "9a536b2fcc8d9049682eef2d919d12370e57861757c74adff1cf671cc6f31aa1";

	auto key = parsePublicKeyPem(pem);
	assert(key.modulus.length == 128);
	assert(key.exponent == [0x01, 0x00, 0x01]);

	ubyte[] d;
	foreach (i; 0 .. privateExponent.length / 2)
		d ~= cast(ubyte)((hexValue(privateExponent[2 * i]) << 4) | hexValue(privateExponent[2 * i + 1]));

	const ubyte[] message = cast(const(ubyte)[]) "password\0";
	ubyte[20] seed;
	foreach (i, ref b; seed)
		b = cast(ubyte)(i * 7 + 1);
	auto cipher = rsaOaepSha1Encrypt(key, message, seed[]);
	assert(cipher.length == 128);

	auto em = modPow(cipher, d, key.modulus);
	assert(em[0] == 0);
	auto maskedSeed = em[1 .. 21].dup;
	auto db = em[21 .. $].dup;
	auto seedMask = mgf1Sha1(db, 20);
	foreach (i, ref b; maskedSeed)
		b ^= seedMask[i];
	assert(maskedSeed == seed[]);
	auto dbMask = mgf1Sha1(maskedSeed, db.length);
	foreach (i, ref b; db)
		b ^= dbMask[i];
	assert(db[0 .. 20] == sha1Of(cast(ubyte[]) null)[]);
	size_t pos = 20;
	while (db[pos] == 0)
		pos++;
	assert(db[pos] == 1 && db[pos + 1 .. $] == message);

	// a random seed gives a different cipher text that decrypts the same way
	auto encrypted = encryptPassword("password", cast(const(ubyte)[]) "\x01\x02\x03", pem);
	assert(encrypted.length == 128 && encrypted != cipher);

	// PKCS #1 form of the same key, and rejected input
	import std.exception : assertThrown;

	auto pkcs1 = parsePublicKeyPem("-----BEGIN RSA PUBLIC KEY-----
MIGJAoGBALxr725qxBuDMLEN8brv7vy+t99YSJn9F099Dch2GsCiUQclrBZuYp5F
ZnarqbUpR+0BtG8smpS5Y2DvUU3w0ZdjN2GFUaah6gib+rJdTsfwmJMezU86/VS4
mCe7AaaziMuuXsyAUjNtO2uh4VSliFt2DaFrotxGRQuD+w85/69DAgMBAAE=
-----END RSA PUBLIC KEY-----
");
	assert(pkcs1 == key);
	assertThrown!MYXProtocol(parsePublicKeyPem("not a key"));
	assertThrown!MYXProtocol(parsePublicKeyPem("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"));
	assertThrown!MYX(rsaOaepSha1Encrypt(key, new ubyte[87], seed[]));
	rsaOaepSha1Encrypt(key, new ubyte[86], seed[]);
}
