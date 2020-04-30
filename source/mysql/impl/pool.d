/++
Implementation - Vibe.d MySQL Pool.

Connect to a MySQL/MariaDB database using vibe.d's
$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool).

You have to include vibe.d in your project to be able to use this class.
If you don't want to, refer to `mysql.connection.Connection`.

This provides various benefits over creating a new connection manually,
such as automatically reusing old connections, and automatic cleanup (no need to close
the connection when done).

WARNING:
This module is used to consolidate the common implementation of the safe and
unafe API. DO NOT directly import this module, please import one of
`mysql.pool`, `mysql.safe.pool`, or `mysql.unsafe.pool`. This module will be
removed in a future version without deprecation.

$(SAFE_MIGRATION)
+/
module mysql.impl.pool;

import std.conv;
import std.typecons;
import mysql.impl.connection;
import mysql.impl.prepared;
import mysql.protocol.constants;
debug(MYSQLN_TESTS)
{
	import mysql.test.common;
}

version(Have_vibe_core)
{
	version = IncludeMySQLPool;
	static if(is(typeof(ConnectionPool!Connection.init.removeUnused((c){}))))
		version = HaveCleanupFunction;
}
version(MySQLDocs)
{
	version = IncludeMySQLPool;
	version = HaveCleanupFunction;
}

