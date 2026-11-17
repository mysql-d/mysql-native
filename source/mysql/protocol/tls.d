/++
Internal - TLS over the Phobos and Vibe.d sockets.

Compiled only when the application depends on `dbwire:tls`
(`version(Have_dbwire_tls)`); see `mysql.ssl`.
+/
module mysql.protocol.tls;

import mysql.protocol.sockets;
import mysql.ssl;

@safe:

version (Have_dbwire_tls):

import core.time : Duration, seconds;
import std.exception : enforce;

import dbwire.exception : DbException;
import dbwire.io.backend : IoBackend;
import dbwire.io.phobos : PhobosBackend, PhobosTransport;
import dbwire.io.transport : Transport;
import dbwire.tls : TlsContext, TlsOptions, TlsTransport;

import mysql.exceptions;

version (Have_vibe_core)
	import dbwire.io.vibecore : VibeBackend, VibeTransport;

/// How long the TLS handshake may take.
private enum handshakeTimeout = 30.seconds;

/++
The dbwire TLS options for `options`.

`preferred` and `required` don't verify the server certificate, `verifyCA`
verifies its chain but not its name, `verifyIdentity` verifies both.
+/
package(mysql) TlsOptions toTlsOptions(const SSLOptions options) pure nothrow
{
	TlsOptions result;
	result.caFile = options.ca;
	result.certFile = options.cert;
	result.keyFile = options.key;
	result.serverName = options.serverName;
	final switch (options.mode)
	{
		case SSLMode.disabled:
		case SSLMode.preferred:
		case SSLMode.required:
			result.skipVerify = true;
			break;
		case SSLMode.verifyCA:
			result.skipNameCheck = true;
			break;
		case SSLMode.verifyIdentity:
			break;
	}
	return result;
}

/++
Performs the TLS handshake over the open `socket` and returns a socket that
encrypts everything sent through it. `socket` must not be used afterwards;
closing the returned socket closes it.

Throws: `mysql.exceptions.MYX` if OpenSSL can't be loaded, a certificate or
key file can't be read, or the handshake fails (including a server
certificate that isn't accepted).
+/
package(mysql) MySQLSocket startTLS(MySQLSocket socket, string host, const SSLOptions options)
{
	const tlsOptions = toTlsOptions(options);

	Transport raw;
	IoBackend backend;
	if (auto phobos = cast(MySQLSocketPhobos) socket)
	{
		raw = new PhobosTransport(phobos.socket);
		backend = new PhobosBackend;
	}
	else
	{
		version (Have_vibe_core)
		{
			auto vibe = cast(MySQLSocketVibeD) socket;
			enforce!MYX(vibe !is null, "TLS is not supported over this socket type");
			raw = new VibeTransport(vibe.socket);
			backend = new VibeBackend;
		}
		else
			throw new MYX("TLS is not supported over this socket type");
	}

	TlsTransport tls;
	try
	{
		auto context = TlsContext.client(tlsOptions);
		tls = new TlsTransport(raw, backend, context, host, tlsOptions, handshakeTimeout);
		tls.setTimeouts(Duration.zero, Duration.zero);
	}
	catch (DbException e)
	{
		socket.close();
		throw new MYX("TLS: " ~ e.msg);
	}
	return new MySQLSocketTLS(socket, tls);
}

/// `MySQLSocket` over a TLS stream. Ownership (Vibe.d) is the plain socket's.
class MySQLSocketTLS : MySQLSocket
{
	private MySQLSocket plain;
	private TlsTransport tls;

	private this(MySQLSocket plain, TlsTransport tls)
	{
		this.plain = plain;
		this.tls = tls;
	}

	/// Sends the TLS close notification and closes the socket.
	void close()
	{
		tls.close();
	}

	/// Whether the socket is open.
	@property bool connected() const
	{
		return tls.connected;
	}

	/// Reads exactly `dst.length` bytes.
	void read(ubyte[] dst)
	{
		try
		{
			while (dst.length)
			{
				const n = tls.read(dst);
				enforce!MYX(n != 0, "Server closed the connection");
				dst = dst[n .. $];
			}
		}
		catch (DbException e)
		{
			tls.close();
			throw new MYX(e.msg);
		}
	}

	/// Writes all of `bytes`.
	void write(const scope ubyte[] bytes)
	{
		try
			tls.write(bytes);
		catch (DbException e)
		{
			tls.close();
			throw new MYX(e.msg);
		}
	}

	/// Ownership of the underlying Vibe.d connection.
	void acquire() { plain.acquire(); }
	void release() { plain.release(); } /// ditto
	bool isOwner() { return plain.isOwner(); } /// ditto
	bool amOwner() { return plain.amOwner(); } /// ditto
}

unittest
{
	SSLOptions options;
	options.ca = "ca.pem";
	options.cert = "client.pem";
	options.key = "client.key";
	options.serverName = "db.example.com";

	options.mode = SSLMode.required;
	auto t = toTlsOptions(options);
	assert(t.caFile == "ca.pem" && t.certFile == "client.pem" && t.keyFile == "client.key");
	assert(t.serverName == "db.example.com");
	assert(t.skipVerify);

	options.mode = SSLMode.verifyCA;
	t = toTlsOptions(options);
	assert(!t.skipVerify && t.skipNameCheck);

	options.mode = SSLMode.verifyIdentity;
	t = toTlsOptions(options);
	assert(!t.skipVerify && !t.skipNameCheck);
}
