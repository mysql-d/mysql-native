/++
Internal - Ed25519 signatures, for MariaDB's `client_ed25519` and `parsec`
authentication.

Only what a client needs: the public key of a secret, and signing (RFC 8032,
section 5.1). Written from the RFC. The secret is hashed with SHA-512 as in
the RFC; RFC 8032 uses a 32-byte seed, MariaDB's `client_ed25519` the whole
password.

The secret scalar and the signing nonce never steer a branch or an array
index: field elements are 16 limbs of 16 bits, points are added with the
complete twisted Edwards formula, and scalars are reduced bit by bit with
masks instead of comparisons.

See_Also: $(LINK https://www.rfc-editor.org/rfc/rfc8032)
+/
module mysql.protocol.ed25519;

import std.digest.sha : SHA512;

@safe:

/++
The public key (encoded point A) for `secret`.
+/
package(mysql) ubyte[32] ed25519PublicKey(const(ubyte)[] secret)
{
	ubyte[32] scalar, prefix;
	expandSecret(secret, scalar, prefix);
	scope(exit) wipe(scalar, prefix);
	return encodePoint(scalarMultBase(scalar));
}

/++
The 64-byte signature (R, S) of `message` with the key of `secret`.
+/
package(mysql) ubyte[64] ed25519Sign(const(ubyte)[] secret, const(ubyte)[] message)
{
	ubyte[32] scalar, prefix;
	expandSecret(secret, scalar, prefix);
	scope(exit) wipe(scalar, prefix);
	const publicKey = encodePoint(scalarMultBase(scalar));

	SHA512 sha;
	sha.start();
	sha.put(prefix[]);
	sha.put(message);
	const r = reduceModL(sha.finish());
	const encodedR = encodePoint(scalarMultBase(r));

	sha.start();
	sha.put(encodedR[]);
	sha.put(publicKey[]);
	sha.put(message);
	const k = reduceModL(sha.finish());

	ubyte[64] signature;
	signature[0 .. 32] = encodedR[];
	signature[32 .. 64] = mulAddModL(k, scalar, r)[];
	return signature;
}

private:

void wipe(ref ubyte[32] scalar, ref ubyte[32] prefix) pure nothrow @nogc
{
	scalar[] = 0;
	prefix[] = 0;
}

// SHA-512 of the secret: the low half, clamped, is the scalar; the high half
// is the prefix that makes the signing nonce.
void expandSecret(const(ubyte)[] secret, ref ubyte[32] scalar, ref ubyte[32] prefix)
{
	auto h = SHA512();
	h.start();
	h.put(secret);
	auto digest = h.finish();
	scalar[] = digest[0 .. 32];
	prefix[] = digest[32 .. 64];
	digest[] = 0;
	scalar[0] &= 0xF8;
	scalar[31] &= 0x7F;
	scalar[31] |= 0x40;
}

// ---- The field GF(2^255 - 19) ----

// Element: value = sum(limb[i] * 2^(16 i)). Every operation leaves the limbs
// non-negative and below 2^16 + 38, so products fit easily in a long.
alias Fe = long[16];

// 2^256 = 2 * 2^255 = 2 * 19 (mod p)
enum long wrap = 38;

// 4p = 2^257 - 76, as limbs of at least 2^17 - 76: added before subtracting so
// that no limb goes negative.
static immutable Fe fourP = () {
	Fe f;
	f[0] = (1L << 17) - 76;
	foreach (i; 1 .. 16)
		f[i] = (1L << 17) - 2;
	return f;
}();

Fe feFromBytes(const(ubyte)[] b) pure nothrow @nogc
in
{
	assert(b.length == 32);
}
do
{
	Fe f;
	foreach (i; 0 .. 16)
		f[i] = b[2 * i] | (long(b[2 * i + 1]) << 8);
	f[15] &= 0x7FFF;
	return f;
}

// 64 lowercase hex digits as 32 bytes (for the constants, at compile time).
ubyte[32] hexBytes(string hex) pure nothrow @nogc
{
	static ubyte digit(char c) pure nothrow @nogc
	{
		return cast(ubyte)(c <= '9' ? c - '0' : c - 'a' + 10);
	}

	ubyte[32] b;
	foreach (i; 0 .. 32)
		b[i] = cast(ubyte)((digit(hex[2 * i]) << 4) | digit(hex[2 * i + 1]));
	return b;
}

// Constants, little-endian: 2d with d = -121665/121666, and the base point B
// (y = 4/5, x even).
static immutable Fe d2 = feFromBytes(hexBytes("59f1b226949bd6eb56b183829a14e00030d1f3eef2808e19e7fcdf56dcd90624"));
static immutable Fe baseX = feFromBytes(hexBytes("1ad5258f602d56c9b2a7259560c72c695cdcd6fd31e2a4c0fe536ecdd3366921"));
static immutable Fe baseY = feFromBytes(hexBytes("5866666666666666666666666666666666666666666666666666666666666666"));

// Moves each limb's excess into the next one, the top limb's into limb 0
// (times 38). Two passes bring every limb below 2^16 + 38.
void carry(ref Fe f) pure nothrow @nogc
{
	foreach (pass; 0 .. 2)
		foreach (i; 0 .. 16)
		{
			const c = f[i] >> 16;
			f[i] &= 0xFFFF;
			if (i < 15)
				f[i + 1] += c;
			else
				f[0] += wrap * c;
		}
}

Fe add(const Fe a, const Fe b) pure nothrow @nogc
{
	Fe r;
	foreach (i; 0 .. 16)
		r[i] = a[i] + b[i];
	carry(r);
	return r;
}

Fe sub(const Fe a, const Fe b) pure nothrow @nogc
{
	Fe r;
	foreach (i; 0 .. 16)
		r[i] = a[i] + fourP[i] - b[i];
	carry(r);
	return r;
}

Fe mul(const Fe a, const Fe b) pure nothrow @nogc
{
	long[31] t;
	foreach (i; 0 .. 16)
		foreach (j; 0 .. 16)
			t[i + j] += a[i] * b[j];
	Fe r;
	foreach (i; 0 .. 15)
		r[i] = t[i] + wrap * t[i + 16];
	r[15] = t[15];
	carry(r);
	return r;
}

// a^(p - 2) = 1/a. The exponent 2^255 - 21 is public: its bits are all set
// except bits 2 and 4.
Fe invert(const Fe a) pure nothrow @nogc
{
	Fe r = a;
	foreach_reverse (bit; 0 .. 254)
	{
		r = mul(r, r);
		if (bit != 2 && bit != 4)
			r = mul(r, a);
	}
	return r;
}

// The canonical (fully reduced) little-endian encoding.
ubyte[32] feToBytes(const Fe a) pure nothrow @nogc
{
	Fe f = a;
	carry(f);
	// the value is below 2^256 + 38 < 3p: subtract p up to twice
	foreach (round; 0 .. 2)
	{
		Fe m;
		long c;
		foreach (i; 0 .. 16)
		{
			const pLimb = i == 0 ? 0xFFED : i == 15 ? 0x7FFF : 0xFFFF;
			m[i] = f[i] - pLimb + c;
			c = m[i] >> 16;
			m[i] &= 0xFFFF;
		}
		// c is -1 when f < p (keep f), else 0 (take f - p)
		const keep = c;
		foreach (i; 0 .. 16)
			f[i] = (f[i] & keep) | (m[i] & ~keep);
	}
	// limb 0 may still hold a carry when f was kept
	foreach (i; 0 .. 15)
	{
		f[i + 1] += f[i] >> 16;
		f[i] &= 0xFFFF;
	}
	ubyte[32] b;
	foreach (i; 0 .. 16)
	{
		b[2 * i] = cast(ubyte) f[i];
		b[2 * i + 1] = cast(ubyte)(f[i] >> 8);
	}
	return b;
}

// ---- Points, extended coordinates (X : Y : Z : T), x = X/Z, y = Y/Z, xy = T/Z ----

struct Point
{
	Fe x, y, z, t;
}

Point identity() pure nothrow @nogc
{
	Point p;
	p.y[0] = 1;
	p.z[0] = 1;
	return p;
}

Point basePoint() pure nothrow @nogc
{
	Point p;
	p.x = baseX;
	p.y = baseY;
	p.z[0] = 1;
	p.t = mul(baseX, baseY);
	return p;
}

// RFC 8032, section 5.1.4. Complete: also right for p == q.
Point addPoints(const Point p, const Point q) pure nothrow @nogc
{
	const a = mul(sub(p.y, p.x), sub(q.y, q.x));
	const b = mul(add(p.y, p.x), add(q.y, q.x));
	const c = mul(mul(p.t, d2), q.t);
	const zz = mul(p.z, q.z);
	const d = add(zz, zz);
	const e = sub(b, a);
	const f = sub(d, c);
	const g = add(d, c);
	const h = add(b, a);
	Point r;
	r.x = mul(e, f);
	r.y = mul(g, h);
	r.t = mul(e, h);
	r.z = mul(f, g);
	return r;
}

// p = q when mask is all ones, unchanged when it is zero.
void select(ref Point p, const Point q, long mask) pure nothrow @nogc
{
	foreach (i; 0 .. 16)
	{
		p.x[i] ^= mask & (p.x[i] ^ q.x[i]);
		p.y[i] ^= mask & (p.y[i] ^ q.y[i]);
		p.z[i] ^= mask & (p.z[i] ^ q.z[i]);
		p.t[i] ^= mask & (p.t[i] ^ q.t[i]);
	}
}

// scalar * B, scalar little-endian: double, add, and keep the sum or not
// with a mask, for every bit.
Point scalarMultBase(const ubyte[32] scalar) pure nothrow @nogc
{
	const b = basePoint();
	Point q = identity();
	foreach_reverse (bit; 0 .. 256)
	{
		q = addPoints(q, q);
		const sum = addPoints(q, b);
		select(q, sum, -long((scalar[bit >> 3] >> (bit & 7)) & 1));
	}
	return q;
}

// y, with the low bit of x in the top bit.
ubyte[32] encodePoint(const Point p) pure nothrow @nogc
{
	const zInverse = invert(p.z);
	const x = feToBytes(mul(p.x, zInverse));
	auto encoded = feToBytes(mul(p.y, zInverse));
	encoded[31] |= cast(ubyte)((x[0] & 1) << 7);
	return encoded;
}

// ---- Scalars modulo L = 2^252 + 27742317777372353535851937790883648493 ----

// Numbers of up to 544 bits, 32-bit words, little-endian.
enum wideWords = 17;
alias Wide = ulong[wideWords];

static immutable ubyte[32] orderL = hexBytes("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");

Wide toWide(const(ubyte)[] bytes) pure nothrow @nogc
{
	Wide w;
	foreach (i, b; bytes)
		w[i / 4] |= ulong(b) << (8 * (i % 4));
	return w;
}

// x mod L for x < 2^512: subtract L * 2^s, for s from 259 down to 0, whenever
// that doesn't go below zero.
ubyte[32] reduceWide(ref Wide x) pure nothrow @nogc
{
	enum topShift = 512 - 253;
	Wide shifted = toWide(orderL[]);
	// shifted = L << topShift
	foreach (s; 0 .. topShift)
		shiftLeft(shifted);
	foreach (s; 0 .. topShift + 1)
	{
		Wide difference;
		long borrow;
		foreach (i; 0 .. wideWords)
		{
			const v = cast(long) x[i] - cast(long) shifted[i] + borrow;
			difference[i] = v & 0xFFFF_FFFF;
			borrow = v >> 32;
		}
		// borrow is -1 if x < shifted (keep x), else 0 (take the difference)
		const keep = cast(ulong) borrow;
		foreach (i; 0 .. wideWords)
			x[i] = (x[i] & keep) | (difference[i] & ~keep);
		shiftRight(shifted);
	}
	ubyte[32] result;
	foreach (i; 0 .. 32)
		result[i] = cast(ubyte)(x[i / 4] >> (8 * (i % 4)));
	return result;
}

void shiftLeft(ref Wide w) pure nothrow @nogc
{
	foreach_reverse (i; 0 .. wideWords)
		w[i] = ((w[i] << 1) | (i > 0 ? w[i - 1] >> 31 : 0)) & 0xFFFF_FFFF;
}

void shiftRight(ref Wide w) pure nothrow @nogc
{
	foreach (i; 0 .. wideWords)
		w[i] = ((w[i] >> 1) | (i + 1 < wideWords ? w[i + 1] << 31 : 0)) & 0xFFFF_FFFF;
}

ubyte[32] reduceModL(const ubyte[64] value) pure nothrow @nogc
{
	auto w = toWide(value[]);
	return reduceWide(w);
}

// (k * a + r) mod L, with k and r already below L and a below 2^255.
ubyte[32] mulAddModL(const ubyte[32] k, const ubyte[32] a, const ubyte[32] r) pure nothrow @nogc
{
	const kw = toWide(k[]);
	const aw = toWide(a[]);
	Wide x = toWide(r[]);
	foreach (i; 0 .. 8)
	{
		ulong c;
		foreach (j; 0 .. 8)
		{
			const v = x[i + j] + kw[i] * aw[j] + c;
			x[i + j] = v & 0xFFFF_FFFF;
			c = v >> 32;
		}
		foreach (j; i + 8 .. wideWords)
		{
			const v = x[j] + c;
			x[j] = v & 0xFFFF_FFFF;
			c = v >> 32;
		}
	}
	return reduceWide(x);
}

version (unittest) ubyte[] unhex(string hex) pure nothrow
{
	static ubyte digit(char c) pure nothrow
	{
		return cast(ubyte)(c <= '9' ? c - '0' : c - 'a' + 10);
	}

	auto b = new ubyte[hex.length / 2];
	foreach (i, ref v; b)
		v = cast(ubyte)((digit(hex[2 * i]) << 4) | digit(hex[2 * i + 1]));
	return b;
}

// RFC 8032, section 7.1, tests 1 to 3 (seed, public key, message, signature).
unittest
{
	static immutable string[4][3] vectors = [
		["9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
			"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
			"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
			~ "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"],
		["4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
			"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
			"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
			~ "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"],
		["c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
			"fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
			"6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
			~ "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"],
	];
	foreach (v; vectors)
	{
		const seed = unhex(v[0]);
		assert(ed25519PublicKey(seed)[] == unhex(v[1]));
		assert(ed25519Sign(seed, unhex(v[2]))[] == unhex(v[3]));
	}
}

// Field and scalar edge cases.
unittest
{
	// p - 1 + 1 encodes as 0; p + 5 as 5
	Fe pMinus1 = feFromBytes(hexBytes("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"));
	Fe one;
	one[0] = 1;
	assert(feToBytes(add(pMinus1, one)) == (ubyte[32]).init);
	Fe six;
	six[0] = 6;
	auto five = feToBytes(add(pMinus1, six));
	assert(five[0] == 5 && five[1 .. $] == (ubyte[31]).init);
	// 0 - 1 = p - 1
	Fe zero;
	assert(feToBytes(sub(zero, one))[] == hexBytes("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")[]);
	// a * 1/a = 1
	auto inv = invert(pMinus1);
	auto product = feToBytes(mul(pMinus1, inv));
	assert(product[0] == 1 && product[1 .. $] == (ubyte[31]).init);

	// L mod L = 0, (L + 1) mod L = 1, (2^512 - 1) mod L
	ubyte[64] wide;
	wide[0 .. 32] = orderL[];
	assert(reduceModL(wide) == (ubyte[32]).init);
	wide[0]++;
	auto r1 = reduceModL(wide);
	assert(r1[0] == 1 && r1[1 .. $] == (ubyte[31]).init);
	wide[] = 0xFF;
	// Python: (2**512 - 1) % L
	assert(reduceModL(wide)[] == unhex("000f9c44e31106a447938568a71b0ed065bef517d273ecce3d9a307c1b419903"));
}
