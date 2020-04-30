/++
Use a DB via plain SQL statements (safe version).

Commands that are expected to return a result set - queries - have distinctive
methods that are enforced. That is it will be an error to call such a method
with an SQL command that does not produce a result set. So for commands like
SELECT, use the `query` functions. For other commands, like
INSERT/UPDATE/CREATE/etc, use `exec`.

This is the @safe version of mysql's command module, and as such uses the @safe
rows and result ranges, and the `MySQLVal` type. For the `Variant` unsafe
version, please import `mysql.unsafe.commands`.

$(SAFE_MIGRATION)
+/

module mysql.safe.commands;

import std.conv;
import std.exception;
import std.range;
import std.typecons;
import std.variant;

import mysql.safe.connection;
import mysql.exceptions;
import mysql.safe.prepared;
import mysql.protocol.comms;
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packets;
import mysql.impl.result;
import mysql.types;

/// This feature is not yet implemented. It currently has no effect.
/+
A struct to represent specializations of returned statement columns.

If you are executing a query that will include result columns that are large objects,
it may be expedient to deal with the data as it is received rather than first buffering
it to some sort of byte array. These two variables allow for this. If both are provided
then the corresponding column will be fed to the stipulated delegate in chunks of
`chunkSize`, with the possible exception of the last chunk, which may be smaller.
The bool argument `finished` will be set to true when the last chunk is set.

Be aware when specifying types for column specializations that for some reason the
field descriptions returned for a resultset have all of the types TINYTEXT, MEDIUMTEXT,
TEXT, LONGTEXT, TINYBLOB, MEDIUMBLOB, BLOB, and LONGBLOB lumped as type 0xfc
contrary to what it says in the protocol documentation.
+/
struct ColumnSpecialization
{
	size_t  cIndex;    // parameter number 0 - number of params-1
	ushort  type;
	uint    chunkSize; /// In bytes
	void delegate(const(ubyte)[] chunk, bool finished) @safe chunkDelegate;
}
///ditto
alias CSN = ColumnSpecialization;

@safe:

