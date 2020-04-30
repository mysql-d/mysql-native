/// Exceptions defined by mysql-native.
module mysql.exceptions;

import std.algorithm;
import mysql.protocol.packets;

/++
An exception type to distinguish exceptions thrown by this package.
+/
class MYX: Exception
{
@safe pure:
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

/++
The server sent back a MySQL error code and message. If the server is 4.1+,
there should also be an ANSI/ODBC-standard SQLSTATE error code.

See_Also: $(LINK https://dev.mysql.com/doc/refman/5.5/en/error-messages-server.html)
+/
class MYXReceived: MYX
{
	ushort errorCode;
	char[5] sqlState;

@safe pure:

	this(OKErrorPacket okp, string file, size_t line)
	{
		this(okp.message, okp.serverStatus, okp.sqlState, file, line);
	}

	this(string msg, ushort errorCode, char[5] sqlState, string file, size_t line)
	{
		this.errorCode = errorCode;
		this.sqlState = sqlState;
		super("MySQL error: " ~ msg, file, line);
	}
}

/++
Received invalid data from the server which violates the MySQL network protocol.
(Quite possibly mysql-native's fault. Please
$(LINK2 https://github.com/mysql-d/mysql-native/issues, file an issue)
if you receive this.)
+/
class MYXProtocol: MYX
{
@safe pure:
	this(string msg, string file, size_t line)
	{
		super(msg, file, line);
	}
}

/++
Deprecated - No longer thrown by mysql-native.

In previous versions, this had been thrown when attempting to use a
prepared statement which had already been released.

But as of v2.0.0, prepared statements are connection-independent and
automatically registered on connections as needed, so this exception
is no longer used.
+/
deprecated("No longer thrown by mysql-native. You can safely remove all handling of this exception from your code.")
class MYXNotPrepared: MYX
{
@safe pure:
	this(string file = __FILE__, size_t line = __LINE__)
	{
		super("The prepared statement has already been released.", file, line);
	}
}

/++
Common base class of `MYXResultRecieved` and `MYXNoResultRecieved`.

Thrown when making the wrong choice between `mysql.commands.exec` versus `mysql.commands.query`.

The query functions (`mysql.commands.query`, `mysql.commands.queryRow`, etc.)
are for SQL statements such as SELECT that
return results (even if the result set has zero elements.)

The `mysql.commands.exec` functions
are for SQL statements, such as INSERT, that never return result sets,
but may return `rowsAffected`.

Using one of those functions, when the other should have been used instead,
results in an exception derived from this.
+/
class MYXWrongFunction: MYX
{
@safe pure:
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

/++
Thrown when a result set was returned unexpectedly.

Use the query functions (`mysql.commands.query`, `mysql.commands.queryRow`, etc.),
not `mysql.commands.exec` for commands
that return result sets (such as SELECT), even if the result set has zero elements.
+/
class MYXResultRecieved: MYXWrongFunction
{
@safe pure:
	this(string file = __FILE__, size_t line = __LINE__)
	{
		super(
			"A result set was returned. Use the query functions, not exec, "~
			"for commands that return result sets.",
			file, line
		);
	}
}

/++
Thrown when the executed query, unexpectedly, did not produce a result set.

Use the `mysql.commands.exec` functions,
not `mysql.commands.query`/`mysql.commands.queryRow`/etc.
for commands that don't produce result sets (such as INSERT).
+/
class MYXNoResultRecieved: MYXWrongFunction
{
@safe pure:
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(
			"The executed query did not produce a result set. Use the exec "~
			"functions, not query, for commands that don't produce result sets.",
			file, line
		);
	}
}

/++
Thrown when attempting to use a range that's been invalidated.

This can occur when using a `mysql.result.ResultRange` after a new command
has been issued on the same connection.
+/
class MYXInvalidatedRange: MYX
{
@safe pure:
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

@("wrongFunctionException")
debug(MYSQLN_TESTS)
unittest
{
	import std.exception;
	import mysql.commands;
	import mysql.connection;
	import mysql.prepared;
	import mysql.test.common : scopedCn, createCn;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `wrongFunctionException`");
	cn.exec("CREATE TABLE `wrongFunctionException` (
		`val` INTEGER
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");

	immutable insertSQL = "INSERT INTO `wrongFunctionException` VALUES (1), (2)";
	immutable selectSQL = "SELECT * FROM `wrongFunctionException`";
	Prepared preparedInsert;
	Prepared preparedSelect;
	int queryTupleResult;
	assertNotThrown!MYXWrongFunction(cn.exec(insertSQL));
	assertNotThrown!MYXWrongFunction(cn.query(selectSQL).each());
	assertNotThrown!MYXWrongFunction(cn.queryRowTuple(selectSQL, queryTupleResult));
	assertNotThrown!MYXWrongFunction(preparedInsert = cn.prepare(insertSQL));
	assertNotThrown!MYXWrongFunction(preparedSelect = cn.prepare(selectSQL));
	assertNotThrown!MYXWrongFunction(cn.exec(preparedInsert));
	assertNotThrown!MYXWrongFunction(cn.query(preparedSelect).each());
	assertNotThrown!MYXWrongFunction(cn.queryRowTuple(preparedSelect, queryTupleResult));

	assertThrown!MYXResultRecieved(cn.exec(selectSQL));
	assertThrown!MYXNoResultRecieved(cn.query(insertSQL).each());
	assertThrown!MYXNoResultRecieved(cn.queryRowTuple(insertSQL, queryTupleResult));
	assertThrown!MYXResultRecieved(cn.exec(preparedSelect));
	assertThrown!MYXNoResultRecieved(cn.query(preparedInsert).each());
	assertThrown!MYXNoResultRecieved(cn.queryRowTuple(preparedInsert, queryTupleResult));
}
