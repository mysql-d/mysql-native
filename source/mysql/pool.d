/++
Connect to a MySQL/MariaDB database using vibe.d's
$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool).

You have to include vibe.d in your project to be able to use this class.
If you don't want to, refer to `mysql.connection.Connection`.

This provides various benefits over creating a new connection manually,
such as automatically reusing old connections, and automatic cleanup (no need to close
the connection when done).
+/
module mysql.pool;

import std.conv;
import std.typecons;
import mysql.connection;
import mysql.prepared;
import mysql.protocol.constants;
debug(MYSQLN_TESTS)
{
	import mysql.test.common;
}

version(Have_vibe_core) version = IncludeMySQLPool;
version(MySQLDocs)      version = IncludeMySQLPool;

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
	directly. Simply provide it with a delegate that creates a new `mysql.connection.Connection`
	and does any other custom processing if needed.
	+/
	class MySQLPool
	{
		private
		{
			string m_host;
			string m_user;
			string m_password;
			string m_database;
			ushort m_port;
			SvrCapFlags m_capFlags;
			void delegate(Connection) m_onNewConnection;
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
			void delegate(Connection) onNewConnection = null)
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
			ushort port, SvrCapFlags capFlags, void delegate(Connection) onNewConnection = null)
		{
			this(host, user, password, database, port, (uint).max, capFlags, onNewConnection);
		}

		///ditto
		this(string host, string user, string password, string database,
			ushort port, void delegate(Connection) onNewConnection)
		{
			this(host, user, password, database, port, (uint).max, defaultClientFlags, onNewConnection);
		}

		///ditto
		this(string connStr, uint maxConcurrent = (uint).max, SvrCapFlags capFlags = defaultClientFlags,
			void delegate(Connection) onNewConnection = null)
		{
			auto parts = Connection.parseConnectionString(connStr);
			this(parts[0], parts[1], parts[2], parts[3], to!ushort(parts[4]), capFlags, onNewConnection);
		}

		///ditto
		this(string connStr, SvrCapFlags capFlags, void delegate(Connection) onNewConnection = null)
		{
			this(connStr, (uint).max, capFlags, onNewConnection);
		}

		///ditto
		this(string connStr, void delegate(Connection) onNewConnection)
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
		LockedConnection!Connection lockConnection()
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
		@property void onNewConnection(void delegate(Connection) onNewConnection)
		{
			m_onNewConnection = onNewConnection;
		}

		///ditto
		@property void delegate(Connection) onNewConnection()
		{
			return m_onNewConnection;
		}

		@("onNewConnection")
		debug(MYSQLN_TESTS)
		unittest
		{
 			auto count = 0;
			void callback(Connection conn)
			{
				count++;
			}

			// Test getting/setting
			auto poolA = new MySQLPool(testConnectionStr, &callback);
			auto poolB = new MySQLPool(testConnectionStr);
			auto poolNoCallback = new MySQLPool(testConnectionStr);

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
				auto poolC = new MySQLPool(testConnectionStr);
				auto connC = poolC.lockConnection();
				assert(!connC.closed);
				assert(count == oldCount);
			}
		}

		/++
		Forwards to vibe.d's
		$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool.maxConcurrency, ConnectionPool.maxConcurrency)
		+/
		@property uint maxConcurrency()
		{
			return m_pool.maxConcurrency;
		}

		///ditto
		@property void maxConcurrency(uint maxConcurrent)
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
		void autoRegister(Prepared prepared)
		{
			autoRegister(prepared.sql);
		}

		///ditto
		void autoRegister(const(char[]) sql)
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
		void autoRelease(Prepared prepared)
		{
			autoRelease(prepared.sql);
		}

		///ditto
		void autoRelease(const(char[]) sql)
		{
			preparedRegistrations.queueForRelease(sql);
		}

		/// Is the given statement set to be automatically registered on all
		/// connections obtained from this connection pool?
		bool isAutoRegistered(Prepared prepared)
		{
			return isAutoRegistered(prepared.sql);
		}
		///ditto
		bool isAutoRegistered(const(char[]) sql)
		{
			return isAutoRegistered(preparedRegistrations[sql]);
		}
		///ditto
		package bool isAutoRegistered(Nullable!PreparedInfo info)
		{
			return info.isNull || !info.get.queuedForRelease;
		}

		/// Is the given statement set to be automatically released on all
		/// connections obtained from this connection pool?
		bool isAutoReleased(Prepared prepared)
		{
			return isAutoReleased(prepared.sql);
		}
		///ditto
		bool isAutoReleased(const(char[]) sql)
		{
			return isAutoReleased(preparedRegistrations[sql]);
		}
		///ditto
		package bool isAutoReleased(Nullable!PreparedInfo info)
		{
			return info.isNull || info.get.queuedForRelease;
		}

		/++
		Is the given statement set for NEITHER auto-register
		NOR auto-release on connections obtained from
		this connection pool?

		Equivalent to `!isAutoRegistered && !isAutoReleased`.
		+/
		bool isAutoCleared(Prepared prepared)
		{
			return isAutoCleared(prepared.sql);
		}
		///ditto
		bool isAutoCleared(const(char[]) sql)
		{
			return isAutoCleared(preparedRegistrations[sql]);
		}
		///ditto
		package bool isAutoCleared(Nullable!PreparedInfo info)
		{
			return info.isNull;
		}

		/++
		Removes any `autoRegister` or `autoRelease` which may have been set
		for this prepared statement.

		Does nothing if the statement has not been set for auto-register or auto-release.

		This releases any relevent memory for potential garbage collection.
		+/
		void clearAuto(Prepared prepared)
		{
			return clearAuto(prepared.sql);
		}
		///ditto
		void clearAuto(const(char[]) sql)
		{
			preparedRegistrations.directLookup.remove(sql);
		}
		
		/++
		Removes ALL prepared statement `autoRegister` and `autoRelease` which have been set.
		
		This releases all relevent memory for potential garbage collection.
		+/
		void clearAllRegistrations()
		{
			preparedRegistrations.clear();
		}
	}
	 
	@("registration")
	debug(MYSQLN_TESTS)
	unittest
	{
		import mysql.commands;
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

	@("closedConnection") // "cct"
	debug(MYSQLN_TESTS)
	{
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

		unittest
		{
			cctStart();
			assert(cctCount == 1);

			auto cn = cctPool.lockConnection();
			assert(cctCount == 1);
			assert(!cn.closed);
		}
	}
}