version(IncludeMySQLPool)
{
	version(Have_vibe_core)
		import vibe.core.connectionpool;
	else version(MySQLDocs)
	{
		/++
		Vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool)
		class.

		Not actually included in module `mysql.pool`. Only listed here for
		documentation purposes. For ConnectionPool and it's documentation, see:
		$(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool)
		+/
		class ConnectionPool(T)
		{
			/// See: $(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.this)
			this(Connection delegate() connection_factory, uint max_concurrent = (uint).max)
			{}

			/// See: $(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.lockConnection)
			LockedConnection!T lockConnection() { return LockedConnection!T(); }

			/// See: $(LINK http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.maxConcurrency)
			uint maxConcurrency;

			/// See: $(LINK https://github.com/vibe-d/vibe-core/blob/24a83434e4c788ebb9859dfaecbe60ad0f6e9983/source/vibe/core/connectionpool.d#L113)
			void removeUnused(scope void delegate(Connection conn) @safe nothrow disconnect_callback)
			{}
		}

		/++
		Vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/LockedConnection, LockedConnection)
		struct.

		Not actually included in module `mysql.pool`. Only listed here for
		documentation purposes. For LockedConnection and it's documentation, see:
		$(LINK http://vibed.org/api/vibe.core.connectionpool/LockedConnection)
		+/
		struct LockedConnection(Connection) { Connection c; alias c this; }
	}

	/++
	A lightweight convenience interface to a MySQL/MariaDB database using vibe.d's
	$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool).

	You have to include vibe.d in your project to be able to use this class.
	If you don't want to, refer to `mysql.connection.Connection`.

	If, for any reason, this class doesn't suit your needs, it's easy to just
	use vibe.d's $(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool)
	directly. Simply provide it with a delegate that creates a new
	`mysql.impl.connection.Connection` and does any other custom processing if
	needed.

	You should not use this template directly, but rather import
	`mysql.safe.pool` or `mysql.unsafe.pool` or `mysql.pool`, which will alias
	MySQLPool to the correct instantiation. The boolean parameter here
	specifies whether the pool is operating in safe mode or unsafe mode.
	+/
	class MySQLPoolImpl(bool isSafe)
	{
		private
		{
			string m_host;
			string m_user;
			string m_password;
			string m_database;
			ushort m_port;
			SvrCapFlags m_capFlags;
			static if(isSafe)
				alias NewConnectionDelegate = void delegate(Connection) @safe;
			else
				alias NewConnectionDelegate = void delegate(Connection) @system;
			NewConnectionDelegate m_onNewConnection;
			ConnectionPool!Connection m_pool;
			PreparedRegistrations!PreparedInfo preparedRegistrations;

			struct PreparedInfo
			{
				bool queuedForRelease = false;
			}

		}

		/// Sets up a connection pool with the provided connection settings.
		///
		/// The optional `onNewConnection` param allows you to set a callback
		/// which will be run every time a new connection is created.
		this(string host, string user, string password, string database,
			ushort port = 3306, uint maxConcurrent = (uint).max,
			SvrCapFlags capFlags = defaultClientFlags,
			NewConnectionDelegate onNewConnection = null)
		{
			m_host = host;
			m_user = user;
			m_password = password;
			m_database = database;
			m_port = port;
			m_capFlags = capFlags;
			m_onNewConnection = onNewConnection;
			m_pool = new ConnectionPool!Connection(&createConnection);
		}

		///ditto
		this(string host, string user, string password, string database,
			ushort port, SvrCapFlags capFlags, NewConnectionDelegate onNewConnection = null)
		{
			this(host, user, password, database, port, (uint).max, capFlags, onNewConnection);
		}

		///ditto
		this(string host, string user, string password, string database,
			ushort port, NewConnectionDelegate onNewConnection)
		{
			this(host, user, password, database, port, (uint).max, defaultClientFlags, onNewConnection);
		}

		///ditto
		this(string connStr, uint maxConcurrent = (uint).max, SvrCapFlags capFlags = defaultClientFlags,
			NewConnectionDelegate onNewConnection = null)
		{
			auto parts = Connection.parseConnectionString(connStr);
			this(parts[0], parts[1], parts[2], parts[3], to!ushort(parts[4]), capFlags, onNewConnection);
		}

		///ditto
		this(string connStr, SvrCapFlags capFlags, NewConnectionDelegate onNewConnection = null)
		{
			this(connStr, (uint).max, capFlags, onNewConnection);
		}

		///ditto
		this(string connStr, NewConnectionDelegate onNewConnection)
		{
			this(connStr, (uint).max, defaultClientFlags, onNewConnection);
		}

		/++
		Obtain a connection. If one isn't available, a new one will be created.

		The connection returned is actually a `LockedConnection!Connection`,
		but it uses `alias this`, and so can be used just like a Connection.
		(See vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/LockedConnection, LockedConnection documentation).)

		No other fiber will be given this `mysql.connection.Connection` as long as your fiber still holds it.

		There is no need to close, release or unlock this connection. It is
		reference-counted and will automatically be returned to the pool once
		your fiber is done with it.

		If you have passed any prepared statements to  `autoRegister`
		or `autoRelease`, then those statements will automatically be
		registered/released on the connection. (Currently, this automatic
		register/release may actually occur upon the first command sent via
		the connection.)
		+/
		static if(isSafe)
			LockedConnection!Connection lockConnection() @safe
			{
				return lockConnectionImpl();
			}
		else
			LockedConnection!Connection lockConnection()
			{
				return lockConnectionImpl();
			}

		// the implementation we want to infer attributes
		private final lockConnectionImpl()
		{
			auto conn = m_pool.lockConnection();
			if(conn.closed)
				conn.reconnect();

			applyAuto(conn);
			return conn;
		}

		/// Applies any `autoRegister`/`autoRelease` settings to a connection,
		/// if necessary.
		private void applyAuto(T)(T conn)
		{
			foreach(sql, info; preparedRegistrations.directLookup)
			{
				auto registeredOnPool = !info.queuedForRelease;
				auto registeredOnConnection = conn.isRegistered(sql);

				if(registeredOnPool && !registeredOnConnection) // Need to register?
					conn.register(sql);
				else if(!registeredOnPool && registeredOnConnection) // Need to release?
					conn.release(sql);
			}
		}

		private Connection createConnection()
		{
			auto conn = new Connection(m_host, m_user, m_password, m_database, m_port, m_capFlags);

			if(m_onNewConnection)
				m_onNewConnection(conn);

			return conn;
		}

		/// Get/set a callback delegate to be run every time a new connection
		/// is created.
		@property void onNewConnection(NewConnectionDelegate onNewConnection) @safe
		{
			m_onNewConnection = onNewConnection;
		}

		///ditto
		@property NewConnectionDelegate onNewConnection() @safe
		{
			return m_onNewConnection;
		}

		@("onNewConnection")
		debug(MYSQLN_TESTS)
		unittest
		{
			auto count = 0;
			static if(isSafe)
				@safe void callback(Connection conn)
				{
					count++;
				}
			else
				@system void callback(Connection conn)
				{
					count++;
				}

			// Test getting/setting
			auto poolA = new MySQLPoolImpl(testConnectionStr, &callback);
			auto poolB = new MySQLPoolImpl(testConnectionStr);
			auto poolNoCallback = new MySQLPoolImpl(testConnectionStr);

			assert(poolA.onNewConnection == &callback);
			assert(poolB.onNewConnection is null);
			assert(poolNoCallback.onNewConnection is null);

			poolB.onNewConnection = &callback;
			assert(poolB.onNewConnection == &callback);
			assert(count == 0);

			// Ensure callback is called
			{
				auto connA = poolA.lockConnection();
				assert(!connA.closed);
				assert(count == 1);

				auto connB = poolB.lockConnection();
				assert(!connB.closed);
				assert(count == 2);
			}

			// Ensure works with no callback
			{
				auto oldCount = count;
				auto poolC = new MySQLPoolImpl(testConnectionStr);
				auto connC = poolC.lockConnection();
				assert(!connC.closed);
				assert(count == oldCount);
			}
		}

		/++
		Forwards to vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.maxConcurrency, ConnectionPool.maxConcurrency)
		+/
		@property uint maxConcurrency() @safe
		{
			return m_pool.maxConcurrency;
		}

		///ditto
		@property void maxConcurrency(uint maxConcurrent) @safe
		{
			m_pool.maxConcurrency = maxConcurrent;
		}

		/++
		Set a prepared statement to be automatically registered on all
		connections received from this pool.

		This also clears any `autoRelease` which may have been set for this statement.

		Calling this is not strictly necessary, as a prepared statement will
		automatically be registered upon its first use on any `Connection`.
		This is provided for those who prefer eager registration over lazy
		for performance reasons.

		Once this has been called, obtaining a connection via `lockConnection`
		will automatically register the prepared statement on the connection
		if it isn't already registered on the connection. This single
		registration safely persists after the connection is reclaimed by the
		pool and locked again by another Vibe.d task.

		Note, due to the way Vibe.d works, it is not possible to eagerly
		register or release a statement on all connections already sitting
		in the pool. This can only be done when locking a connection.

		You can stop the pool from continuing to auto-register the statement
		by calling either `autoRelease` or `clearAuto`.
		+/
		void autoRegister(SafePrepared prepared) @safe
		{
			autoRegister(prepared.sql);
		}

		///ditto
		void autoRegister(UnsafePrepared prepared) @safe
		{
			autoRegister(prepared.sql);
		}

		///ditto
		void autoRegister(const(char[]) sql) @safe
		{
			preparedRegistrations.registerIfNeeded(sql, (sql) => PreparedInfo());
		}

		/++
		Set a prepared statement to be automatically released from all
		connections received from this pool.

		This also clears any `autoRegister` which may have been set for this statement.

		Calling this is not strictly necessary. The server considers prepared
		statements to be per-connection, so they'll go away when the connection
		closes anyway. This is provided in case direct control is actually needed.

		Once this has been called, obtaining a connection via `lockConnection`
		will automatically release the prepared statement from the connection
		if it isn't already releases from the connection.

		Note, due to the way Vibe.d works, it is not possible to eagerly
		register or release a statement on all connections already sitting
		in the pool. This can only be done when locking a connection.

		You can stop the pool from continuing to auto-release the statement
		by calling either `autoRegister` or `clearAuto`.
		+/
		void autoRelease(SafePrepared prepared) @safe
		{
			autoRelease(prepared.sql);
		}

		///ditto
		void autoRelease(UnsafePrepared prepared) @safe
		{
			autoRelease(prepared.sql);
		}

		///ditto
		void autoRelease(const(char[]) sql) @safe
		{
			preparedRegistrations.queueForRelease(sql);
		}

		/// Is the given statement set to be automatically registered on all
		/// connections obtained from this connection pool?
		bool isAutoRegistered(SafePrepared prepared) @safe
		{
			return isAutoRegistered(prepared.sql);
		}
		///ditto
		bool isAutoRegistered(UnsafePrepared prepared) @safe
		{
			return isAutoRegistered(prepared.sql);
		}
		///ditto
		bool isAutoRegistered(const(char[]) sql) @safe
		{
			return isAutoRegistered(preparedRegistrations[sql]);
		}
		///ditto
		package bool isAutoRegistered(Nullable!PreparedInfo info) @safe
		{
			return info.isNull || !info.get.queuedForRelease;
		}

		/// Is the given statement set to be automatically released on all
		/// connections obtained from this connection pool?
		bool isAutoReleased(SafePrepared prepared) @safe
		{
			return isAutoReleased(prepared.sql);
		}
		///ditto
		bool isAutoReleased(UnsafePrepared prepared) @safe
		{
			return isAutoReleased(prepared.sql);
		}
		///ditto
		bool isAutoReleased(const(char[]) sql) @safe
		{
			return isAutoReleased(preparedRegistrations[sql]);
		}
		///ditto
		package bool isAutoReleased(Nullable!PreparedInfo info) @safe
		{
			return info.isNull || info.get.queuedForRelease;
		}

		/++
		Is the given statement set for NEITHER auto-register
		NOR auto-release on connections obtained from
		this connection pool?

		Equivalent to `!isAutoRegistered && !isAutoReleased`.
		+/
		bool isAutoCleared(SafePrepared prepared) @safe
		{
			return isAutoCleared(prepared.sql);
		}
		///ditto
		bool isAutoCleared(const(char[]) sql) @safe
		{
			return isAutoCleared(preparedRegistrations[sql]);
		}
		///ditto
		package bool isAutoCleared(Nullable!PreparedInfo info) @safe
		{
			return info.isNull;
		}

		/++
		Removes any `autoRegister` or `autoRelease` which may have been set
		for this prepared statement.

		Does nothing if the statement has not been set for auto-register or auto-release.

		This releases any relevent memory for potential garbage collection.
		+/
		void clearAuto(SafePrepared prepared) @safe
		{
			return clearAuto(prepared.sql);
		}
		///ditto
		void clearAuto(UnsafePrepared prepared) @safe
		{
			return clearAuto(prepared.sql);
		}
		///ditto
		void clearAuto(const(char[]) sql) @safe
		{
			preparedRegistrations.directLookup.remove(sql);
		}

		/++
		Removes ALL prepared statement `autoRegister` and `autoRelease` which have been set.

		This releases all relevent memory for potential garbage collection.
		+/
		void clearAllRegistrations() @safe
		{
			preparedRegistrations.clear();
		}

		version(HaveCleanupFunction)
		{
			/++
			Removes all unused connections from the pool. This can
			be used to clean up before exiting the program to
			ensure the event core driver can be properly shut down.

			Note: this is only available if vibe-core 1.7.0 or later is being
			used.
			+/
			void removeUnusedConnections() @safe
			{
				// Note: we squelch all exceptions here, because vibe-core
				// requires the function be nothrow, and because an exception
				// thrown while closing is probably not important enough to
				// interrupt cleanup.
				m_pool.removeUnused((conn) @trusted nothrow {
					try {
						conn.close();
					} catch(Exception) {}
				});
			}
		}
	}

	@("registration")
	debug(MYSQLN_TESTS)
	unittest
	{
		static void test(bool isSafe)()
		{
			mixin(doImports(isSafe, "commands", "connection"));
			alias MySQLPool = MySQLPoolImpl!isSafe;
			auto pool = new MySQLPool(testConnectionStr);

			// Setup
			Connection cn = pool.lockConnection();
			cn.exec("DROP TABLE IF EXISTS `poolRegistration`");
			cn.exec("CREATE TABLE `poolRegistration` (
													  `data` LONGBLOB
													 ) ENGINE=InnoDB DEFAULT CHARSET=utf8");
			immutable sql = "SELECT * from `poolRegistration`";
			//auto cn2 = pool.lockConnection(); // Seems to return the same connection as `cn`
			auto cn2 = pool.createConnection();
			pool.applyAuto(cn2);
			assert(cn !is cn2);

			// Tests:
			// Initial
			assert(pool.isAutoCleared(sql));
			assert(pool.isAutoRegistered(sql));
			assert(pool.isAutoReleased(sql));
			assert(!cn.isRegistered(sql));
			assert(!cn2.isRegistered(sql));

			// Register on connection #1
			auto prepared = cn.prepare(sql);
			{
				assert(pool.isAutoCleared(sql));
				assert(pool.isAutoRegistered(sql));
				assert(pool.isAutoReleased(sql));
				assert(cn.isRegistered(sql));
				assert(!cn2.isRegistered(sql));

				//auto cn3 = pool.lockConnection(); // Seems to return the same connection as `cn`
				auto cn3 = pool.createConnection();
				pool.applyAuto(cn3);
				assert(!cn3.isRegistered(sql));
			}

			// autoRegister
			pool.autoRegister(prepared);
			{
				assert(!pool.isAutoCleared(sql));
				assert(pool.isAutoRegistered(sql));
				assert(!pool.isAutoReleased(sql));
				assert(cn.isRegistered(sql));
				assert(!cn2.isRegistered(sql));

				//auto cn3 = pool.lockConnection(); // Seems to return the *same* connection as `cn`
				auto cn3 = pool.createConnection();
				pool.applyAuto(cn3);
				assert(cn3.isRegistered(sql));
			}

			// autoRelease
			pool.autoRelease(prepared);
			{
				assert(!pool.isAutoCleared(sql));
				assert(!pool.isAutoRegistered(sql));
				assert(pool.isAutoReleased(sql));
				assert(cn.isRegistered(sql));
				assert(!cn2.isRegistered(sql));

				//auto cn3 = pool.lockConnection(); // Seems to return the same connection as `cn`
				auto cn3 = pool.createConnection();
				pool.applyAuto(cn3);
				assert(!cn3.isRegistered(sql));
			}

			// clearAuto
			pool.clearAuto(prepared);
			{
				assert(pool.isAutoCleared(sql));
				assert(pool.isAutoRegistered(sql));
				assert(pool.isAutoReleased(sql));
				assert(cn.isRegistered(sql));
				assert(!cn2.isRegistered(sql));

				//auto cn3 = pool.lockConnection(); // Seems to return the same connection as `cn`
				auto cn3 = pool.createConnection();
				pool.applyAuto(cn3);
				assert(!cn3.isRegistered(sql));
			}
		}

		// run tests for both safe and unsafe options.
		() @safe {test!true(); }();
		test!false();
	}

	@("closedConnection") // "cct"
	debug(MYSQLN_TESTS)
	unittest
	{
		static void test(bool isSafe)()
		{
			mixin(doImports(isSafe, "commands"));
			alias MySQLPool = MySQLPoolImpl!isSafe;
			MySQLPool cctPool;
			int cctCount=0;

			void cctStart()
			{
				import std.array;
				import mysql.commands;

				cctPool = new MySQLPool(testConnectionStr);
				cctPool.onNewConnection = (Connection conn) { cctCount++; };
				assert(cctCount == 0);

				auto cn = cctPool.lockConnection();
				assert(!cn.closed);
				cn.close();
				assert(cn.closed);
				assert(cctCount == 1);
			}

			{
				cctStart();
				assert(cctCount == 1);

				auto cn = cctPool.lockConnection();
				assert(cctCount == 1);
				assert(!cn.closed);
			}
		}

		// run tests for both safe and unsafe options.
		() @safe {test!true(); }();
		test!false();
	}
}
