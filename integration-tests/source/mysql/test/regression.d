/++
This contains regression tests for the issues at:
https://github.com/rejectedsoftware/mysql-native/issues

Regression unittests, like other unittests, are located together with
the units they test.
+/
module mysql.test.regression;

import std.algorithm;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.exception;
import std.range;
import std.socket;
import std.stdio;
import std.string;
import std.traits;
import std.variant;

import mysql.commands;
import mysql.connection;
import mysql.exceptions;
import mysql.prepared;
import mysql.protocol.sockets;
import mysql.result;
import mysql.test.common;

// Issue #24: Driver doesn't like BIT
@("issue24")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);
	ulong rowsAffected;
	cn.exec("DROP TABLE IF EXISTS `issue24`");
	cn.exec(
		"CREATE TABLE `issue24` (
		`bit` BIT,
		`date` DATE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8"
	);
	
	cn.exec("INSERT INTO `issue24` (`bit`, `date`) VALUES (1, '1970-01-01')");
	cn.exec("INSERT INTO `issue24` (`bit`, `date`) VALUES (0, '1950-04-24')");

	auto stmt = cn.prepare("SELECT `bit`, `date` FROM `issue24` ORDER BY `date` DESC");
	auto results = cn.query(stmt).array;
	assert(results.length == 2);
	assert(results[0][0] == true);
	assert(results[0][1] == Date(1970, 1, 1));
	assert(results[1][0] == false);
	assert(results[1][1] == Date(1950, 4, 24));
}

// Issue #28: MySQLProtocolException thrown when using large integers as prepared parameters.
@("issue28")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `issue28`");
	cn.exec("CREATE TABLE IF NOT EXISTS `issue28` (
		`added` DATETIME NOT NULL
	) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8 COLLATE = utf8_bin");
	cn.exec("INSERT INTO `issue28` (added) VALUES (NOW())");

	auto prepared = cn.prepare(
		"SELECT added
		FROM `issue28` WHERE UNIX_TIMESTAMP(added) >= (? - ?)");

	uint baseTimeStamp    = 1371477821;
    uint cacheCutOffLimit = int.max;

	prepared.setArgs(baseTimeStamp, cacheCutOffLimit);
	auto e = collectException( cn.query(prepared).array );
	assert(e !is null);
	auto myxReceived = cast(MYXReceived) e;
	assert(myxReceived !is null);
}

// Issue #33: TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT types treated as ubyte[]
@("issue33")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);
	cn.exec("DROP TABLE IF EXISTS `issue33`");
	cn.exec(
		"CREATE TABLE `issue33` (
		`text` TEXT,
		`blob` BLOB
		) ENGINE=InnoDB DEFAULT CHARSET=utf8"
	);
	
	cn.exec("INSERT INTO `issue33` (`text`, `blob`) VALUES ('hello', 'world')");

	auto stmt = cn.prepare("SELECT `text`, `blob` FROM `issue33`");
	auto results = cn.query(stmt).array;
	assert(results.length == 1);
	auto pText = results[0][0].peek!string();
	auto pBlob = results[0][1].peek!(ubyte[])();
	assert(pText);
	assert(pBlob);
	assert(*pText == "hello");
	assert(*pBlob == cast(ubyte[])"world".dup);
}

// Issue #39: Unsupported SQL type NEWDECIMAL
@("issue39-NEWDECIMAL")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);
	auto rows = cn.query("SELECT SUM(123.456)").array;
	assert(rows.length == 1);
	assert(rows[0][0] == "123.456");
}

// Issue #40: Decoding LCB value for large feilds
// And likely Issue #18: select varchar - thinks the package is incomplete while it's actually complete
@("issue40")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);
	cn.exec("DROP TABLE IF EXISTS `issue40`");
	cn.exec(
		"CREATE TABLE `issue40` (
		`str` varchar(255)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8"
	);

	auto longString = repeat('a').take(251).array().idup;
	cn.exec("INSERT INTO `issue40` VALUES('"~longString~"')");
	cn.query("SELECT * FROM `issue40`");

	cn.exec("DELETE FROM `issue40`");

	longString = repeat('a').take(255).array().idup;
	cn.exec("INSERT INTO `issue40` VALUES('"~longString~"')");
	cn.query("SELECT * FROM `issue40`");
}

// Issue #52: execSQLSequence doesn't work with map
@("issue52")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);

	assert(cn.query("SELECT 1").array.length == 1);
	assert(cn.query("SELECT 1").map!(r => r).array.length == 1);
	assert(cn.query("SELECT 1").array.map!(r => r).array.length == 1);
}

