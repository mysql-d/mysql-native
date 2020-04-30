/++
Connect to a MySQL/MariaDB database using vibe.d's
$(LINK2 http://vibed.org/api/vibe.core.connectionpool/ConnectionPool, ConnectionPool) (safe version).

This aliases `mysql.impl.pool.MySQLPoolImpl!true` as `MySQLPool`. Please see the
`mysql.impl.pool` moddule for documentation on how to use `MySQLPool`.

This is the @safe version of mysql's pool module, and as such uses only @safe
callback delegates. If you wish to use @system callbacks, import
`mysql.unsafe.pool`.

$(SAFE_MIGRATION)
+/

module mysql.safe.pool;

import mysql.impl.pool;
// need to check if mysqlpool was enabled
static if(__traits(compiles, () { alias p = MySQLPoolImpl!true; }))
	alias MySQLPool = MySQLPoolImpl!true;
