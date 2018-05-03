/// Connect to a MySQL/MariaDB server.
module mysql.connection;

import std.algorithm;
import std.conv;
import std.exception;
import std.range;
import std.socket;
import std.string;
import std.typecons;

import mysql.commands;
import mysql.exceptions;
import mysql.prepared;
import mysql.protocol.comms;
import mysql.protocol.constants;
import mysql.protocol.packets;
import mysql.protocol.sockets;
import mysql.result;
debug(MYSQLN_TESTS)
{
	import mysql.test.common;
}

version(Have_vibe_d_core)
{
	static if(__traits(compiles, (){ import vibe.core.net; } ))
		import vibe.core.net;
	else
		static assert(false, "mysql-native can't find Vibe.d's 'vibe.core.net'.");
}

/// The default `mysql.protocol.constants.SvrCapFlags` used when creating a connection.
immutable SvrCapFlags defaultClientFlags =
		SvrCapFlags.OLD_LONG_PASSWORD | SvrCapFlags.ALL_COLUMN_FLAGS |
		SvrCapFlags.WITH_DB | SvrCapFlags.PROTOCOL41 |
		SvrCapFlags.SECURE_CONNECTION;// | SvrCapFlags.MULTI_STATEMENTS |
		//SvrCapFlags.MULTI_RESULTS;

/++
Submit an SQL command to the server to be compiled into a prepared statement.

This will automatically register the prepared statement on the provided connection.
The resulting `mysql.prepared.Prepared` can then be used freely on ANY `Connection`,
as it will automatically be registered upon its first use on other connections.
Or, pass it to `Connection.register` if you prefer eager registration.

Internally, the result of a successful outcome will be a statement handle - an ID -
for the prepared statement, a count of the parameters required for
execution of the statement, and a count of the columns that will be present
in any result set that the command generates.

The server will then proceed to send prepared statement headers,
including parameter descriptions, and result set field descriptions,
followed by an EOF packet.

Throws: `mysql.exceptions.MYX` if the server has a problem.
+/
Prepared prepare(Connection conn, const(char[]) sql)
{
	auto info = conn.registerIfNeeded(sql);
	return Prepared(sql, info.headers, info.numParams);
}

/++
This function is provided ONLY as a temporary aid in upgrading to mysql-native v2.0.0.

See `BackwardCompatPrepared` for more info.
+/
deprecated("This is provided ONLY as a temporary aid in upgrading to mysql-native v2.0.0. You should migrate from this to the Prepared-compatible exec/query overloads in 'mysql.commands'.")
BackwardCompatPrepared prepareBackwardCompat(Connection conn, const(char[]) sql)
{
	return prepareBackwardCompatImpl(conn, sql);
}

/// Allow mysql-native tests to get around the deprecation message
package BackwardCompatPrepared prepareBackwardCompatImpl(Connection conn, const(char[]) sql)
{
	return BackwardCompatPrepared(conn, prepare(conn, sql));
}

/++
Convenience function to create a prepared statement which calls a stored function.

Be careful that your `numArgs` is correct. If it isn't, you may get a
`mysql.exceptions.MYX` with a very unclear error message.

Throws: `mysql.exceptions.MYX` if the server has a problem.

Params:
	name = The name of the stored function.
	numArgs = The number of arguments the stored procedure takes.
+/
Prepared prepareFunction(Connection conn, string name, int numArgs)
{
	auto sql = "select " ~ name ~ preparedPlaceholderArgs(numArgs);
	return prepare(conn, sql);
}

///
@("prepareFunction")
debug(MYSQLN_TESTS)
unittest
{
	import mysql.test.common;
	mixin(scopedCn);

	exec(cn, `DROP FUNCTION IF EXISTS hello`);
	exec(cn, `
		CREATE FUNCTION hello (s CHAR(20))
		RETURNS CHAR(50) DETERMINISTIC
		RETURN CONCAT('Hello ',s,'!')
	`);

	auto preparedHello = prepareFunction(cn, "hello", 1);
	preparedHello.setArgs("World");
	auto rs = cn.query(preparedHello).array;
	assert(rs.length == 1);
	assert(rs[0][0] == "Hello World!");
}

/++
Convenience function to create a prepared statement which calls a stored procedure.

OUT parameters are currently not supported. It should generally be
possible with MySQL to present them as a result set.

Be careful that your `numArgs` is correct. If it isn't, you may get a
`mysql.exceptions.MYX` with a very unclear error message.

Throws: `mysql.exceptions.MYX` if the server has a problem.

Params:
	name = The name of the stored procedure.
	numArgs = The number of arguments the stored procedure takes.

+/
Prepared prepareProcedure(Connection conn, string name, int numArgs)
{
	auto sql = "call " ~ name ~ preparedPlaceholderArgs(numArgs);
	return prepare(conn, sql);
}

///
@("prepareProcedure")
debug(MYSQLN_TESTS)
unittest
{
	import mysql.test.common;
	import mysql.test.integration;
	mixin(scopedCn);
	initBaseTestTables(cn);

	exec(cn, `DROP PROCEDURE IF EXISTS insert2`);
	exec(cn, `
		CREATE PROCEDURE insert2 (IN p1 INT, IN p2 CHAR(50))
		BEGIN
			INSERT INTO basetest (intcol, stringcol) VALUES(p1, p2);
		END
	`);

	auto preparedInsert2 = prepareProcedure(cn, "insert2", 2);
	preparedInsert2.setArgs(2001, "inserted string 1");
	cn.exec(preparedInsert2);

	auto rs = query(cn, "SELECT stringcol FROM basetest WHERE intcol=2001").array;
	assert(rs.length == 1);
	assert(rs[0][0] == "inserted string 1");
}