// Issue #56: Result set quantity does not equal MySQL rows quantity
@("issue56")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);
	cn.exec("DROP TABLE IF EXISTS `issue56`");
	cn.exec("CREATE TABLE `issue56` (a datetime DEFAULT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	
	cn.exec("INSERT INTO `issue56` VALUES
		('2015-03-28 00:00:00')
		,('2015-03-29 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-04-01 00:00:00')
		,('2015-04-02 00:00:00')
		,('2015-04-03 00:00:00')
		,('2015-04-04 00:00:00')");

	auto stmt = cn.prepare("SELECT a FROM `issue56`");
	auto res = cn.query(stmt).array;
	assert(res.length == 10);
}

// Issue #66: Can't connect when omitting default database
@("issue66")
debug(MYSQLN_TESTS)
unittest
{
	auto a = Connection.parseConnectionString(testConnectionStr);

	{
		// Sanity check:
		auto cn = new Connection(a[0], a[1], a[2], a[3], to!ushort(a[4]));
		scope(exit) cn.close();
	}

	{
		// Ensure it works without a default database
		auto cn = new Connection(a[0], a[1], a[2], "", to!ushort(a[4]));
		scope(exit) cn.close();
	}
}

// Issue #117: Server packet out of order when Prepared is destroyed too early
@("issue117")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);

	struct S
	{
		this(ResultRange x) { r = x; } // destroying x kills the range
		ResultRange r;
		alias r this;
	}

	cn.exec("DROP TABLE IF EXISTS `issue117`");
	cn.exec("CREATE TABLE `issue117` (a INTEGER) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `issue117` (a) VALUES (1)");

	auto r = cn.query("SELECT * FROM `issue117`");
	assert(!r.empty);

	auto s = S(cn.query("SELECT * FROM `issue117`"));
	assert(!s.empty);
}

// Issue #133: `queryValue`: result of 1 row & field `NULL` check inconsistency / error
@("issue133")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);
	
	cn.exec("DROP TABLE IF EXISTS `issue133`");
	cn.exec("CREATE TABLE `issue133` (a BIGINT UNSIGNED NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `issue133` (a) VALUES (NULL)");
	
	auto prep = cn.prepare("SELECT a FROM `issue133`");
	auto value = cn.queryValue(prep);

	assert(!value.isNull);
	assert(value.get.type == typeid(typeof(null)));
}

// Issue #139: Server packet out of order when Prepared is destroyed too early
@("issue139")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);

	// Sanity check
	{
		ResultRange result;

		auto prep = cn.prepare("SELECT ?");
		prep.setArgs("Hello world");
		result = cn.query(prep);

		result.close();
	}
	
	// Should not throw server packet out of order
	{
		ResultRange result;
		{
			auto prep = cn.prepare("SELECT ?");
			prep.setArgs("Hello world");
			result = cn.query(prep);
		}

		result.close();
	}
}

/+
Issue #170: Assertion when concurrently using multiple LockedConnection.

The root problem here was that `MySQLPool.lockConnection` was accidentally
returning a `Connection` instead of a `LockedConnection!Connection`.
This meant the `LockedConnection` went out-of-scope and returned the
connection to the pool as soon as `MySQLPool.lockConnection` returned.
So the `Connection` returned was no longer locked and got handed out
to the next fiber which requested it, even if the first fiber was
still using it.

So, this test ensures lockConnection doesn't return a connection that's already in use.
+/
@("issue170")
version(Have_vibe_core)
debug(MYSQLN_TESTS)
unittest
{
	import mysql.commands;
	import mysql.pool;
	int count=0;

	auto pool = new MySQLPool(testConnectionStr);
	pool.onNewConnection = (Connection conn) { count++; };
	assert(count == 0);

	auto cn1 = pool.lockConnection();
	assert(count == 1);

	auto cn2 = pool.lockConnection();
	assert(count == 2);

	assert(cn1 != cn2);
}

// 
@("timestamp")
debug(MYSQLN_TESTS)
unittest
{
	import mysql.types;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `issueX`");
	cn.exec("CREATE TABLE `issueX` (a TIMESTAMP) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	
	auto stmt = cn.prepare("INSERT INTO `issueX` (`a`) VALUES (?)");
	stmt.setArgs(Timestamp(2011_11_11_12_20_02UL));
	cn.exec(stmt);
}

// JSON and GEOMETRY columns used to fail with an assertion ("Unsupported SQL type")
@("json-geometry")
debug(MYSQLN_TESTS)
unittest
{
	mixin(scopedCn);
	cn.exec("DROP TABLE IF EXISTS `json_geometry`");
	cn.exec(
		"CREATE TABLE `json_geometry` (
		`id` INT,
		`doc` JSON,
		`shape` GEOMETRY
		) ENGINE=InnoDB DEFAULT CHARSET=utf8"
	);
	cn.exec(`INSERT INTO json_geometry VALUES (1, '{"a": [1, 2]}', ST_GeomFromText('POINT(1 2)'))`);

	void check(T)(T row)
	{
		assert(row[0] == `{"a": [1, 2]}`);
		// GEOMETRY: a 4-byte SRID, then WKB: byte order 1 (little endian), type 1 (point), x, y
		auto shape = row[1].get!(ubyte[]);
		assert(shape.length == 25);
		assert(shape[4] == 1 && shape[5 .. 9] == [1, 0, 0, 0]);
		assert(row[2] == "[1, 2]");
	}

	// Text protocol
	check(cn.query("SELECT `doc`, `shape`, JSON_ARRAY(1, 2) FROM `json_geometry`").front);
	// Binary protocol
	auto stmt = cn.prepare("SELECT `doc`, `shape`, JSON_ARRAY(1, 2) FROM `json_geometry` WHERE `id` = ?");
	stmt.setArgs(1);
	check(cn.query(stmt).front);
}