@("columnSpecial")
debug(MYSQLN_TESTS)
unittest
{
	import std.array;
	import std.range;
	import mysql.test.common;
	mixin(scopedCn);

	// Setup
	cn.exec("DROP TABLE IF EXISTS `columnSpecial`");
	cn.exec("CREATE TABLE `columnSpecial` (
		`data` LONGBLOB
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");

	immutable totalSize = 1000; // Deliberately not a multiple of chunkSize below
	auto alph = cast(const(ubyte)[]) "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
	auto data = alph.cycle.take(totalSize).array;
	cn.exec("INSERT INTO `columnSpecial` VALUES (\""~(cast(const(char)[])data)~"\")");

	// Common stuff
	int chunkSize;
	immutable selectSQL = "SELECT `data` FROM `columnSpecial`";
	ubyte[] received;
	bool lastValueOfFinished;
	void receiver(const(ubyte)[] chunk, bool finished) @safe
	{
		assert(lastValueOfFinished == false);

		if(finished)
			assert(chunk.length == chunkSize);
		else
			assert(chunk.length < chunkSize); // Not always true in general, but true in this unittest

		received ~= chunk;
		lastValueOfFinished = finished;
	}

	// Sanity check
	auto value = cn.queryValue(selectSQL);
	assert(!value.isNull);
	assert(value.get == data);

	// Use ColumnSpecialization with sql string,
	// and totalSize as a multiple of chunkSize
	{
		chunkSize = 100;
		assert(cast(int)(totalSize / chunkSize) * chunkSize == totalSize);
		auto columnSpecial = ColumnSpecialization(0, 0xfc, chunkSize, &receiver);

		received = null;
		lastValueOfFinished = false;
		value = cn.queryValue(selectSQL, [columnSpecial]);
		assert(!value.isNull);
		assert(value.get == data);
		//TODO: ColumnSpecialization is not yet implemented
		//assert(lastValueOfFinished == true);
		//assert(received == data);
	}

	// Use ColumnSpecialization with sql string,
	// and totalSize as a non-multiple of chunkSize
	{
		chunkSize = 64;
		assert(cast(int)(totalSize / chunkSize) * chunkSize != totalSize);
		auto columnSpecial = ColumnSpecialization(0, 0xfc, chunkSize, &receiver);

		received = null;
		lastValueOfFinished = false;
		value = cn.queryValue(selectSQL, [columnSpecial]);
		assert(!value.isNull);
		assert(value.get == data);
		//TODO: ColumnSpecialization is not yet implemented
		//assert(lastValueOfFinished == true);
		//assert(received == data);
	}

	// Use ColumnSpecialization with prepared statement,
	// and totalSize as a multiple of chunkSize
	{
		chunkSize = 100;
		assert(cast(int)(totalSize / chunkSize) * chunkSize == totalSize);
		auto columnSpecial = ColumnSpecialization(0, 0xfc, chunkSize, &receiver);

		received = null;
		lastValueOfFinished = false;
		auto prepared = cn.prepare(selectSQL);
		prepared.columnSpecials = [columnSpecial];
		value = cn.queryValue(prepared);
		assert(!value.isNull);
		assert(value.get == data);
		//TODO: ColumnSpecialization is not yet implemented
		//assert(lastValueOfFinished == true);
		//assert(received == data);
	}
}

/++
Execute an SQL command or prepared statement, such as INSERT/UPDATE/CREATE/etc.

This method is intended for commands such as which do not produce a result set
(otherwise, use one of the `query` functions instead.) If the SQL command does
produces a result set (such as SELECT), `mysql.exceptions.MYXResultRecieved`
will be thrown.

If `args` is supplied, the sql string will automatically be used as a prepared
statement. Prepared statements are automatically cached by mysql-native,
so there's no performance penalty for using this multiple times for the
same statement instead of manually preparing a statement.

If `args` and `prepared` are both provided, `args` will be used,
and any arguments that are already set in the prepared statement
will automatically be replaced with `args` (note, just like calling
`mysql.impl.prepared.SafePrepared.setArgs`, this will also remove all
`mysql.impl.prepared.SafeParameterSpecialization` that may have been applied).

Only use the `const(char[]) sql` overload that doesn't take `args`
when you are not going to be using the same
command repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise, consider using overload that takes a `Prepared`.

If you need to use any `mysql.impl.prepared.SafeParameterSpecialization`, use
`mysql.safe.connection.prepare` to manually create a
`mysql.impl.prepared.SafePrepared`, and set your parameter specializations using
`mysql.impl.prepared.SafePrepared.setArg` or
`mysql.impl.prepared.SafePrepared.setArgs`.

Type_Mappings: $(TYPE_MAPPINGS)

Params:
conn = An open `mysql.impl.connection.Connection` to the database.
sql = The SQL command to be run.
prepared = The prepared statement to be run.
args = The arguments to be passed in the `mysql.impl.prepared.SafePrepared`.

Returns: The number of rows affected.

Example:
---
auto myInt = 7;
auto rowsAffected = myConnection.exec("INSERT INTO `myTable` (`a`) VALUES (?)", myInt);
---
+/
ulong exec(Connection conn, const(char[]) sql)
{
	return execImpl(conn, ExecQueryImplInfo(false, sql));
}
///ditto
ulong exec(T...)(Connection conn, const(char[]) sql, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]))
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return exec(conn, prepared);
}
///ditto
ulong exec(Connection conn, const(char[]) sql, MySQLVal[] args)
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return exec(conn, prepared);
}

///ditto
ulong exec(Connection conn, ref Prepared prepared)
{
	auto preparedInfo = conn.registerIfNeeded(prepared.sql);
	auto ra = execImpl(conn, prepared.getExecQueryImplInfo(preparedInfo.statementId));
	prepared._lastInsertID = conn.lastInsertID;
	return ra;
}
///ditto
ulong exec(T...)(Connection conn, ref Prepared prepared, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]))
{
	prepared.setArgs(args);
	return exec(conn, prepared);
}

///ditto
ulong exec(Connection conn, ref Prepared prepared, MySQLVal[] args)
{
	prepared.setArgs(args);
	return exec(conn, prepared);
}