private string preparedPlaceholderArgs(int numArgs)
{
	auto sql = "(";
	bool comma = false;
	foreach(i; 0..numArgs)
	{
		if (comma)
			sql ~= ",?";
		else
		{
			sql ~= "?";
			comma = true;
		}
	}
	sql ~= ")";

	return sql;
}

@("preparedPlaceholderArgs")
debug(MYSQLN_TESTS)
unittest
{
	assert(preparedPlaceholderArgs(3) == "(?,?,?)");
	assert(preparedPlaceholderArgs(2) == "(?,?)");
	assert(preparedPlaceholderArgs(1) == "(?)");
	assert(preparedPlaceholderArgs(0) == "()");
}

/// Per-connection info from the server about a registered prepared statement.
package struct PreparedServerInfo
{
	/// Server's identifier for this prepared statement.
	/// Apperently, this is never 0 if it's been registered,
	/// although mysql-native no longer relies on that.
	uint statementId;

	ushort psWarnings;

	/// Number of parameters this statement takes.
	/// 
	/// This will be the same on all connections, but it's returned
	/// by the server upon registration, so it's stored here.
	ushort numParams;

	/// Prepared statement headers
	///
	/// This will be the same on all connections, but it's returned
	/// by the server upon registration, so it's stored here.
	PreparedStmtHeaders headers;
	
	/// Not actually from the server. Connection uses this to keep track
	/// of statements that should be treated as having been released.
	bool queuedForRelease = false;
}

