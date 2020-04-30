/++
Connect to a MySQL/MariaDB database using vibe.d's
$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool) (unsafe version).

This aliases `mysql.impl.pool.MySQLPoolImpl!false` as `MySQLPool`. Please see the
`mysql.impl.pool` moddule for documentation on how to use `MySQLPool`.

This is the unsafe version of mysql's pool module, and as such uses only @system
callback delegates. If you wish to use @safe callbacks, import
`mysql.safe.pool`.

$(SAFE_MIGRATION)
+/

module mysql.unsafe.pool;

import mysql.impl.pool;
// need to check if mysqlpool was enabled
static if(__traits(compiles, () { alias p = MySQLPoolImpl!false; }))
	alias MySQLPool = MySQLPoolImpl!false;
