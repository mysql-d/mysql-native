/++
Connect to a MySQL/MariaDB server (unsafe version).

This is the unsafe API for the Connection type. It publicly imports
`mysql.impl.connection`, and also provides the unsafe version of the API for
preparing statements. Note that unsafe prepared statements actually use safe
code underneath.

Note that the common pieces of the connection are documented and currently
reside in `mysql.impl.connection`. Please see this module for documentation of
the connection object.

This module also contains the soon-to-be-deprecated BackwardCompatPrepared type.

$(SAFE_MIGRATION)
+/
module mysql.unsafe.connection;

public import mysql.impl.connection;
import mysql.unsafe.prepared;
import mysql.unsafe.commands;
private import CS = mysql.safe.connection;

/++
Convenience functions.

Returns: an UnsafePrepared instance based on the result of the corresponding `mysql.safe.connection` function.

See that module for more details on how these functions work.
+/
UnsafePrepared prepare(Connection conn, const(char[]) sql) @safe
{
	return CS.prepare(conn, sql).unsafe;
}

/// ditto
UnsafePrepared prepareFunction(Connection conn, string name, int numArgs) @safe
{
	return CS.prepareFunction(conn, name, numArgs).unsafe;
}

/// ditto
UnsafePrepared prepareProcedure(Connection conn, string name, int numArgs) @safe
{
	return CS.prepareProcedure(conn, name, numArgs).unsafe;
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
package(mysql) BackwardCompatPrepared prepareBackwardCompatImpl(Connection conn, const(char[]) sql)
{
	return BackwardCompatPrepared(conn, prepare(conn, sql));
}

/++
This is a wrapper over `mysql.unsafe.prepared.Prepared`, provided ONLY as a
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
	import mysql.unsafe.result;
	import std.typecons;

	private Connection _conn;
	Prepared _prepared;

	/// Access underlying `Prepared`
	@property Prepared prepared() @safe { return _prepared; }

	alias _prepared this;

	/++
	This function is provided ONLY as a temporary aid in upgrading to mysql-native v2.0.0.

	See `BackwardCompatPrepared` for more info.
	+/
	deprecated("Change 'preparedStmt.exec()' to 'conn.exec(preparedStmt)'")
	ulong exec() @system
	{
		return .exec(_conn, _prepared);
	}

	///ditto
	deprecated("Change 'preparedStmt.query()' to 'conn.query(preparedStmt)'")
	ResultRange query() @system
	{
		return .query(_conn, _prepared);
	}

	///ditto
	deprecated("Change 'preparedStmt.queryRow()' to 'conn.queryRow(preparedStmt)'")
	Nullable!Row queryRow() @system
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
	Nullable!Variant queryValue() @system
	{
		return .queryValue(_conn, _prepared);
	}
}