/++
This is a wrapper over `mysql.prepared.Prepared`, provided ONLY as a
temporary aid in upgrading to mysql-native v2.0.0 and its
new connection-independent model of prepared statements. See the
$(LINK2 https://github.com/mysql-d/mysql-native/blob/master/MIGRATING_TO_V2.md, migration guide)
for more info.

In most cases, this layer shouldn't even be needed. But if you have many
lines of code making calls to exec/query the same prepared statement,
then this may be helpful.

To use this temporary compatability layer, change instances of:

---
auto stmt = conn.prepare(...);
---

to this:

---
auto stmt = conn.prepareBackwardCompat(...);
---

And then your prepared statement should work as before.

BUT DO NOT LEAVE IT LIKE THIS! Ultimately, you should update
your prepared statement code to the mysql-native v2.0.0 API, by changing
instances of:

---
stmt.exec()
stmt.query()
stmt.queryRow()
stmt.queryRowTuple(outputArgs...)
stmt.queryValue()
---

to this:

---
conn.exec(stmt)
conn.query(stmt)
conn.queryRow(stmt)
conn.queryRowTuple(stmt, outputArgs...)
conn.queryValue(stmt)
---

Both of the above syntaxes can be used with a `BackwardCompatPrepared`
(the `Connection` passed directly to `mysql.commands.exec`/`mysql.commands.query`
will override the one embedded associated with your `BackwardCompatPrepared`).

Once all of your code is updated, you can change `prepareBackwardCompat`
back to `prepare` again, and your upgrade will be complete.
+/
struct BackwardCompatPrepared
{
	import std.variant;
	
	private Connection _conn;
	Prepared _prepared;

	/// Access underlying `Prepared`
	@property Prepared prepared() { return _prepared; }

	alias _prepared this;

	/++
	This function is provided ONLY as a temporary aid in upgrading to mysql-native v2.0.0.
	
	See `BackwardCompatPrepared` for more info.
	+/
	deprecated("Change 'preparedStmt.exec()' to 'conn.exec(preparedStmt)'")
	ulong exec()
	{
		return .exec(_conn, _prepared);
	}

	///ditto
	deprecated("Change 'preparedStmt.query()' to 'conn.query(preparedStmt)'")
	ResultRange query()
	{
		return .query(_conn, _prepared);
	}

	///ditto
	deprecated("Change 'preparedStmt.queryRow()' to 'conn.queryRow(preparedStmt)'")
	Nullable!Row queryRow()
	{
		return .queryRow(_conn, _prepared);
	}

	///ditto
	deprecated("Change 'preparedStmt.queryRowTuple(outArgs...)' to 'conn.queryRowTuple(preparedStmt, outArgs...)'")
	void queryRowTuple(T...)(ref T args) if(T.length == 0 || !is(T[0] : Connection))
	{
		return .queryRowTuple(_conn, _prepared, args);
	}

	///ditto
	deprecated("Change 'preparedStmt.queryValue()' to 'conn.queryValue(preparedStmt)'")
	Nullable!Variant queryValue()
	{
		return .queryValue(_conn, _prepared);
	}
}

/++
A class representing a database connection.

If you are using Vibe.d, consider using `mysql.pool.MySQLPool` instead of
creating a new Connection directly. That will provide certain benefits,
such as reusing old connections and automatic cleanup (no need to close
the connection when done).

------------------
// Suggested usage:

{
	auto con = new Connection("host=localhost;port=3306;user=joe;pwd=pass123;db=myappsdb");
	scope(exit) con.close();

	// Use the connection
	...
}
------------------
+/
//TODO: All low-level commms should be moved into the mysql.protocol package.
class Connection
{
/+
The Connection is responsible for handshaking with the server to establish
authentication. It then passes client preferences to the server, and
subsequently is the channel for all command packets that are sent, and all
response packets received.

Uncompressed packets consist of a 4 byte header - 3 bytes of length, and one
byte as a packet number. Connection deals with the headers and ensures that
packet numbers are sequential.

The initial packet is sent by the server - essentially a 'hello' packet
inviting login. That packet has a sequence number of zero. That sequence
number is the incremented by client and server packets through the handshake
sequence.

After login all further sequences are initialized by the client sending a
command packet with a zero sequence number, to which the server replies with
zero or more packets with sequential sequence numbers.
+/
package:
	enum OpenState
	{
		/// We have not yet connected to the server, or have sent QUIT to the
		/// server and closed the connection
		notConnected,
		/// We have connected to the server and parsed the greeting, but not
		/// yet authenticated
		connected,
		/// We have successfully authenticated against the server, and need to
		/// send QUIT to the server when closing the connection
		authenticated
	}
	OpenState   _open;
	MySQLSocket _socket;

	SvrCapFlags _sCaps, _cCaps;
	uint    _sThread;
	ushort  _serverStatus;
	ubyte   _sCharSet, _protocol;
	string  _serverVersion;

	string _host, _user, _pwd, _db;
	ushort _port;

	MySQLSocketType _socketType;

	OpenSocketCallbackPhobos _openSocketPhobos;
	OpenSocketCallbackVibeD  _openSocketVibeD;

	ulong _insertID;

	// This gets incremented every time a command is issued or results are purged,
	// so a ResultRange can tell whether it's been invalidated.
	ulong _lastCommandID;

	// Whether there are rows, headers or bimary data waiting to be retreived.
	// MySQL protocol doesn't permit performing any other action until all
	// such data is read.
	bool _rowsPending, _headersPending, _binaryPending;

	// Field count of last performed command.
	//TODO: Does Connection need to store this?
	ushort _fieldCount;

	// ResultSetHeaders of last performed command.
	//TODO: Does Connection need to store this? Is this even used?
	ResultSetHeaders _rsh;

	// This tiny thing here is pretty critical. Pay great attention to it's maintenance, otherwise
	// you'll get the dreaded "packet out of order" message. It, and the socket connection are
	// the reason why most other objects require a connection object for their construction.
	ubyte _cpn; /// Packet Number in packet header. Serial number to ensure correct
				/// ordering. First packet should have 0
	@property ubyte pktNumber()   { return _cpn; }
	void bumpPacket()       { _cpn++; }
	void resetPacket()      { _cpn = 0; }

	version(Have_vibe_d_core) {} else
	pure const nothrow invariant()
	{
		assert(_socketType != MySQLSocketType.vibed);
	}

	static PlainPhobosSocket defaultOpenSocketPhobos(string host, ushort port)
	{
		auto s = new PlainPhobosSocket();
		s.connect(new InternetAddress(host, port));
		return s;
	}

	static PlainVibeDSocket defaultOpenSocketVibeD(string host, ushort port)
	{
		version(Have_vibe_d_core)
			return vibe.core.net.connectTCP(host, port);
		else
			assert(0);
	}

	void initConnection()
	{
		kill(); // Ensure internal state gets reset

		resetPacket();
		final switch(_socketType)
		{
			case MySQLSocketType.phobos:
				_socket = new MySQLSocketPhobos(_openSocketPhobos(_host, _port));
				break;

			case MySQLSocketType.vibed:
				version(Have_vibe_d_core) {
					_socket = new MySQLSocketVibeD(_openSocketVibeD(_host, _port));
					break;
				} else assert(0, "Unsupported socket type. Need version Have_vibe_d_core.");
		}
	}

	SvrCapFlags _clientCapabilities;

	void connect(SvrCapFlags clientCapabilities)
	out
	{
		assert(_open == OpenState.authenticated);
	}
	body
	{
		initConnection();
		auto greeting = this.parseGreeting();
		_open = OpenState.connected;

		_clientCapabilities = clientCapabilities;
		_cCaps = setClientFlags(_sCaps, clientCapabilities);
		this.authenticate(greeting);
	}
	
	/++
	Forcefully close the socket without sending the quit command.
	
	Also resets internal state regardless of whether the connection is open or not.
	
	Needed in case an error leaves communatations in an undefined or non-recoverable state.
	+/
	void kill()
	{
		if(_socket && _socket.connected)
			_socket.close();
		_open = OpenState.notConnected;
		// any pending data is gone. Any statements to release will be released
		// on the server automatically.
		_headersPending = _rowsPending = _binaryPending = false;

		preparedRegistrations.clear();

		_lastCommandID++; // Invalidate result sets
	}
	
	/// Called whenever mysql-native needs to send a command to the server
	/// and be sure there aren't any pending results (which would prevent
	/// a new command from being sent).
	void autoPurge()
	{
		// This is called every time a command is sent,
		// so detect & prevent infinite recursion.
		static bool isAutoPurging = false;

		if(isAutoPurging)
			return;
			
		isAutoPurging = true;
		scope(exit) isAutoPurging = false;

		try
		{
			purgeResult();
			releaseQueued();
		}
		catch(Exception e)
		{
			// Likely the connection was closed, so reset any state (and force-close if needed).
			// Don't treat this as a real error, because everything will be reset when we
			// reconnect.
			kill();
		}
	}

	/// Lookup per-connection prepared statement info by SQL
	private PreparedRegistrations!PreparedServerInfo preparedRegistrations;

	/// Releases all prepared statements that are queued for release.
	void releaseQueued()
	{
		foreach(sql, info; preparedRegistrations.directLookup)
		if(info.queuedForRelease)
		{
			immediateReleasePrepared(this, info.statementId);
			preparedRegistrations.directLookup.remove(sql);
		}
	}

	/// Returns null if not found
	Nullable!PreparedServerInfo getPreparedServerInfo(const(char[]) sql) pure nothrow
	{
		return preparedRegistrations[sql];
	}

	/// If already registered, simply returns the cached `PreparedServerInfo`.
	PreparedServerInfo registerIfNeeded(const(char[]) sql)
	{
		return preparedRegistrations.registerIfNeeded(sql, sql => performRegister(this, sql));
	}

public:

	/++
	Construct opened connection.

	Throws `mysql.exceptions.MYX` upon failure to connect.
	
	If you are using Vibe.d, consider using `mysql.pool.MySQLPool` instead of
	creating a new Connection directly. That will provide certain benefits,
	such as reusing old connections and automatic cleanup (no need to close
	the connection when done).

	------------------
	// Suggested usage:

	{
	    auto con = new Connection("host=localhost;port=3306;user=joe;pwd=pass123;db=myappsdb");
	    scope(exit) con.close();

	    // Use the connection
	    ...
	}
	------------------

	Params:
		cs = A connection string of the form "host=localhost;user=user;pwd=password;db=mysqld"
			(TODO: The connection string needs work to allow for semicolons in its parts!)
		socketType = Whether to use a Phobos or Vibe.d socket. Default is Phobos,
			unless compiled with `-version=Have_vibe_d_core` (set automatically
			if using $(LINK2 http://code.dlang.org/getting_started, DUB)).
		openSocket = Optional callback which should return a newly-opened Phobos
			or Vibe.d TCP socket. This allows custom sockets to be used,
			subclassed from Phobos's or Vibe.d's sockets.
		host = An IP address in numeric dotted form, or as a host  name.
		user = The user name to authenticate.
		password = User's password.
		db = Desired initial database.
		capFlags = The set of flag bits from the server's capabilities that the client requires
	+/
	//After the connection is created, and the initial invitation is received from the server
	//client preferences can be set, and authentication can then be attempted.
	this(string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		version(Have_vibe_d_core)
			enum defaultSocketType = MySQLSocketType.vibed;
		else
			enum defaultSocketType = MySQLSocketType.phobos;

		this(defaultSocketType, host, user, pwd, db, port, capFlags);
	}

	///ditto
	this(MySQLSocketType socketType, string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		version(Have_vibe_d_core) {} else
			enforce!MYX(socketType != MySQLSocketType.vibed, "Cannot use Vibe.d sockets without -version=Have_vibe_d_core");

		this(socketType, &defaultOpenSocketPhobos, &defaultOpenSocketVibeD,
			host, user, pwd, db, port, capFlags);
	}

	///ditto
	this(OpenSocketCallbackPhobos openSocket,
		string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		this(MySQLSocketType.phobos, openSocket, null, host, user, pwd, db, port, capFlags);
	}

	version(Have_vibe_d_core)
	///ditto
	this(OpenSocketCallbackVibeD openSocket,
		string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	{
		this(MySQLSocketType.vibed, null, openSocket, host, user, pwd, db, port, capFlags);
	}

	///ditto
	private this(MySQLSocketType socketType,
		OpenSocketCallbackPhobos openSocketPhobos, OpenSocketCallbackVibeD openSocketVibeD,
		string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
	in
	{
		final switch(socketType)
		{
			case MySQLSocketType.phobos: assert(openSocketPhobos !is null); break;
			case MySQLSocketType.vibed:  assert(openSocketVibeD  !is null); break;
		}
	}
	body
	{
		enforce!MYX(capFlags & SvrCapFlags.PROTOCOL41, "This client only supports protocol v4.1");
		enforce!MYX(capFlags & SvrCapFlags.SECURE_CONNECTION, "This client only supports protocol v4.1 connection");
		version(Have_vibe_d_core) {} else
			enforce!MYX(socketType != MySQLSocketType.vibed, "Cannot use Vibe.d sockets without -version=Have_vibe_d_core");

		_socketType = socketType;
		_host = host;
		_user = user;
		_pwd = pwd;
		_db = db;
		_port = port;

		_openSocketPhobos = openSocketPhobos;
		_openSocketVibeD  = openSocketVibeD;

		connect(capFlags);
	}

	///ditto
	//After the connection is created, and the initial invitation is received from the server
	//client preferences can be set, and authentication can then be attempted.
	this(string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	///ditto
	this(MySQLSocketType socketType, string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(socketType, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	///ditto
	this(OpenSocketCallbackPhobos openSocket, string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(openSocket, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	version(Have_vibe_d_core)
	///ditto
	this(OpenSocketCallbackVibeD openSocket, string cs, SvrCapFlags capFlags = defaultClientFlags)
	{
		string[] a = parseConnectionString(cs);
		this(openSocket, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
	}

	/++
	Check whether this `Connection` is still connected to the server, or if
	the connection has been closed.
	+/
	@property bool closed()
	{
		return _open == OpenState.notConnected || !_socket.connected;
	}

	/++
	Explicitly close the connection.
	
	Idiomatic use as follows is suggested:
	------------------
	{
	    auto con = new Connection("localhost:user:password:mysqld");
	    scope(exit) con.close();
	    // Use the connection
	    ...
	}
	------------------
	+/
	void close()
	{
		// This is a two-stage process. First tell the server we are quitting this
		// connection, and then close the socket.

		if (_open == OpenState.authenticated && _socket.connected)
			quit();

		if (_open == OpenState.connected)
			kill();
		resetPacket();
	}

	/++
	Reconnects to the server using the same connection settings originally
	used to create the `Connection`.

	Optionally takes a `mysql.protocol.constants.SvrCapFlags`, allowing you to
	reconnect using a different set of server capability flags.

	Normally, if the connection is already open, this will do nothing. However,
	if you request a different set of `mysql.protocol.constants.SvrCapFlags`
	then was originally used to create the `Connection`, the connection will
	be closed and then reconnected using the new `mysql.protocol.constants.SvrCapFlags`.
	+/
	void reconnect()
	{
		reconnect(_clientCapabilities);
	}

	///ditto
	void reconnect(SvrCapFlags clientCapabilities)
	{
		bool sameCaps = clientCapabilities == _clientCapabilities;
		if(!closed)
		{
			// Same caps as before?
			if(clientCapabilities == _clientCapabilities)
				return; // Nothing to do, just keep current connection

			close();
		}

		connect(clientCapabilities);
	}

	// This also serves as a regression test for #167:
	// ResultRange doesn't get invalidated upon reconnect
	@("reconnect")
	debug(MYSQLN_TESTS)
	unittest
	{
		import std.variant;
		mixin(scopedCn);
		cn.exec("DROP TABLE IF EXISTS `reconnect`");
		cn.exec("CREATE TABLE `reconnect` (a INTEGER) ENGINE=InnoDB DEFAULT CHARSET=utf8");
		cn.exec("INSERT INTO `reconnect` VALUES (1),(2),(3)");

		enum sql = "SELECT a FROM `reconnect`";

		// Sanity check
		auto rows = cn.query(sql).array;
		assert(rows[0][0] == 1);
		assert(rows[1][0] == 2);
		assert(rows[2][0] == 3);

		// Ensure reconnect keeps the same connection when it's supposed to
		auto range = cn.query(sql);
		assert(range.front[0] == 1);
		cn.reconnect();
		assert(!cn.closed); // Is open?
		assert(range.isValid); // Still valid?
		range.popFront();
		assert(range.front[0] == 2);

		// Ensure reconnect reconnects when it's supposed to
		range = cn.query(sql);
		assert(range.front[0] == 1);
		cn._clientCapabilities = ~cn._clientCapabilities; // Pretend that we're changing the clientCapabilities
		cn.reconnect(~cn._clientCapabilities);
		assert(!cn.closed); // Is open?
		assert(!range.isValid); // Was invalidated?
		cn.query(sql).array; // Connection still works?

		// Try manually reconnecting
		range = cn.query(sql);
		assert(range.front[0] == 1);
		cn.connect(cn._clientCapabilities);
		assert(!cn.closed); // Is open?
		assert(!range.isValid); // Was invalidated?
		cn.query(sql).array; // Connection still works?

		// Try manually closing and connecting
		range = cn.query(sql);
		assert(range.front[0] == 1);
		cn.close();
		assert(cn.closed); // Is closed?
		assert(!range.isValid); // Was invalidated?
		cn.connect(cn._clientCapabilities);
		assert(!cn.closed); // Is open?
		assert(!range.isValid); // Was invalidated?
		cn.query(sql).array; // Connection still works?

		// Auto-reconnect upon a command
		cn.close();
		assert(cn.closed);
		range = cn.query(sql);
		assert(!cn.closed);
		assert(range.front[0] == 1);
	}
	
	private void quit()
	in
	{
		assert(_open == OpenState.authenticated);
	}
	body
	{
		this.sendCmd(CommandType.QUIT, []);
		// No response is sent for a quit packet
		_open = OpenState.connected;
	}

	/++
	Parses a connection string of the form
	`"host=localhost;port=3306;user=joe;pwd=pass123;db=myappsdb"`

	Port is optional and defaults to 3306.

	Whitespace surrounding any name or value is automatically stripped.

	Returns a five-element array of strings in this order:
	$(UL
	$(LI [0]: host)
	$(LI [1]: user)
	$(LI [2]: pwd)
	$(LI [3]: db)
	$(LI [4]: port)
	)
	
	(TODO: The connection string needs work to allow for semicolons in its parts!)
	+/
	//TODO: Replace the return value with a proper struct.
	static string[] parseConnectionString(string cs)
	{
		string[] rv;
		rv.length = 5;
		rv[4] = "3306"; // Default port
		string[] a = split(cs, ";");
		foreach (s; a)
		{
			string[] a2 = split(s, "=");
			enforce!MYX(a2.length == 2, "Bad connection string: " ~ cs);
			string name = strip(a2[0]);
			string val = strip(a2[1]);
			switch (name)
			{
				case "host":
					rv[0] = val;
					break;
				case "user":
					rv[1] = val;
					break;
				case "pwd":
					rv[2] = val;
					break;
				case "db":
					rv[3] = val;
					break;
				case "port":
					rv[4] = val;
					break;
				default:
					throw new MYX("Bad connection string: " ~ cs, __FILE__, __LINE__);
			}
		}
		return rv;
	}

	/++
	Select a current database.
	
	Throws `mysql.exceptions.MYX` upon failure.

	Params: dbName = Name of the requested database
	+/
	void selectDB(string dbName)
	{
		this.sendCmd(CommandType.INIT_DB, dbName);
		this.getCmdResponse();
		_db = dbName;
	}

	/++
	Check the server status.
	
	Throws `mysql.exceptions.MYX` upon failure.

	Returns: An `mysql.protocol.packets.OKErrorPacket` from which server status can be determined
	+/
	OKErrorPacket pingServer()
	{
		this.sendCmd(CommandType.PING, []);
		return this.getCmdResponse();
	}

	/++
	Refresh some feature(s) of the server.
	
	Throws `mysql.exceptions.MYX` upon failure.

	Returns: An `mysql.protocol.packets.OKErrorPacket` from which server status can be determined
	+/
	OKErrorPacket refreshServer(RefreshFlags flags)
	{
		this.sendCmd(CommandType.REFRESH, [flags]);
		return this.getCmdResponse();
	}

	/++
	Flush any outstanding result set elements.
	
	When the server responds to a command that produces a result set, it
	queues the whole set of corresponding packets over the current connection.
	Before that `Connection` can embark on any new command, it must receive
	all of those packets and junk them.
	
	As of v1.1.4, this is done automatically as needed. But you can still
	call this manually to force a purge to occur when you want.

	See_Also: $(LINK http://www.mysqlperformanceblog.com/2007/07/08/mysql-net_write_timeout-vs-wait_timeout-and-protocol-notes/)
	+/
	ulong purgeResult()
	{
		return mysql.protocol.comms.purgeResult(this);
	}

	/++
	Get a textual report on the server status.
	
	(COM_STATISTICS)
	+/
	string serverStats()
	{
		return mysql.protocol.comms.serverStats(this);
	}

	/++
	Enable multiple statement commands.
	
	This can be used later if this feature was not requested in the client capability flags.
	
	Warning: This functionality is currently untested.
	
	Params: on = Boolean value to turn the capability on or off.
	+/
	//TODO: Need to test this
	void enableMultiStatements(bool on)
	{
		mysql.protocol.comms.enableMultiStatements(this, on);
	}

	/// Return the in-force protocol number.
	@property ubyte protocol() pure const nothrow { return _protocol; }
	/// Server version
	@property string serverVersion() pure const nothrow { return _serverVersion; }
	/// Server capability flags
	@property uint serverCapabilities() pure const nothrow { return _sCaps; }
	/// Server status
	@property ushort serverStatus() pure const nothrow { return _serverStatus; }
	/// Current character set
	@property ubyte charSet() pure const nothrow { return _sCharSet; }
	/// Current database
	@property string currentDB() pure const nothrow { return _db; }
	/// Socket type being used, Phobos or Vibe.d
	@property MySQLSocketType socketType() pure const nothrow { return _socketType; }

	/// After a command that inserted a row into a table with an auto-increment
	/// ID column, this method allows you to retrieve the last insert ID.
	@property ulong lastInsertID() pure const nothrow { return _insertID; }

	/// This gets incremented every time a command is issued or results are purged,
	/// so a `mysql.result.ResultRange` can tell whether it's been invalidated.
	@property ulong lastCommandID() pure const nothrow { return _lastCommandID; }

	/// Gets whether rows are pending.
	///
	/// Note, you may want `hasPending` instead.
	@property bool rowsPending() pure const nothrow { return _rowsPending; }

	/// Gets whether anything (rows, headers or binary) is pending.
	/// New commands cannot be sent on a connection while anything is pending
	/// (the pending data will automatically be purged.)
	@property bool hasPending() pure const nothrow
	{
		return _rowsPending || _headersPending || _binaryPending;
	}

	/// Gets the result header's field descriptions.
	@property FieldDescription[] resultFieldDescriptions() pure { return _rsh.fieldDescriptions; }

	/++
	Manually register a prepared statement on this connection.
	
	Does nothing if statement is already registered on this connection.
	
	Calling this is not strictly necessary, as the prepared statement will
	automatically be registered upon its first use on any `Connection`.
	This is provided for those who prefer eager registration over lazy
	for performance reasons.
	+/
	void register(Prepared prepared)
	{
		register(prepared.sql);
	}

	///ditto
	void register(const(char[]) sql)
	{
		registerIfNeeded(sql);
	}

	/++
	Manually release a prepared statement on this connection.
	
	This method tells the server that it can dispose of the information it
	holds about the current prepared statement.
	
	Calling this is not strictly necessary. The server considers prepared
	statements to be per-connection, so they'll go away when the connection
	closes anyway. This is provided in case direct control is actually needed.

	If you choose to use a reference counted struct to call this automatically,
	be aware that embedding reference counted structs inside garbage collectible
	heap objects is dangerous and should be avoided, as it can lead to various
	hidden problems, from crashes to race conditions. (See the discussion at issue
	$(LINK2 https://github.com/mysql-d/mysql-native/issues/159, #159)
	for details.) Instead, it may be better to simply avoid trying to manage
	their release at all, as it's not usually necessary. Or to periodically
	release all prepared statements, and simply allow mysql-native to
	automatically re-register them upon their next use.
	
	Notes:
	
	In actuality, the server might not immediately be told to release the
	statement (although `isRegistered` will still report `false`).
	
	This is because there could be a `mysql.result.ResultRange` with results
	still pending for retrieval, and the protocol doesn't allow sending commands
	(such as "release a prepared statement") to the server while data is pending.
	Therefore, this function may instead queue the statement to be released
	when it is safe to do so: Either the next time a result set is purged or
	the next time a command (such as `mysql.commands.query` or
	`mysql.commands.exec`) is performed (because such commands automatically
	purge any pending results).
	
	This function does NOT auto-purge because, if this is ever called from
	automatic resource management cleanup (refcounting, RAII, etc), that
	would create ugly situations where hidden, implicit behavior triggers
	an unexpected auto-purge.
	+/
	void release(Prepared prepared)
	{
		release(prepared.sql);
	}
	
	///ditto
	void release(const(char[]) sql)
	{
		//TODO: Don't queue it if nothing is pending. Just do it immediately.
		//      But need to be certain both situations are unittested.
		preparedRegistrations.queueForRelease(sql);
	}
	
	/++
	Manually release all prepared statements on this connection.
	
	While minimal, every prepared statement registered on a connection does
	use up a small amount of resources in both mysql-native and on the server.
	Additionally, servers can be configured
	$(LINK2 https://dev.mysql.com/doc/refman/5.7/en/server-system-variables.html#sysvar_max_prepared_stmt_count,
	to limit the number of prepared statements)
	allowed on a connection at one time (the default, however
	is quite high). Note also, that certain overloads of `mysql.commands.exec`,
	`mysql.commands.query`, etc. register prepared statements behind-the-scenes
	which are cached for quick re-use later.
	
	Therefore, it may occasionally be useful to clear out all prepared
	statements on a connection, together with all resources used by them (or
	at least leave the resources ready for garbage-collection). This function
	does just that.
	
	Note that this is ALWAYS COMPLETELY SAFE to call, even if you still have
	live prepared statements you intend to use again. This is safe because
	mysql-native will automatically register or re-register prepared statements
	as-needed.

	Notes:
	
	In actuality, the prepared statements might not be immediately released
	(although `isRegistered` will still report `false` for them).
	
	This is because there could be a `mysql.result.ResultRange` with results
	still pending for retrieval, and the protocol doesn't allow sending commands
	(such as "release a prepared statement") to the server while data is pending.
	Therefore, this function may instead queue the statement to be released
	when it is safe to do so: Either the next time a result set is purged or
	the next time a command (such as `mysql.commands.query` or
	`mysql.commands.exec`) is performed (because such commands automatically
	purge any pending results).
	
	This function does NOT auto-purge because, if this is ever called from
	automatic resource management cleanup (refcounting, RAII, etc), that
	would create ugly situations where hidden, implicit behavior triggers
	an unexpected auto-purge.
	+/
	void releaseAll()
	{
		preparedRegistrations.queueAllForRelease();
	}

	@("releaseAll")
	debug(MYSQLN_TESTS)
	unittest
	{
		mixin(scopedCn);
		
		cn.exec("DROP TABLE IF EXISTS `releaseAll`");
		cn.exec("CREATE TABLE `releaseAll` (a INTEGER) ENGINE=InnoDB DEFAULT CHARSET=utf8");

		auto preparedSelect = cn.prepare("SELECT * FROM `releaseAll`");
		auto preparedInsert = cn.prepare("INSERT INTO `releaseAll` (a) VALUES (1)");
		assert(cn.isRegistered(preparedSelect));
		assert(cn.isRegistered(preparedInsert));

		cn.releaseAll();
		assert(!cn.isRegistered(preparedSelect));
		assert(!cn.isRegistered(preparedInsert));
		cn.exec("INSERT INTO `releaseAll` (a) VALUES (1)");
		assert(!cn.isRegistered(preparedSelect));
		assert(!cn.isRegistered(preparedInsert));

		cn.exec(preparedInsert);
		cn.query(preparedSelect).array;
		assert(cn.isRegistered(preparedSelect));
		assert(cn.isRegistered(preparedInsert));

	}

	/// Is the given statement registered on this connection as a prepared statement?
	bool isRegistered(Prepared prepared)
	{
		return isRegistered( prepared.sql );
	}

	///ditto
	bool isRegistered(const(char[]) sql)
	{
		return isRegistered( preparedRegistrations[sql] );
	}

	///ditto
	package bool isRegistered(Nullable!PreparedServerInfo info)
	{
		return !info.isNull && !info.queuedForRelease;
	}
}

// Test register, release, isRegistered, and auto-register for prepared statements
@("autoRegistration")
debug(MYSQLN_TESTS)
unittest
{
	import mysql.connection;
	import mysql.test.common;
	
	Prepared preparedInsert;
	Prepared preparedSelect;
	immutable insertSQL = "INSERT INTO `autoRegistration` VALUES (1), (2)";
	immutable selectSQL = "SELECT `val` FROM `autoRegistration`";
	int queryTupleResult;
	
	{
		mixin(scopedCn);
		
		// Setup
		cn.exec("DROP TABLE IF EXISTS `autoRegistration`");
		cn.exec("CREATE TABLE `autoRegistration` (
			`val` INTEGER
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");

		// Initial register
		preparedInsert = cn.prepare(insertSQL);
		preparedSelect = cn.prepare(selectSQL);
		
		// Test basic register, release, isRegistered
		assert(cn.isRegistered(preparedInsert));
		assert(cn.isRegistered(preparedSelect));
		cn.release(preparedInsert);
		cn.release(preparedSelect);
		assert(!cn.isRegistered(preparedInsert));
		assert(!cn.isRegistered(preparedSelect));
		
		// Test manual re-register
		cn.register(preparedInsert);
		cn.register(preparedSelect);
		assert(cn.isRegistered(preparedInsert));
		assert(cn.isRegistered(preparedSelect));
		
		// Test double register
		cn.register(preparedInsert);
		cn.register(preparedSelect);
		assert(cn.isRegistered(preparedInsert));
		assert(cn.isRegistered(preparedSelect));

		// Test double release
		cn.release(preparedInsert);
		cn.release(preparedSelect);
		assert(!cn.isRegistered(preparedInsert));
		assert(!cn.isRegistered(preparedSelect));
		cn.release(preparedInsert);
		cn.release(preparedSelect);
		assert(!cn.isRegistered(preparedInsert));
		assert(!cn.isRegistered(preparedSelect));
	}

	// Note that at this point, both prepared statements still exist,
	// but are no longer registered on any connection. In fact, there
	// are no open connections anymore.
	
	// Test auto-register: exec
	{
		mixin(scopedCn);
	
		assert(!cn.isRegistered(preparedInsert));
		cn.exec(preparedInsert);
		assert(cn.isRegistered(preparedInsert));
	}
	
	// Test auto-register: query
	{
		mixin(scopedCn);
	
		assert(!cn.isRegistered(preparedSelect));
		cn.query(preparedSelect).each();
		assert(cn.isRegistered(preparedSelect));
	}
	
	// Test auto-register: queryRow
	{
		mixin(scopedCn);
	
		assert(!cn.isRegistered(preparedSelect));
		cn.queryRow(preparedSelect);
		assert(cn.isRegistered(preparedSelect));
	}
	
	// Test auto-register: queryRowTuple
	{
		mixin(scopedCn);
	
		assert(!cn.isRegistered(preparedSelect));
		cn.queryRowTuple(preparedSelect, queryTupleResult);
		assert(cn.isRegistered(preparedSelect));
	}
	
	// Test auto-register: queryValue
	{
		mixin(scopedCn);
	
		assert(!cn.isRegistered(preparedSelect));
		cn.queryValue(preparedSelect);
		assert(cn.isRegistered(preparedSelect));
	}
}

// An attempt to reproduce issue #81: Using mysql-native driver with no default database
// I'm unable to actually reproduce the error, though.
@("issue81")
debug(MYSQLN_TESTS)
unittest
{
	import mysql.escape;
	mixin(scopedCn);
	
	cn.exec("DROP TABLE IF EXISTS `issue81`");
	cn.exec("CREATE TABLE `issue81` (a INTEGER) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `issue81` (a) VALUES (1)");

	auto cn2 = new Connection(text("host=", cn._host, ";port=", cn._port, ";user=", cn._user, ";pwd=", cn._pwd));
	scope(exit) cn2.close();
	
	cn2.query("SELECT * FROM `"~mysqlEscape(cn._db).text~"`.`issue81`");
}

// Regression test for Issue #154:
// autoPurge can throw an exception if the socket was closed without purging
//
// This simulates a disconnect by closing the socket underneath the Connection
// object itself.
@("dropConnection")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `dropConnection`");
	cn.exec("CREATE TABLE `dropConnection` (
		`val` INTEGER
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `dropConnection` VALUES (1), (2), (3)");
	import mysql.prepared;
	{
		auto prep = cn.prepare("SELECT * FROM `dropConnection`");
		cn.query(prep);
	}
	// close the socket forcibly
	cn._socket.close();
	// this should still work (it should reconnect).
	cn.exec("DROP TABLE `dropConnection`");
}

/+
Test Prepared's ability to be safely refcount-released during a GC cycle
(ie, `Connection.release` must not allocate GC memory).

Currently disabled because it's not guaranteed to always work
(and apparently, cannot be made to work?)
For relevant discussion, see issue #159:
https://github.com/mysql-d/mysql-native/issues/159
+/
version(none)
debug(MYSQLN_TESTS)
{
	/// Proof-of-concept ref-counted Prepared wrapper, just for testing,
	/// not really intended for actual use.
	private struct RCPreparedPayload
	{
		Prepared prepared;
		Connection conn; // Connection to be released from

		alias prepared this;

		@disable this(this); // not copyable
		~this()
		{
			// There are a couple calls to this dtor where `conn` happens to be null.
			if(conn is null)
				return;

			assert(conn.isRegistered(prepared));
			conn.release(prepared);
		}
	}
	///ditto
	alias RCPrepared = RefCounted!(RCPreparedPayload, RefCountedAutoInitialize.no);
	///ditto
	private RCPrepared rcPrepare(Connection conn, const(char[]) sql)
	{
		import std.algorithm.mutation : move;

		auto prepared = conn.prepare(sql);
		auto payload = RCPreparedPayload(prepared, conn);
		return refCounted(move(payload));
	}

	@("rcPrepared")
	unittest
	{
		import core.memory;
		mixin(scopedCn);
		
		cn.exec("DROP TABLE IF EXISTS `rcPrepared`");
		cn.exec("CREATE TABLE `rcPrepared` (
			`val` INTEGER
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");
		cn.exec("INSERT INTO `rcPrepared` VALUES (1), (2), (3)");

		// Define this in outer scope to guarantee data is left pending when
		// RCPrepared's payload is collected. This will guarantee
		// that Connection will need to queue the release.
		ResultRange rows;

		void bar()
		{
			class Foo { RCPrepared p; }
			auto foo = new Foo();

			auto rcStmt = cn.rcPrepare("SELECT * FROM `rcPrepared`");
			foo.p = rcStmt;
			rows = cn.query(rcStmt);

			/+
			At this point, there are two references to the prepared statement:
			One in a `Foo` object (currently bound to `foo`), and one on the stack.

			Returning from this function will destroy the one on the stack,
			and deterministically reduce the refcount to 1.

			So, right here we set `foo` to null to *keep* the Foo object's
			reference to the prepared statement, but set adrift the Foo object
			itself, ready to be destroyed (along with the only remaining
			prepared statement reference it contains) by the next GC cycle.

			Thus, `RCPreparedPayload.~this` and `Connection.release(Prepared)`
			will be executed during a GC cycle...and had better not perform
			any allocations, or else...boom!
			+/
			foo = null;
		}

		bar();
		assert(cn.hasPending); // Ensure Connection is forced to queue the release.
		GC.collect(); // `Connection.release(Prepared)` better not be allocating, or boom!
	}
}
