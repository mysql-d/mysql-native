/++
TLS (SSL) settings for connections.

TLS support is optional: it comes from the
$(LINK2 https://code.dlang.org/packages/dbwire, dbwire:tls) package, which
mysql-native uses only when the application depends on it. Add it to your
project to enable TLS:

------------------
// dub.json
"dependencies": {
	"mysql-native": "...",
	"dbwire:tls": "~>0.6"
}
------------------

OpenSSL is loaded at run time by dbwire (`libssl` on Posix, `libssl-3-x64.dll`
and similar on Windows; on macOS Homebrew's `openssl@3`), so nothing is linked
when the application is built. If OpenSSL can't be loaded, only TLS connections
fail, with an `mysql.exceptions.MYX`.

Choose the mode with `SSLOptions.mode`, or with the `sslmode` key of a
connection string:

------------------
auto conn = new Connection("host=db.example.com;user=app;pwd=secret;db=app;sslmode=verify_identity");
------------------

Connection string keys: `sslmode` (`disabled`, `preferred`, `required`,
`verify_ca`, `verify_identity`), `sslca`, `sslcert`, `sslkey` and
`sslservername`, matching the fields of `SSLOptions`.
+/
module mysql.ssl;

import std.exception : enforce;
import std.string : toLower;

import mysql.exceptions;

@safe:

/// Whether this build of mysql-native supports TLS (it depends on `dbwire:tls`).
version (Have_dbwire_tls)
	enum bool sslSupported = true;
else
	enum bool sslSupported = false; /// ditto

/++
How a connection uses TLS. The modes have the same meaning as the MySQL
client's `--ssl-mode` option.
+/
enum SSLMode
{
	/// Never use TLS. This is the default.
	disabled,

	/++
	Use TLS when the server supports it and this build supports TLS
	(`sslSupported`); otherwise connect unencrypted. The server certificate
	isn't verified.
	+/
	preferred,

	/++
	Require TLS, without verifying the server certificate. This protects
	against eavesdropping, but not against an attacker who can impersonate
	the server.
	+/
	required,

	/// Require TLS and a server certificate signed by a trusted CA (`SSLOptions.ca`).
	verifyCA,

	/++
	Like `verifyCA`, and the certificate must also be issued for the host
	connected to (or `SSLOptions.serverName`).
	+/
	verifyIdentity,
}

/// TLS settings of a connection.
struct SSLOptions
{
	/// How the connection uses TLS.
	SSLMode mode;

	/// PEM file with the certificate authorities to trust. Empty: the system's default store.
	string ca;

	/// PEM file with the client certificate, for servers that require one (`REQUIRE X509`).
	string cert;

	/// PEM file with the client certificate's private key. Empty: taken from `cert`.
	string key;

	/++
	Name to verify the certificate against (and to send with SNI) instead of
	the host connected to, e.g. when connecting through an IP address or a
	tunnel.
	+/
	string serverName;
}

/++
Parses an `sslmode` value: `disabled`, `preferred`, `required`, `verify_ca` or
`verify_identity` (case-insensitive).

Throws: `mysql.exceptions.MYX` for any other value.
+/
SSLMode parseSSLMode(string value)
{
	switch (value.toLower)
	{
		case "disabled":
			return SSLMode.disabled;
		case "preferred":
			return SSLMode.preferred;
		case "required":
			return SSLMode.required;
		case "verify_ca":
			return SSLMode.verifyCA;
		case "verify_identity":
			return SSLMode.verifyIdentity;
		default:
			throw new MYX("Unknown sslmode '" ~ value
				~ "' (expected disabled, preferred, required, verify_ca or verify_identity)");
	}
}

///
unittest
{
	assert(parseSSLMode("disabled") == SSLMode.disabled);
	assert(parseSSLMode("PREFERRED") == SSLMode.preferred);
	assert(parseSSLMode("required") == SSLMode.required);
	assert(parseSSLMode("verify_ca") == SSLMode.verifyCA);
	assert(parseSSLMode("Verify_Identity") == SSLMode.verifyIdentity);

	import std.exception : assertThrown;
	assertThrown!MYX(parseSSLMode("on"));
}