/// Common implementation for `exec` overloads
package ulong execImpl(Connection conn, ExecQueryImplInfo info)
{
	ulong rowsAffected;
	bool receivedResultSet = execQueryImpl(conn, info, rowsAffected);
	if(receivedResultSet)
	{
		conn.purgeResult();
		throw new MYXResultRecieved();
	}

	return rowsAffected;
}

/++
Execute an SQL SELECT command or prepared statement.

This returns an input range of `mysql.impl.result.SafeRow`, so if you need random
access to the `mysql.impl.result.SafeRow` elements, simply call
$(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`)
on the result.

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

If `args` is supplied, the sql string will automatically be used as a prepared
statement. Prepared statements are automatically cached by mysql-native,
so there's no performance penalty for using this multiple times for the
same statement instead of manually preparing a statement.

If `args` and `prepared` are both provided, `args` will be used,
and any arguments that are already set in the prepared statement
will automatically be replaced with `args` (note, just like calling
`mysql.impl.prepared.SafePrepared.setArgs`, this will also remove all
`mysql.impl.prepared.SafeParameterSpecialization` that may have been applied).

Only use the `const(char[]) sql` overload that doesn't take `args`
when you are not going to be using the same
command repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise, consider using overload that takes a `Prepared`.

If you need to use any `mysql.safe.prepared.ParameterSpecialization`, use
`mysql.safe.connection.prepare` to manually create a
`mysql.impl.prepared.SafePrepared`, and set your parameter specializations using
`mysql.impl.prepared.SafePrepared.setArg` or
`mysql.impl.prepared.SafePrepared.setArgs`.

Type_Mappings: $(TYPE_MAPPINGS)

Params:
conn = An open `mysql.impl.connection.Connection` to the database.
sql = The SQL command to be run.
prepared = The prepared statement to be run.
csa = Not yet implemented.
args = Arguments to the SQL statement or `mysql.safe.prepared.Prepared` struct.

Returns: A (possibly empty) `mysql.safe.result.ResultRange`.

Example:
---
ResultRange oneAtATime = myConnection.query("SELECT * from `myTable`");
Row[]       allAtOnce  = myConnection.query("SELECT * from `myTable`").array;

auto myInt = 7;
ResultRange rows = myConnection.query("SELECT * FROM `myTable` WHERE `a` = ?", myInt);
---
+/
/+
Future text:
If there are long data items among the expected result columns you can use
the `csa` param to specify that they are to be subject to chunked transfer via a
delegate.

csa = An optional array of `ColumnSpecialization` structs. If you need to
use this with a prepared statement, please use `mysql.prepared.Prepared.columnSpecials`.
+/
SafeResultRange query(Connection conn, const(char[]) sql, ColumnSpecialization[] csa = null)
{
	return queryImpl(csa, conn, ExecQueryImplInfo(false, sql));
}
///ditto
SafeResultRange query(T...)(Connection conn, const(char[]) sql, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]) && !is(T[0] == ColumnSpecialization) && !is(T[0] == ColumnSpecialization[]))
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return query(conn, prepared);
}

///ditto
SafeResultRange query(Connection conn, const(char[]) sql, MySQLVal[] args)
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return query(conn, prepared);
}

///ditto
SafeResultRange query(Connection conn, ref Prepared prepared)
{
	auto preparedInfo = conn.registerIfNeeded(prepared.sql);
	auto result = queryImpl(prepared.columnSpecials, conn, prepared.getExecQueryImplInfo(preparedInfo.statementId));
	prepared._lastInsertID = conn.lastInsertID; // Conceivably, this might be needed when multi-statements are enabled.
	return result;
}
///ditto
SafeResultRange query(T...)(Connection conn, ref Prepared prepared, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]) && !is(T[0] == ColumnSpecialization) && !is(T[0] == ColumnSpecialization[]))
{
	prepared.setArgs(args);
	return query(conn, prepared);
}
///ditto
SafeResultRange query(Connection conn, ref Prepared prepared, MySQLVal[] args)
{
	prepared.setArgs(args);
	return query(conn, prepared);
}

/// Common implementation for `query` overloads
package SafeResultRange queryImpl(ColumnSpecialization[] csa,
	Connection conn, ExecQueryImplInfo info)
{
	ulong ra;
	enforce!MYXNoResultRecieved(execQueryImpl(conn, info, ra));

	conn._rsh = ResultSetHeaders(conn, conn._fieldCount);
	if(csa !is null)
		conn._rsh.addSpecializations(csa);

	conn._headersPending = false;
	return SafeResultRange(conn, conn._rsh, conn._rsh.fieldNames);
}

/++
Execute an SQL SELECT command or prepared statement where you only want the
first `mysql.impl.result.SafeRow`, if any.

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

If `args` is supplied, the sql string will automatically be used as a prepared
statement. Prepared statements are automatically cached by mysql-native,
so there's no performance penalty for using this multiple times for the
same statement instead of manually preparing a statement.

If `args` and `prepared` are both provided, `args` will be used,
and any arguments that are already set in the prepared statement
will automatically be replaced with `args` (note, just like calling
`mysql.impl.prepared.SafePrepared.setArgs`, this will also remove all
`mysql.impl.prepared.SafeParameterSpecialization` that may have been applied).

Only use the `const(char[]) sql` overload that doesn't take `args`
when you are not going to be using the same
command repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise, consider using overload that takes a `Prepared`.

If you need to use any `mysql.impl.prepared.SafeParameterSpecialization`, use
`mysql.safe.connection.prepare` to manually create a
`mysql.impl.prepared.SafePrepared`, and set your parameter specializations using
`mysql.impl.prepared.SafePrepared.setArg` or
`mysql.impl.prepared.SafePrepared.setArgs`.

Type_Mappings: $(TYPE_MAPPINGS)

Params:
conn = An open `mysql.impl.connection.Connection` to the database.
sql = The SQL command to be run.
prepared = The prepared statement to be run.
csa = Not yet implemented.
args = Arguments to SQL statement or `mysql.impl.prepared.SafePrepared` struct.

Returns: `Nullable!(mysql.impl.result.SafeRow)`: This will be null (check
		via `Nullable.isNull`) if the query resulted in an empty result set.

Example:
---
auto myInt = 7;
Nullable!Row row = myConnection.queryRow("SELECT * FROM `myTable` WHERE `a` = ?", myInt);
---
+/
/+
Future text:
If there are long data items among the expected result columns you can use
the `csa` param to specify that they are to be subject to chunked transfer via a
delegate.

csa = An optional array of `ColumnSpecialization` structs. If you need to
use this with a prepared statement, please use `mysql.prepared.Prepared.columnSpecials`.
+/
/+
Future text:
If there are long data items among the expected result columns you can use
the `csa` param to specify that they are to be subject to chunked transfer via a
delegate.

csa = An optional array of `ColumnSpecialization` structs. If you need to
use this with a prepared statement, please use `mysql.prepared.Prepared.columnSpecials`.
+/
Nullable!SafeRow queryRow(Connection conn, const(char[]) sql, ColumnSpecialization[] csa = null)
{
	return queryRowImpl(csa, conn, ExecQueryImplInfo(false, sql));
}
///ditto
Nullable!SafeRow queryRow(T...)(Connection conn, const(char[]) sql, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]) && !is(T[0] == ColumnSpecialization) && !is(T[0] == ColumnSpecialization[]))
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return queryRow(conn, prepared);
}
///ditto
Nullable!SafeRow queryRow(Connection conn, const(char[]) sql, MySQLVal[] args)
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return queryRow(conn, prepared);
}

///ditto
Nullable!SafeRow queryRow(Connection conn, ref Prepared prepared)
{
	auto preparedInfo = conn.registerIfNeeded(prepared.sql);
	auto result = queryRowImpl(prepared.columnSpecials, conn, prepared.getExecQueryImplInfo(preparedInfo.statementId));
	prepared._lastInsertID = conn.lastInsertID; // Conceivably, this might be needed when multi-statements are enabled.
	return result;
}
///ditto
Nullable!SafeRow queryRow(T...)(Connection conn, ref Prepared prepared, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]) && !is(T[0] == ColumnSpecialization) && !is(T[0] == ColumnSpecialization[]))
{
	prepared.setArgs(args);
	return queryRow(conn, prepared);
}
///ditto
Nullable!SafeRow queryRow(Connection conn, ref Prepared prepared, MySQLVal[] args)
{
	prepared.setArgs(args);
	return queryRow(conn, prepared);
}

/// Common implementation for `querySet` overloads.
package Nullable!SafeRow queryRowImpl(ColumnSpecialization[] csa, Connection conn,
	ExecQueryImplInfo info)
{
	auto results = queryImpl(csa, conn, info);
	if(results.empty)
		return Nullable!SafeRow();
	else
	{
		auto row = results.front;
		results.close();
		return Nullable!SafeRow(row);
	}
}

/++
Execute an SQL SELECT command or prepared statement where you only want the
first `mysql.result.Row`, and place result values into a set of D variables.

This method will throw if any column type is incompatible with the corresponding D variable.

Unlike the other query functions, queryRowTuple will throw
`mysql.exceptions.MYX` if the result set is empty
(and thus the reference variables passed in cannot be filled).

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

Only use the `const(char[]) sql` overload when you are not going to be using the same
command repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise, consider using overload that takes a `Prepared`.

Type_Mappings: $(TYPE_MAPPINGS)

Params:
conn = An open `mysql.impl.connection.Connection` to the database.
sql = The SQL command to be run.
prepared = The prepared statement to be run.
args = The variables, taken by reference, to receive the values.
+/
void queryRowTuple(T...)(Connection conn, const(char[]) sql, ref T args)
{
	return queryRowTupleImpl(conn, ExecQueryImplInfo(false, sql), args);
}

///ditto
void queryRowTuple(T...)(Connection conn, ref Prepared prepared, ref T args)
{
	auto preparedInfo = conn.registerIfNeeded(prepared.sql);
	queryRowTupleImpl(conn, prepared.getExecQueryImplInfo(preparedInfo.statementId), args);
	prepared._lastInsertID = conn.lastInsertID; // Conceivably, this might be needed when multi-statements are enabled.
}

/// Common implementation for `queryRowTuple` overloads.
package(mysql) void queryRowTupleImpl(T...)(Connection conn, ExecQueryImplInfo info, ref T args)
{
	ulong ra;
	enforce!MYXNoResultRecieved(execQueryImpl(conn, info, ra));

	auto rr = conn.getNextRow();
	/+if (!rr._valid)   // The result set was empty - not a crime.
		return;+/
	enforce!MYX(rr._values.length == args.length, "Result column count does not match the target tuple.");
	foreach (size_t i, dummy; args)
	{
		import taggedalgebraic.taggedalgebraic : get, hasType;
		enforce!MYX(rr._values[i].hasType!(T[i]),
			"Tuple "~to!string(i)~" type and column type are not compatible.");
		// use taggedalgebraic get to avoid extra calls.
		args[i] = get!(T[i])(rr._values[i]);
	}
	// If there were more rows, flush them away
	// Question: Should I check in purgeResult and throw if there were - it's very inefficient to
	// allow sloppy SQL that does not ensure just one row!
	conn.purgeResult();
}

// Test what happends when queryRowTuple receives no rows
@("queryRowTuple_noRows")
debug(MYSQLN_TESTS)
unittest
{
	import mysql.test.common : scopedCn, createCn;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `queryRowTuple_noRows`");
	cn.exec("CREATE TABLE `queryRowTuple_noRows` (
		`val` INTEGER
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");

	immutable selectSQL = "SELECT * FROM `queryRowTuple_noRows`";
	int queryTupleResult;
	assertThrown!MYX(cn.queryRowTuple(selectSQL, queryTupleResult));
}

/++
Execute an SQL SELECT command or prepared statement and return a single value:
the first column of the first row received.

If the query did not produce any rows, or the rows it produced have zero columns,
this will return `Nullable!MySQLVal()`, ie, null. Test for this with
`result.isNull`.

If the query DID produce a result, but the value actually received is NULL,
then `result.isNull` will be FALSE, and `result.get` will produce a MySQLVal
which CONTAINS null. Check for this with `result.get.kind == MySQLVal.Kind.Null`
or `result.get == null`.

If the SQL command does not produce a result set (such as INSERT/CREATE/etc),
then `mysql.exceptions.MYXNoResultRecieved` will be thrown. Use
`exec` instead for such commands.

If `args` is supplied, the sql string will automatically be used as a prepared
statement. Prepared statements are automatically cached by mysql-native,
so there's no performance penalty for using this multiple times for the
same statement instead of manually preparing a statement.

If `args` and `prepared` are both provided, `args` will be used,
and any arguments that are already set in the prepared statement
will automatically be replaced with `args` (note, just like calling
`mysql.impl.prepared.SafePrepared.setArgs`, this will also remove all
`mysql.impl.prepared.SafeParameterSpecialization` that may have been applied).

Only use the `const(char[]) sql` overload that doesn't take `args`
when you are not going to be using the same
command repeatedly and you are CERTAIN all the data you're sending is properly
escaped. Otherwise, consider using overload that takes a `Prepared`.

If you need to use any `mysql.impl.prepared.SafeParameterSpecialization`, use
`mysql.safe.connection.prepare` to manually create a `mysql.impl.prepared.SafePrepared`,
and set your parameter specializations using `mysql.impl.prepared.SafePrepared.setArg`
or `mysql.impl.prepared.SafePrepared.setArgs`.

Type_Mappings: $(TYPE_MAPPINGS)

Params:
conn = An open `mysql.impl.connection.Connection` to the database.
sql = The SQL command to be run.
prepared = The prepared statement to be run.
csa = Not yet implemented.

Returns: `Nullable!MySQLVal`: This will be null (check via `Nullable.isNull`) if the
query resulted in an empty result set.

Example:
---
auto myInt = 7;
Nullable!MySQLVal value = myConnection.queryRow("SELECT * FROM `myTable` WHERE `a` = ?", myInt);
---
+/
/+
Future text:
If there are long data items among the expected result columns you can use
the `csa` param to specify that they are to be subject to chunked transfer via a
delegate.

csa = An optional array of `ColumnSpecialization` structs. If you need to
use this with a prepared statement, please use `mysql.prepared.Prepared.columnSpecials`.
+/
/+
Future text:
If there are long data items among the expected result columns you can use
the `csa` param to specify that they are to be subject to chunked transfer via a
delegate.

csa = An optional array of `ColumnSpecialization` structs. If you need to
use this with a prepared statement, please use `mysql.prepared.Prepared.columnSpecials`.
+/
///ditto
Nullable!MySQLVal queryValue(Connection conn, const(char[]) sql, ColumnSpecialization[] csa = null)
{
	return queryValueImpl(csa, conn, ExecQueryImplInfo(false, sql));
}
///ditto
Nullable!MySQLVal queryValue(T...)(Connection conn, const(char[]) sql, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]) && !is(T[0] == ColumnSpecialization) && !is(T[0] == ColumnSpecialization[]))
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return queryValue(conn, prepared);
}
///ditto
Nullable!MySQLVal queryValue(Connection conn, const(char[]) sql, MySQLVal[] args)
{
	auto prepared = conn.prepare(sql);
	prepared.setArgs(args);
	return queryValue(conn, prepared);
}
///ditto
Nullable!MySQLVal queryValue(Connection conn, ref Prepared prepared)
{
	auto preparedInfo = conn.registerIfNeeded(prepared.sql);
	auto result = queryValueImpl(prepared.columnSpecials, conn, prepared.getExecQueryImplInfo(preparedInfo.statementId));
	prepared._lastInsertID = conn.lastInsertID; // Conceivably, this might be needed when multi-statements are enabled.
	return result;
}
///ditto
Nullable!MySQLVal queryValue(T...)(Connection conn, ref Prepared prepared, T args)
	if(T.length > 0 && !is(T[0] == Variant[]) && !is(T[0] == MySQLVal[]) && !is(T[0] == ColumnSpecialization) && !is(T[0] == ColumnSpecialization[]))
{
	prepared.setArgs(args);
	return queryValue(conn, prepared);
}
///ditto
Nullable!MySQLVal queryValue(Connection conn, ref Prepared prepared, MySQLVal[] args)
{
	prepared.setArgs(args);
	return queryValue(conn, prepared);
}

/// Common implementation for `queryValue` overloads.
package Nullable!MySQLVal queryValueImpl(ColumnSpecialization[] csa, Connection conn,
	ExecQueryImplInfo info)
{
	auto results = queryImpl(csa, conn, info);
	if(results.empty)
		return Nullable!MySQLVal();
	else
	{
		auto row = results.front;
		results.close();

		if(row.length == 0)
			return Nullable!MySQLVal();
		else
			return Nullable!MySQLVal(row[0]);
	}
}

@("execOverloads")
debug(MYSQLN_TESTS)
unittest
{
	import std.array;
	import mysql.test.common;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `execOverloads`");
	cn.exec("CREATE TABLE `execOverloads` (
		`i` INTEGER,
		`s` VARCHAR(50)
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");

	immutable prepareSQL = "INSERT INTO `execOverloads` VALUES (?, ?)";

	// Do the inserts, using exec

	// exec: const(char[]) sql
	assert(cn.exec("INSERT INTO `execOverloads` VALUES (1, \"aa\")") == 1);
	assert(cn.exec(prepareSQL, 2, "bb") == 1);
	assert(cn.exec(prepareSQL, [MySQLVal(3), MySQLVal("cc")]) == 1);

	// exec: prepared sql
	auto prepared = cn.prepare(prepareSQL);
	prepared.setArgs(4, "dd");
	assert(cn.exec(prepared) == 1);

	assert(cn.exec(prepared, 5, "ee") == 1);
	assert(prepared.getArg(0) == 5);
	assert(prepared.getArg(1) == "ee");

	assert(cn.exec(prepared, [MySQLVal(6), MySQLVal("ff")]) == 1);
	assert(prepared.getArg(0) == 6);
	assert(prepared.getArg(1) == "ff");

	// Check results
	auto rows = cn.query("SELECT * FROM `execOverloads`").array();
	assert(rows.length == 6);

	assert(rows[0].length == 2);
	assert(rows[1].length == 2);
	assert(rows[2].length == 2);
	assert(rows[3].length == 2);
	assert(rows[4].length == 2);
	assert(rows[5].length == 2);

	assert(rows[0][0] == 1);
	assert(rows[0][1] == "aa");
	assert(rows[1][0] == 2);
	assert(rows[1][1] == "bb");
	assert(rows[2][0] == 3);
	assert(rows[2][1] == "cc");
	assert(rows[3][0] == 4);
	assert(rows[3][1] == "dd");
	assert(rows[4][0] == 5);
	assert(rows[4][1] == "ee");
	assert(rows[5][0] == 6);
	assert(rows[5][1] == "ff");
}

@("queryOverloads")
debug(MYSQLN_TESTS)
unittest
{
	import std.array;
	import mysql.test.common;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `queryOverloads`");
	cn.exec("CREATE TABLE `queryOverloads` (
		`i` INTEGER,
		`s` VARCHAR(50)
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `queryOverloads` VALUES (1, \"aa\"), (2, \"bb\"), (3, \"cc\")");

	immutable prepareSQL = "SELECT * FROM `queryOverloads` WHERE `i`=? AND `s`=?";

	// Test query
	{
		SafeRow[] rows;

		// String sql
		rows = cn.query("SELECT * FROM `queryOverloads` WHERE `i`=1 AND `s`=\"aa\"").array;
		assert(rows.length == 1);
		assert(rows[0].length == 2);
		assert(rows[0][0] == 1);
		assert(rows[0][1] == "aa");

		rows = cn.query(prepareSQL, 2, "bb").array;
		assert(rows.length == 1);
		assert(rows[0].length == 2);
		assert(rows[0][0] == 2);
		assert(rows[0][1] == "bb");

		rows = cn.query(prepareSQL, [MySQLVal(3), MySQLVal("cc")]).array;
		assert(rows.length == 1);
		assert(rows[0].length == 2);
		assert(rows[0][0] == 3);
		assert(rows[0][1] == "cc");

		// Prepared sql
		auto prepared = cn.prepare(prepareSQL);
		prepared.setArgs(1, "aa");
		rows = cn.query(prepared).array;
		assert(rows.length == 1);
		assert(rows[0].length == 2);
		assert(rows[0][0] == 1);
		assert(rows[0][1] == "aa");

		rows = cn.query(prepared, 2, "bb").array;
		assert(rows.length == 1);
		assert(rows[0].length == 2);
		assert(rows[0][0] == 2);
		assert(rows[0][1] == "bb");

		rows = cn.query(prepared, [MySQLVal(3), MySQLVal("cc")]).array;
		assert(rows.length == 1);
		assert(rows[0].length == 2);
		assert(rows[0][0] == 3);
		assert(rows[0][1] == "cc");
	}

	// Test queryRow
	{
		Nullable!SafeRow nrow;
		// avoid always saying nrow.get
		SafeRow row() { return nrow.get; }

		// String sql
		nrow = cn.queryRow("SELECT * FROM `queryOverloads` WHERE `i`=1 AND `s`=\"aa\"");
		assert(!nrow.isNull);
		assert(row.length == 2);
		assert(row[0] == 1);
		assert(row[1] == "aa");

		nrow = cn.queryRow(prepareSQL, 2, "bb");
		assert(!nrow.isNull);
		assert(row.length == 2);
		assert(row[0] == 2);
		assert(row[1] == "bb");

		nrow = cn.queryRow(prepareSQL, [MySQLVal(3), MySQLVal("cc")]);
		assert(!nrow.isNull);
		assert(row.length == 2);
		assert(row[0] == 3);
		assert(row[1] == "cc");

		// Prepared sql
		auto prepared = cn.prepare(prepareSQL);
		prepared.setArgs(1, "aa");
		nrow = cn.queryRow(prepared);
		assert(!nrow.isNull);
		assert(row.length == 2);
		assert(row[0] == 1);
		assert(row[1] == "aa");

		nrow = cn.queryRow(prepared, 2, "bb");
		assert(!nrow.isNull);
		assert(row.length == 2);
		assert(row[0] == 2);
		assert(row[1] == "bb");

		nrow = cn.queryRow(prepared, [MySQLVal(3), MySQLVal("cc")]);
		assert(!nrow.isNull);
		assert(row.length == 2);
		assert(row[0] == 3);
		assert(row[1] == "cc");
	}

	// Test queryRowTuple
	{
		int i;
		string s;

		// String sql
		cn.queryRowTuple("SELECT * FROM `queryOverloads` WHERE `i`=1 AND `s`=\"aa\"", i, s);
		assert(i == 1);
		assert(s == "aa");

		// Prepared sql
		auto prepared = cn.prepare(prepareSQL);
		prepared.setArgs(2, "bb");
		cn.queryRowTuple(prepared, i, s);
		assert(i == 2);
		assert(s == "bb");
	}

	// Test queryValue
	{
		Nullable!MySQLVal value;

		// String sql
		value = cn.queryValue("SELECT * FROM `queryOverloads` WHERE `i`=1 AND `s`=\"aa\"");
		assert(!value.isNull);
		assert(value.get.kind != MySQLVal.Kind.Null);
		assert(value.get == 1);

		value = cn.queryValue(prepareSQL, 2, "bb");
		assert(!value.isNull);
		assert(value.get.kind != MySQLVal.Kind.Null);
		assert(value.get == 2);

		value = cn.queryValue(prepareSQL, [MySQLVal(3), MySQLVal("cc")]);
		assert(!value.isNull);
		assert(value.get.kind != MySQLVal.Kind.Null);
		assert(value.get == 3);

		// Prepared sql
		auto prepared = cn.prepare(prepareSQL);
		prepared.setArgs(1, "aa");
		value = cn.queryValue(prepared);
		assert(!value.isNull);
		assert(value.get.kind != MySQLVal.Kind.Null);
		assert(value.get == 1);

		value = cn.queryValue(prepared, 2, "bb");
		assert(!value.isNull);
		assert(value.get.kind != MySQLVal.Kind.Null);
		assert(value.get == 2);

		value = cn.queryValue(prepared, [MySQLVal(3), MySQLVal("cc")]);
		assert(!value.isNull);
		assert(value.get.kind != MySQLVal.Kind.Null);
		assert(value.get == 3);
	}
}
