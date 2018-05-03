/// Internal - Phobos and vibe.d sockets.
module mysql.protocol.sockets;

import std.exception;
import std.socket;

import mysql.exceptions;

version(Have_vibe_d_core)
{
	static if(__traits(compiles, (){ import vibe.core.net; } ))
		import vibe.core.net;
	else
		static assert(false, "mysql-native can't find Vibe.d's 'vibe.core.net'.");
}

/// Phobos/Vibe.d type aliases
alias PlainPhobosSocket = std.socket.TcpSocket;
version(Have_vibe_d_core)
{
	static import vibe.core.net;
	alias PlainVibeDSocket = vibe.core.net.TCPConnection; ///ditto
}
else
{
	// Dummy types
	alias PlainVibeDSocket = Object; ///ditto
}

alias OpenSocketCallbackPhobos = PlainPhobosSocket function(string,ushort);
alias OpenSocketCallbackVibeD = PlainVibeDSocket function(string,ushort);

enum MySQLSocketType { phobos, vibed }

/// A minimal socket interface similar to Vibe.d's TCPConnection.
/// Used to wrap both Phobos and Vibe.d sockets with a common interface.
interface MySQLSocket
{
	void close();
	@property bool connected() const;
	void read(ubyte[] dst);
	void write(in ubyte[] bytes);

	void acquire();
	void release();
	bool isOwner();
	bool amOwner();
}

/// Wraps a Phobos socket with the common interface
class MySQLSocketPhobos : MySQLSocket
{
	private PlainPhobosSocket socket;

	/// The socket should already be open
	this(PlainPhobosSocket socket)
	{
		enforce!MYX(socket, "Tried to use a null Phobos socket - Maybe the 'openSocket' callback returned null?");
		enforce!MYX(socket.isAlive, "Tried to use a closed Phobos socket - Maybe the 'openSocket' callback created a socket but forgot to open it?");
		this.socket = socket;
	}

	invariant()
	{
		assert(socket !is null);
	}

	void close()
	{
		socket.shutdown(SocketShutdown.BOTH);
		socket.close();
	}

	@property bool connected() const
	{
		return socket.isAlive;
	}

	void read(ubyte[] dst)
	{
		// Note: I'm a little uncomfortable with this line as it doesn't
		// (and can't) update Connection._open. Not sure what can be done,
		// but perhaps Connection._open should be eliminated in favor of
		// querying the socket's opened/closed state directly.
		scope(failure) socket.close();

		for (size_t off, len; off < dst.length; off += len) {
			len = socket.receive(dst[off..$]);
			enforce!MYX(len != 0, "Server closed the connection");
			enforce!MYX(len != socket.ERROR, "Received std.socket.Socket.ERROR");
		}
	}

	void write(in ubyte[] bytes)
	{
		socket.send(bytes);
	}

	void acquire() { /+ Do nothing +/ }
	void release() { /+ Do nothing +/ }
	bool isOwner() { return true; }
	bool amOwner() { return true; }
}

version(Have_vibe_d_core) {
	/// Wraps a Vibe.d socket with the common interface
	class MySQLSocketVibeD : MySQLSocket
	{
		private PlainVibeDSocket socket;

		/// The socket should already be open
		this(PlainVibeDSocket socket)
		{
			enforce!MYX(socket, "Tried to use a null Vibe.d socket - Maybe the 'openSocket' callback returned null?");
			enforce!MYX(socket.connected, "Tried to use a closed Vibe.d socket - Maybe the 'openSocket' callback created a socket but forgot to open it?");
			this.socket = socket;
		}

		invariant()
		{
			// vibe-core (used by default as of vibe.d v0.8.3) changed
			// TCPConnection from an interface to a struct, so checking
			// for null is no longer needed.
			static if(is(socket == interface))
				assert(socket !is null);
		}

		void close()
		{
			socket.close();
		}

		@property bool connected() const
		{
			return socket.connected;
		}

		void read(ubyte[] dst)
		{
			socket.read(dst);
		}

		void write(in ubyte[] bytes)
		{
			socket.write(bytes);
		}

		static if (is(typeof(&TCPConnection.isOwner))) {
			void acquire() { socket.acquire(); }
			void release() { socket.release(); }
			bool isOwner() { return socket.isOwner(); }
			bool amOwner() { return socket.isOwner(); }
		} else {
			void acquire() { /+ Do nothing +/ }
			void release() { /+ Do nothing +/ }
			bool isOwner() { return true; }
			bool amOwner() { return true; }
		}
	}
}
