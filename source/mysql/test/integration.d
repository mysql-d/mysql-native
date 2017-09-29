module mysql.test.integration;

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
import std.typecons;
import std.variant;

import mysql.commands;
import mysql.connection;
import mysql.exceptions;
import mysql.metadata;
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packets;
import mysql.protocol.sockets;
import mysql.result;
import mysql.test.common;

alias indexOf = std.string.indexOf; // Needed on DMD 2.064.2

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	// Test connect/disconnect
	mixin(scopedCn);
}

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);

	// These may vary according to the server setup
	//assert(cn.protocol == 10);
	//assert(cn.serverVersion == "5.1.54-1ubuntu4");
	//assert(cn.serverCapabilities == 0b1111011111111111);
	//assert(cn.serverStatus == 2);
	//assert(cn.charSet == 8);
	try {
		cn.selectDB("rabbit does not exist");
	}
	catch (Exception x)
	{
		assert(x.msg.indexOf("Access denied") > 0 || x.msg.indexOf("Unknown database") > 0);
	}
	auto okp = cn.pingServer();
	assert(okp.serverStatus == 2);
	try {
		okp = cn.refreshServer(RefreshFlags.GRANT);
	}
	catch (Exception x)
	{
		assert(x.msg.indexOf("Access denied") > 0);
	}
	string stats = cn.serverStats();
	assert(stats.indexOf("Uptime") == 0);
	cn.enableMultiStatements(true);   // Need to be tested later with a prepared "CALL"
	cn.enableMultiStatements(false);
}

debug(MYSQL_INTEGRATION_TESTS)
{
	void initBaseTestTables(Connection cn)
	{
		auto cmd = Command(cn);
		ulong rowsAffected;
		cmd.sql = 
			"DROP TABLE IF EXISTS `basetest`";
		cmd.execSQL(rowsAffected);
		cmd.sql = 
			"CREATE TABLE `basetest` (
			`boolcol` bit(1),
			`bytecol` tinyint(4),
			`ubytecol` tinyint(3) unsigned,
			`shortcol` smallint(6),
			`ushortcol` smallint(5) unsigned,
			`intcol` int(11),
			`uintcol` int(10) unsigned,
			`longcol` bigint(20),
			`ulongcol` bigint(20) unsigned,
			`charscol` char(10),
			`stringcol` varchar(50),
			`bytescol` tinyblob,
			`datecol` date,
			`timecol` time,
			`dtcol` datetime,
			`doublecol` double,
			`floatcol` float,
			`nullcol` int(11),
			`decimalcol` decimal(11,4)
			) ENGINE=InnoDB DEFAULT CHARSET=latin1";
		cmd.execSQL(rowsAffected);
		cmd.sql = 
			"DROP TABLE IF EXISTS `tblob`";
		cmd.execSQL(rowsAffected);
		cmd.sql = 
			"CREATE TABLE `tblob` (
			`foo` int
			) ENGINE=InnoDB DEFAULT CHARSET=latin1";
		cmd.execSQL(rowsAffected);
	}
}

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	struct X
	{
		int a, b, c;
		string s;
		double d;
	}
	bool ok = true;

	mixin(scopedCn);
	initBaseTestTables(cn);

	ulong ra;
	auto c1 = Command(cn);

	c1.sql = "delete from basetest";
	c1.execSQL(ra);

	c1.sql = "insert into basetest values(" ~
		"1, -128, 255, -32768, 65535, 42, 4294967295, -9223372036854775808, 18446744073709551615, 'ABC', " ~
		"'The quick brown fox', 0x000102030405060708090a0b0c0d0e0f, '2007-01-01', " ~
		"'12:12:12', '2007-01-01 12:12:12', 1.234567890987654, 22.4, NULL, 11234.4325)";
	c1.execSQL(ra);

	c1.sql = "select bytecol from basetest limit 1";
	ResultSet rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == -128);
	c1.sql = "select ubytecol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs.front[0] == 255);
	c1.sql = "select shortcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == short.min);
	c1.sql = "select ushortcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == ushort.max);
	c1.sql = "select intcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == 42);
	c1.sql = "select uintcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == uint.max);
	c1.sql = "select longcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == long.min);
	c1.sql = "select ulongcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == ulong.max);
	c1.sql = "select charscol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0].toString() == "ABC");
	c1.sql = "select stringcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0].toString() == "The quick brown fox");
	c1.sql = "select bytescol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0].toString() == "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]");
	c1.sql = "select datecol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	Date d = rs[0][0].get!(Date);
	assert(d.year == 2007 && d.month == 1 && d.day == 1);
	c1.sql = "select timecol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	TimeOfDay t = rs[0][0].get!(TimeOfDay);
	assert(t.hour == 12 && t.minute == 12 && t.second == 12);
	c1.sql = "select dtcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	DateTime dt = rs[0][0].get!(DateTime);
	assert(dt.year == 2007 && dt.month == 1 && dt.day == 1 && dt.hour == 12 && dt.minute == 12 && dt.second == 12);
	c1.sql = "select doublecol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0].toString() == "1.23457");
	c1.sql = "select floatcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0].toString() == "22.4");
	c1.sql = "select decimalcol from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == "11234.4325");

	c1.sql = "select * from basetest limit 1";
	rs = c1.execSQLResult();
	assert(rs.length == 1);
	assert(rs[0][0] == true);
	assert(rs[0][1] == -128);
	assert(rs[0][2] == 255);
	assert(rs[0][3] == short.min);
	assert(rs[0][4] == ushort.max);
	assert(rs[0][5] == 42);
	assert(rs[0][6] == uint.max);
	assert(rs[0][7] == long.min);
	assert(rs[0][8] == ulong.max);
	assert(rs[0][9].toString() == "ABC");
	assert(rs[0][10].toString() == "The quick brown fox");
	assert(rs[0][11].toString() == "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]");
	d = rs[0][12].get!(Date);
	assert(d.year == 2007 && d.month == 1 && d.day == 1);
	t = rs[0][13].get!(TimeOfDay);
	assert(t.hour == 12 && t.minute == 12 && t.second == 12);
	dt = rs[0][14].get!(DateTime);
	assert(dt.year == 2007 && dt.month == 1 && dt.day == 1 && dt.hour == 12 && dt.minute == 12 && dt.second == 12);
	assert(rs[0][15].toString() == "1.23457");
	assert(rs[0][16].toString() == "22.4");
	assert(rs[0].isNull(17) == true);
	assert(rs[0][18] == "11234.4325", rs[0][18].toString());

	c1.sql = "select bytecol, ushortcol, intcol, charscol, floatcol from basetest limit 1";
	rs = c1.execSQLResult();
	X x;
	rs[0].toStruct(x);
	assert(x.a == -128 && x.b == 65535 && x.c == 42 && x.s == "ABC" && to!string(x.d) == "22.4");

	c1.sql = "select * from basetest limit 1";
	c1.prepare();
	rs = c1.execPreparedResult();
	assert(rs.length == 1);
	assert(rs[0][0] == true);
	assert(rs[0][1] == -128);
	assert(rs[0][2] == 255);
	assert(rs[0][3] == short.min);
	assert(rs[0][4] == ushort.max);
	assert(rs[0][5] == 42);
	assert(rs[0][6] == uint.max);
	assert(rs[0][7] == long.min);
	assert(rs[0][8] == ulong.max);
	assert(rs[0][9].toString() == "ABC");
	assert(rs[0][10].toString() == "The quick brown fox");
	assert(rs[0][11].toString() == "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]");
	d = rs[0][12].get!(Date);
	assert(d.year == 2007 && d.month == 1 && d.day == 1);
	t = rs[0][13].get!(TimeOfDay);
	assert(t.hour == 12 && t.minute == 12 && t.second == 12);
	dt = rs[0][14].get!(DateTime);
	assert(dt.year == 2007 && dt.month == 1 && dt.day == 1 && dt.hour == 12 && dt.minute == 12 && dt.second == 12);
	assert(rs[0][15].toString() == "1.23457");
	assert(rs[0][16].toString() == "22.4");
	assert(rs[0].isNull(17) == true);
	assert(rs[0][18] == "11234.4325", rs[0][18].toString());

	c1.sql = "insert into basetest (intcol, stringcol) values(?, ?)";
	c1.prepare();
	Variant[] va;
	va.length = 2;
	va[0] = 42;
	va[1] = "The quick brown fox x";
	c1.bindParameters(va);
	foreach (int i; 0..20)
	{
		c1.execPrepared(ra);
		c1.param(0) += 1;
		c1.param(1) ~= "x";
	}

	c1.sql = "insert into basetest (intcol, stringcol) values(?, ?)";
	c1.prepare();
	//Variant[] va;
	va.length = 2;
	va[0] = 42;
	va[1] = "The quick brown fox x";
	c1.bindParameters(va);
	foreach (int i; 0..20)
	{
		c1.execPrepared(ra);

		va[0] = c1.getArg(0).get!int + 1;
		va[1] = c1.getArg(1).get!string ~ "x";
		c1.bindParameters(va);
	}

	int a;
	string b;
	c1.sql = "select intcol, stringcol from basetest where bytecol=-128 limit 1";
	c1.execSQLTuple(a, b);
	assert(a == 42 && b == "The quick brown fox");

	c1.sql = "select intcol, stringcol from basetest where bytecol=? limit 1";
	c1.prepare();
	Variant[] va2;
	va2.length = 1;
	va2[0] = cast(byte) -128;
	c1.bindParameters(va2);
	a = 0;
	b = "";
	c1.execPreparedTuple(a, b);
	assert(a == 42 && b == "The quick brown fox");

	c1.sql = "update basetest set intcol=? where bytecol=-128";
	c1.prepare();
	int referred = 555;
	c1.bindParameter(referred, 0);
	c1.execPrepared(ra);
	referred = 666;
	c1.execPrepared(ra);
	c1.sql = "select intcol from basetest where bytecol = -128";
	int referredBack;
	c1.execSQLTuple(referredBack);
	assert(referredBack == 666);

	// Test execFunction()
	exec(cn, `DROP FUNCTION IF EXISTS hello`);
	exec(cn, `
		CREATE FUNCTION hello (s CHAR(20))
		RETURNS CHAR(50) DETERMINISTIC
		RETURN CONCAT('Hello ',s,'!')
	`);

	rs = querySet(cn, "select hello ('World')");
	assert(rs.length == 1);
	assert(rs[0][0] == "Hello World!");

	string g = "Gorgeous";
	string reply;

	c1.sql = "";
	bool nonNull = c1.execFunction("hello", reply, g);
	assert(nonNull && reply == "Hello Gorgeous!");
	g = "Hotlips";
	nonNull = c1.execFunction("hello", reply, g);
	assert(nonNull && reply == "Hello Hotlips!");

	// Test execProcedure()
	exec(cn, `DROP PROCEDURE IF EXISTS insert2`);
	exec(cn, `
		CREATE PROCEDURE insert2 (IN p1 INT, IN p2 CHAR(50))
		BEGIN
			INSERT INTO basetest (intcol, stringcol) VALUES(p1, p2);
		END
	`);
	g = "inserted string 1";
	int m = 2001;
	c1.sql = "";
	c1.execProcedure("insert2", m, g);

	c1.sql = "select stringcol from basetest where intcol=2001";
	c1.execSQLTuple(reply);
	assert(reply == g);

	g = "inserted string 2";
	m = 2002;
	c1.sql = "";
	c1.execProcedure("insert2", m, g);

	c1.sql = "select stringcol from basetest where intcol=2002";
	c1.execSQLTuple(reply);
	assert(reply == g);

/+
	c1.sql = "delete from tblob";
	c1.execSQL(ra);
	c1.sql = "insert into tblob values(321, NULL, 22.4, NULL, '2011-11-05 11:52:00')";
	c1.execSQL(ra);
+/
	size_t delegate(ubyte[]) foo()
	{
		size_t n = 20000000;
		uint cp = 0;

		void fill(ubyte[] a, size_t m)
		{
			foreach (size_t i; 0..m)
			{
				a[i] = cast(ubyte) (cp & 0xff);
				cp++;
			}
		}

		size_t dg(ubyte[] dest)
		{
			size_t len = dest.length;
			if (n >= len)
			{
				fill(dest, len);
				n -= len;
				return len;
			}
			fill(dest, n);
			return n;
		}

		return &dg;
	}
/+
	c1.sql = "update tblob set lob=?, lob2=? where ikey=321";
	c1.prepare();
	ubyte[] uba;
	ubyte[] uba2;
	c1.bindParameter(uba, 0, PSN(0, false, SQLType.LONGBLOB, 10000, foo()));
	c1.bindParameter(uba2, 1, PSN(1, false, SQLType.LONGBLOB, 10000, foo()));
	c1.execPrepared(ra);

	uint got1, got2;
	bool verified1, verified2;
	void delegate(ubyte[], bool) bar1(ref uint got, ref bool  verified)
	{
		got = 0;
		verified = true;

		void dg(ubyte[] ba, bool finished)
		{
			foreach (uint; 0..ba.length)
			{
				if (verified && ba[i] != ((got+i) & 0xff))
				verified = false;
			}
			got += ba.length;
		}
		return &dg;
	}

	void delegate(ubyte[], bool) bar2(ref uint got, ref bool  verified)
	{
		got = 0;
		verified = true;

		void dg(ubyte[] ba, bool finished)
		{
			foreach (size_t i; 0..ba.length)
			{
				if (verified && ba[i] != ((got+i) & 0xff))
					verified = false;
			}
			got += ba.length;
		}
		return &dg;
	}

	c1.sql = "select * from tblob limit 1";
	rs = c1.execSQLResult();
	ubyte[] blob = rs[0][1].get!(ubyte[]);
	ubyte[] blob2 = rs[0][3].get!(ubyte[]);
	DateTime dt4 = rs[0][4].get!(DateTime);
	writefln("blob. lengths %d %d", blob.length, blob2.length);
	writeln(to!string(dt4));


	c1.sql = "select * from tblob limit 1";
	CSN[] csa = [ CSN(1, 0xfc, 100000, bar1(got1, verified1)), CSN(3, 0xfc, 100000, bar2(got2, verified2)) ];
	rs = c1.execSQLResult(csa);
	writefln("1) %d, %s", got1, verified1);
	writefln("2) %d, %s", got2, verified2);
	DateTime dt4 = rs[0][4].get!(DateTime);
	writeln(to!string(dt4));
+/
}

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto schemaName = cn.currentDB;
	MetaData md = MetaData(cn);
	string[] dbList = md.databases();
	int count = 0;
	foreach (string db; dbList)
	{
		if (db == schemaName || db == "information_schema")
			count++;
	}
	assert(count == 2);
	
	initBaseTestTables(cn);
	
	string[] tList = md.tables();
	count = 0;
	foreach (string t; tList)
	{
		if (t == "basetest" || t == "tblob")
			count++;
	}
	assert(count == 2);

	ColumnInfo[] ca = md.columns("basetest");
	assert( ca[0].schema == schemaName && ca[0].table == "basetest" && ca[0].name == "boolcol" && ca[0].index == 0 &&
			ca[0].defaultNull && ca[0].nullable && ca[0].type == "bit" && ca[0].charsMax == -1 && ca[0].octetsMax == -1 &&
			ca[0].numericPrecision == 1 && ca[0].numericScale == -1 && ca[0].charSet == "<NULL>" && ca[0].collation == "<NULL>"  &&
			ca[0].colType == "bit(1)");
	assert( ca[1].schema == schemaName && ca[1].table == "basetest" && ca[1].name == "bytecol" && ca[1].index == 1 &&
			ca[1].defaultNull && ca[1].nullable && ca[1].type == "tinyint" && ca[1].charsMax == -1 && ca[1].octetsMax == -1 &&
			ca[1].numericPrecision == 3 && ca[1].numericScale == 0 && ca[1].charSet == "<NULL>" && ca[1].collation == "<NULL>"  &&
			ca[1].colType == "tinyint(4)");
	assert( ca[2].schema == schemaName && ca[2].table == "basetest" && ca[2].name == "ubytecol" && ca[2].index == 2 &&
			ca[2].defaultNull && ca[2].nullable && ca[2].type == "tinyint" && ca[2].charsMax == -1 && ca[2].octetsMax == -1 &&
			ca[2].numericPrecision == 3 && ca[2].numericScale == 0 && ca[2].charSet == "<NULL>" && ca[2].collation == "<NULL>"  &&
			ca[2].colType == "tinyint(3) unsigned");
	assert( ca[3].schema == schemaName && ca[3].table == "basetest" && ca[3].name == "shortcol" && ca[3].index == 3 &&
			ca[3].defaultNull && ca[3].nullable && ca[3].type == "smallint" && ca[3].charsMax == -1 && ca[3].octetsMax == -1 &&
			ca[3].numericPrecision == 5 && ca[3].numericScale == 0 && ca[3].charSet == "<NULL>" && ca[3].collation == "<NULL>"  &&
			ca[3].colType == "smallint(6)");
	assert( ca[4].schema == schemaName && ca[4].table == "basetest" && ca[4].name == "ushortcol" && ca[4].index == 4 &&
			ca[4].defaultNull && ca[4].nullable && ca[4].type == "smallint" && ca[4].charsMax == -1 && ca[4].octetsMax == -1 &&
			ca[4].numericPrecision == 5 && ca[4].numericScale == 0 && ca[4].charSet == "<NULL>" && ca[4].collation == "<NULL>"  &&
			ca[4].colType == "smallint(5) unsigned");
	assert( ca[5].schema == schemaName && ca[5].table == "basetest" && ca[5].name == "intcol" && ca[5].index == 5 &&
			ca[5].defaultNull && ca[5].nullable && ca[5].type == "int" && ca[5].charsMax == -1 && ca[5].octetsMax == -1 &&
			ca[5].numericPrecision == 10 && ca[5].numericScale == 0 && ca[5].charSet == "<NULL>" && ca[5].collation == "<NULL>"  &&
			ca[5].colType == "int(11)");
	assert( ca[6].schema == schemaName && ca[6].table == "basetest" && ca[6].name == "uintcol" && ca[6].index == 6 &&
			ca[6].defaultNull && ca[6].nullable && ca[6].type == "int" && ca[6].charsMax == -1 && ca[6].octetsMax == -1 &&
			ca[6].numericPrecision == 10 && ca[6].numericScale == 0 && ca[6].charSet == "<NULL>" && ca[6].collation == "<NULL>"  &&
			ca[6].colType == "int(10) unsigned");
	assert( ca[7].schema == schemaName && ca[7].table == "basetest" && ca[7].name == "longcol" && ca[7].index == 7 &&
			ca[7].defaultNull && ca[7].nullable && ca[7].type == "bigint" && ca[7].charsMax == -1 && ca[7].octetsMax == -1 &&
			ca[7].numericPrecision == 19 && ca[7].numericScale == 0 && ca[7].charSet == "<NULL>" && ca[7].collation == "<NULL>"  &&
			ca[7].colType == "bigint(20)");
	assert( ca[8].schema == schemaName && ca[8].table == "basetest" && ca[8].name == "ulongcol" && ca[8].index == 8 &&
			ca[8].defaultNull && ca[8].nullable && ca[8].type == "bigint" && ca[8].charsMax == -1 && ca[8].octetsMax == -1 &&
			//TODO: I'm getting numericPrecision==19, figure it out later
			/+ca[8].numericPrecision == 20 &&+/ ca[8].numericScale == 0 && ca[8].charSet == "<NULL>" && ca[8].collation == "<NULL>"  &&
			ca[8].colType == "bigint(20) unsigned");
	assert( ca[9].schema == schemaName && ca[9].table == "basetest" && ca[9].name == "charscol" && ca[9].index == 9 &&
			ca[9].defaultNull && ca[9].nullable && ca[9].type == "char" && ca[9].charsMax == 10 && ca[9].octetsMax == 10 &&
			ca[9].numericPrecision == -1 && ca[9].numericScale == -1 && ca[9].charSet == "latin1" && ca[9].collation == "latin1_swedish_ci"  &&
			ca[9].colType == "char(10)");
	assert( ca[10].schema == schemaName && ca[10].table == "basetest" && ca[10].name == "stringcol" && ca[10].index == 10 &&
			ca[10].defaultNull && ca[10].nullable && ca[10].type == "varchar" && ca[10].charsMax == 50 && ca[10].octetsMax == 50 &&
			ca[10].numericPrecision == -1 && ca[10].numericScale == -1 && ca[10].charSet == "latin1" && ca[10].collation == "latin1_swedish_ci"  &&
			ca[10].colType == "varchar(50)");
	assert( ca[11].schema == schemaName && ca[11].table == "basetest" && ca[11].name == "bytescol" && ca[11].index == 11 &&
			ca[11].defaultNull && ca[11].nullable && ca[11].type == "tinyblob" && ca[11].charsMax == 255 && ca[11].octetsMax == 255 &&
			ca[11].numericPrecision == -1 && ca[11].numericScale == -1 && ca[11].charSet == "<NULL>" && ca[11].collation == "<NULL>"  &&
			ca[11].colType == "tinyblob");
	assert( ca[12].schema == schemaName && ca[12].table == "basetest" && ca[12].name == "datecol" && ca[12].index == 12 &&
			ca[12].defaultNull && ca[12].nullable && ca[12].type == "date" && ca[12].charsMax == -1 && ca[12].octetsMax == -1 &&
			ca[12].numericPrecision == -1 && ca[12].numericScale == -1 && ca[12].charSet == "<NULL>" && ca[12].collation == "<NULL>"  &&
			ca[12].colType == "date");
	assert( ca[13].schema == schemaName && ca[13].table == "basetest" && ca[13].name == "timecol" && ca[13].index == 13 &&
			ca[13].defaultNull && ca[13].nullable && ca[13].type == "time" && ca[13].charsMax == -1 && ca[13].octetsMax == -1 &&
			ca[13].numericPrecision == -1 && ca[13].numericScale == -1 && ca[13].charSet == "<NULL>" && ca[13].collation == "<NULL>"  &&
			ca[13].colType == "time");
	assert( ca[14].schema == schemaName && ca[14].table == "basetest" && ca[14].name == "dtcol" && ca[14].index == 14 &&
			ca[14].defaultNull && ca[14].nullable && ca[14].type == "datetime" && ca[14].charsMax == -1 && ca[14].octetsMax == -1 &&
			ca[14].numericPrecision == -1 && ca[14].numericScale == -1 && ca[14].charSet == "<NULL>" && ca[14].collation == "<NULL>"  &&
			ca[14].colType == "datetime");
	assert( ca[15].schema == schemaName && ca[15].table == "basetest" && ca[15].name == "doublecol" && ca[15].index == 15 &&
			ca[15].defaultNull && ca[15].nullable && ca[15].type == "double" && ca[15].charsMax == -1 && ca[15].octetsMax == -1 &&
			ca[15].numericPrecision == 22 && ca[15].numericScale == -1 && ca[15].charSet == "<NULL>" && ca[15].collation == "<NULL>"  &&
			ca[15].colType == "double");
	assert( ca[16].schema == schemaName && ca[16].table == "basetest" && ca[16].name == "floatcol" && ca[16].index == 16 &&
			ca[16].defaultNull && ca[16].nullable && ca[16].type == "float" && ca[16].charsMax == -1 && ca[16].octetsMax == -1 &&
			ca[16].numericPrecision == 12 && ca[16].numericScale == -1 && ca[16].charSet == "<NULL>" && ca[16].collation == "<NULL>"  &&
			ca[16].colType == "float");
	assert( ca[17].schema == schemaName && ca[17].table == "basetest" && ca[17].name == "nullcol" && ca[17].index == 17 &&
			ca[17].defaultNull && ca[17].nullable && ca[17].type == "int" && ca[17].charsMax == -1 && ca[17].octetsMax == -1 &&
			ca[17].numericPrecision == 10 && ca[17].numericScale == 0 && ca[17].charSet == "<NULL>" && ca[17].collation == "<NULL>"  &&
			ca[17].colType == "int(11)");
	assert( ca[18].schema == schemaName && ca[18].table == "basetest" && ca[18].name == "decimalcol" && ca[18].index == 18 &&
			ca[18].defaultNull && ca[18].nullable && ca[18].type == "decimal" && ca[18].charsMax == -1 && ca[18].octetsMax == -1 &&
			ca[18].numericPrecision == 11 && ca[18].numericScale == 4 && ca[18].charSet == "<NULL>" && ca[18].collation == "<NULL>"  &&
			ca[18].colType == "decimal(11,4)");
	MySQLProcedure[] pa = md.functions();
	//assert(pa[0].db == schemaName && pa[0].name == "hello" && pa[0].type == "FUNCTION");
	//pa = md.procedures();
	//assert(pa[0].db == schemaName && pa[0].name == "insert2" && pa[0].type == "PROCEDURE");
}

/+
The following tests are borrowed from simendsjo's fork at:
https://github.com/simendsjo/mysqln

For easier maintenance, I've attempted to keep these as close to simendsjo's
version as possible. Code that doesn't currently work with this version of
mysql-native is not deleted or replaced, but commented out, sometimes with a
modified version immediately below.
+/

// Bind values in prepared statements
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	cn.exec("DROP TABLE IF EXISTS manytypes");
	cn.exec( "CREATE TABLE manytypes ("
			~"  i    INT"
			~", f    FLOAT"
			~", dttm DATETIME"
			~", dt   DATE"
			~")");

	//DataSet ds;
	ResultSet rs;
	//Table tbl;
	Row row;
	Command cmd;
	Variant value;

	// Index out of bounds throws
	/+
	try
	{
		cn.query_("SELECT TRUE", 1);
		assert(0);
	}
	catch(Exception ex) {}
	+/

	// Select without result
	cn.truncate("manytypes");
	cn.exec("INSERT INTO manytypes (i, f) VALUES (1, NULL)");
	cmd = cn.prepareCmd("SELECT * FROM manytypes WHERE i = ?");
	{
		auto val = 2;
		cmd.bind(0, val);
	}
	//ds = cmd.query_();
	//assert(ds.length == 1);
	//assert(ds[0].length == 0);
	rs = cmd.query_();
	assert(rs.length == 0);

	// Bind single primitive value
	cn.truncate("manytypes");
	cn.exec("INSERT INTO manytypes (i, f) VALUES (1, NULL)");
	cmd = cn.prepareCmd("SELECT * FROM manytypes WHERE i = ?");
	{
		auto val = 1;
		cmd.bind(0, val);
	}
	cmd.querySingle();

	// Bind multiple primitive values
	cn.truncate("manytypes");
	cn.exec("INSERT INTO manytypes (i, f) VALUES (1, 2)");
	{
		auto val1 = 1;
		auto val2 = 2;
		row = cn.querySingle("SELECT * FROM manytypes WHERE i = ? AND f = ?", val1, val2);
	}
	assert(row[0] == 1);
	assert(row[1] == 2);

	/+
	// Insert null - params defaults to null
	cn.truncate("manytypes");
	cn.prepareCmd("INSERT INTO manytypes (i, f) VALUES (1, ?)" ).exec();
	cn.assertScalar!int("SELECT i FROM manytypes WHERE f IS NULL", 1);
	+/

	// Insert null
	cn.truncate("manytypes");
	{
		auto val = null;
		cn.execCmd("INSERT INTO manytypes (i, f) VALUES (1, ?)", val);
	}
	cn.assertScalar!int("SELECT i FROM manytypes WHERE f IS NULL", 1);

	// select where null
	cn.truncate("manytypes");
	cn.exec("INSERT INTO manytypes (i, f) VALUES (1, NULL)");
	{
		auto val = null;
		value = cn.queryScalar("SELECT i FROM manytypes WHERE f <=> ?", val);
	}
	assert(value.get!int == 1);

	// rebind parameter
	/+
	cn.truncate("manytypes");
	cn.exec("INSERT INTO manytypes (i, f) VALUES (1, NULL)");
	cmd = cn.prepareCmd("SELECT i FROM manytypes WHERE f <=> ?");
	cmd.bind(0, 1);
	tbl = cmd.query_()[0];
	assert(tbl.length == 0);
	cmd.bind(0, null);
	assert(cmd.queryScalar().get!int == 1);
	+/
}


// Simple commands
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);

	//cn.ping();
	cn.pingServer();
	//assert(cn.statistics(), "COM_STATISTICS didn't return a result");
	assert(cn.serverStats(), "COM_STATISTICS didn't return a result");

	cn.initDB(cn.currentDB);
	try
	{
		cn.initDB("this cannot exist");
		assert(false);
	} catch(/+MySQLErrorPacketException+/MySQLReceivedException ex) {
		assert(ex./+errorPacket.+/errorCode == 1044 || // Access Denied
				ex./+errorPacket.+/errorCode == 1049, // BAD_DB_ERROR
				"Unexpected error code when connecting to non-existing schema");
	}

}
/+
// COM_FIELD_LIST and some ColumnDescription
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);

	cn.initDB("information_schema");
	try
	{
		cn.fieldList("this one doesn't exist", "%");
		assert(false);
	}
	catch(MySQLErrorPacketException ex)
	{
		assert(ex.errorPacket.errorCode == 1146, // Table doesn't exist
				"Unexpected error code when table doesn't exist");
	}

	// We don't expect this table to change much, so we,ll test this
	auto fields = cn.fieldList("character_sets", "%");
	assert(fields.length == 4);

	auto field = fields[0];
	assert(field.schema == "information_schema");
	assert(field.table == "character_sets");
	// Skip originalTable. Seems like it changes between runs as it references
	// a temporary file
	assert(field.name == "CHARACTER_SET_NAME");
	assert(field.originalName == field.name);
	// Skip charset. Think it might be defined by the default character set for
	// the database.
	assert(field.length == 96);
	assert(field.type == SQLType.VARSTRING);
	assert(field.flags == FieldFlags.NOT_NULL);
	assert(field.scale == 0);
	assert(field.defaultValues == "");

	field = fields[1];
	assert(field.schema == "information_schema");
	assert(field.table == "character_sets");
	// Skip originalTable. Seems like it changes between runs as it references
	// a temporary file
	assert(field.name == "DEFAULT_COLLATE_NAME");
	assert(field.originalName == field.name);
	// Skip charset. Think it might be defined by the default character set for
	// the database.
	assert(field.length == 96);
	assert(field.type == SQLType.VARSTRING);
	assert(field.flags == FieldFlags.NOT_NULL);
	assert(field.scale == 0);
	assert(field.defaultValues == "");

	field = fields[2];
	assert(field.schema == "information_schema");
	assert(field.table == "character_sets");
	// Skip originalTable. Seems like it changes between runs as it references
	// a temporary file
	assert(field.name == "DESCRIPTION");
	assert(field.originalName == field.name);
	// Skip charset. Think it might be defined by the default character set for
	// the database.
	assert(field.length == 180);
	assert(field.type == SQLType.VARSTRING);
	assert(field.flags == FieldFlags.NOT_NULL);
	assert(field.scale == 0);
	assert(field.defaultValues == "");

	field = fields[3];
	assert(field.schema == "information_schema");
	assert(field.table == "character_sets");
	// Skip originalTable. Seems like it changes between runs as it references
	// a temporary file
	assert(field.name == "MAXLEN");
	assert(field.originalName == field.name);
	// Skip charset. Think it might be defined by the default character set for
	// the database.
	assert(field.length == 3);
	assert(field.type == SQLType.LONGLONG);
	assert(field.flags == FieldFlags.NOT_NULL);
	assert(field.scale == 0);
	assert(field.defaultValues == "0");
}
+/
/+
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto pi = cn.processInfo();
	// TODO: Test result
}
+/

// Simple text queries
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto ds = cn.query_("SELECT 1");
	assert(ds.length == 1);
	//auto rs = ds[0];
	//assert(rs.rows.length == 1);
	//auto row = rs.rows[0];
	auto rs = ds;
	assert(rs.length == 1);
	auto row = rs[0];
	//assert(row.length == 1);
	assert(row._values.length == 1);
	assert(row[0].get!long == 1);
}

/+
// Multi results
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto ds = cn.query_("SELECT 1; SELECT 2;");
	assert(ds.length == 2);
	auto rs = ds[0];
	assert(rs.rows.length == 1);
	auto row = rs.rows[0];
	assert(row.length == 1);
	assert(row[0].get!long == 1);
	rs = ds[1];
	assert(rs.rows.length == 1);
	row = rs.rows[0];
	assert(row.length == 1);
	assert(row[0].get!long == 2);
}
+/

// Create and query table
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);

	void assertBasicTests(T, U)(string sqlType, U[] values ...)
	{
		import std.array;
		immutable tablename = "`basic_"~sqlType.replace(" ", "")~"`";
		cn.exec("CREATE TABLE IF NOT EXISTS "~tablename~" (value "~sqlType~ ")");

		// Missing and NULL
		cn.exec("TRUNCATE "~tablename);
		immutable selectOneSql = "SELECT value FROM "~tablename~" LIMIT 1";
		//assert(cn.query_(selectOneSql)[0].length == 0);
		assert(cn.query_(selectOneSql).length == 0);

		immutable insertNullSql = "INSERT INTO "~tablename~" VALUES (NULL)";
		auto okp = cn.exec(insertNullSql);
		//assert(okp.affectedRows == 1);
		assert(okp == 1);
		okp = cn.prepareCmd(insertNullSql).execCmd();
		//assert(okp.affectedRows == 1);
		assert(okp == 1);

		//assert(!cn.queryScalar(selectOneSql).hasValue);
		assert(cn.querySingle(selectOneSql).isNull(0));

		// NULL as bound param
		auto inscmd = cn.prepareCmd("INSERT INTO "~tablename~" VALUES (?)");
		cn.exec("TRUNCATE "~tablename);

		inscmd.bindParameters([Variant(null)]);
		okp = inscmd.execCmd();
		//assert(okp.affectedRows == 1, "value not inserted");
		assert(okp == 1, "value not inserted");

		//assert(!cn.queryScalar(selectOneSql).hasValue);
		assert(cn.querySingle(selectOneSql).isNull(0));

		// Values
		foreach(value; values)
		{
			cn.exec("TRUNCATE "~tablename);

			inscmd.bind(0, value);
			okp = inscmd.execCmd();
			//assert(okp.affectedRows == 1, "value not inserted");
			assert(okp == 1, "value not inserted");

			cn.assertScalar!T(selectOneSql, value);
		}
	}

	// TODO: Add tests for epsilon
	assertBasicTests!float("FLOAT", 0.0f, 0.1f, -0.1f, 1.0f, -1.0f);
	assertBasicTests!double("DOUBLE", 0.0, 0.1, -0.1, 1.0, -1.0);

	//assertBasicTests!bool("BOOL", true, false);
	//assertBasicTests!bool("TINYINT(1)", true, false);
	assertBasicTests!byte("BOOL", cast(byte)0, cast(byte)1);
	assertBasicTests!byte("TINYINT(1)", cast(byte)0, cast(byte)1);

	assertBasicTests!byte("TINYINT",
			cast(byte)0, cast(byte)1, cast(byte)-1, byte.min, byte.max);
	assertBasicTests!ubyte("TINYINT UNSIGNED",
			cast(ubyte)0, cast(ubyte)1, ubyte.max);
	assertBasicTests!short("SMALLINT",
			cast(short)0, cast(short)1, cast(short)-1, short.min, short.max);
	assertBasicTests!ushort("SMALLINT UNSIGNED",
			cast(ushort)0, cast(ushort)1, ushort.max);
	assertBasicTests!int("INT", 0, 1, -1, int.min, int.max);
	assertBasicTests!uint("INT UNSIGNED", 0U, 1U, uint.max);
	assertBasicTests!long("BIGINT", 0L, 1L, -1L, long.min, long.max);
	assertBasicTests!ulong("BIGINT UNSIGNED", 0LU, 1LU, ulong.max);

	assertBasicTests!string("VARCHAR(10)", "", "aoeu");
	assertBasicTests!string("CHAR(10)", "", "aoeu");

	assertBasicTests!string("TINYTEXT", "", "aoeu");
	assertBasicTests!string("MEDIUMTEXT", "", "aoeu");
	assertBasicTests!string("TEXT", "", "aoeu");
	assertBasicTests!string("LONGTEXT", "", "aoeu");

	assertBasicTests!(ubyte[])("TINYBLOB", "", "aoeu");
	assertBasicTests!(ubyte[])("MEDIUMBLOB", "", "aoeu");
	assertBasicTests!(ubyte[])("BLOB", "", "aoeu");
	assertBasicTests!(ubyte[])("LONGBLOB", "", "aoeu");

	assertBasicTests!Date("DATE", Date(2013, 10, 03));
	assertBasicTests!DateTime("DATETIME", DateTime(2013, 10, 03, 12, 55, 35));
	//assertBasicTests!TimeOfDay("TIME", TimeOfDay(12, 55, 35));
	//assertBasicTests!DateTime("TIMESTAMP NULL", Timestamp(2013_10_03_12_55_35));
}

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto cmd = cn.prepareCmd(
			"SELECT * FROM information_schema.character_sets"~
			" WHERE CHARACTER_SET_NAME=?");
	auto val = "utf8";
	cmd.bind(0, val);
	auto row = cmd.querySingle();
	//assert(row.length == 4);
	assert(row._values.length == 4);
	assert(row[0] == "utf8");
	assert(row[1] == "utf8_general_ci");
	assert(row[2] == "UTF-8 Unicode");
	assert(row[3] == 3);
}

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	import mysql.prepared;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `coupleTypes`");
	cn.exec("CREATE TABLE `coupleTypes` (
		`i` INTEGER,
		`s` VARCHAR(50)
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");
	cn.exec("INSERT INTO `coupleTypes` VALUES (11, 'aaa'), (22, 'bbb'), (33, 'ccc')");

	immutable selectSQL          = "SELECT * FROM `coupleTypes` ORDER BY i ASC";
	immutable selectBackwardsSQL = "SELECT `s`,`i` FROM `coupleTypes` ORDER BY i DESC";
	immutable selectNoRowsSQL    = "SELECT * FROM `coupleTypes` WHERE s='no such match'";
	auto prepared = cn.prepare(selectSQL);
	auto preparedSelectNoRows = cn.prepare(selectNoRowsSQL);
	
	// Test querySet
	ResultSet rs = cn.querySet(selectSQL);
	assert(rs.length == 3);
	assert(rs[0].length == 2);
	assert(rs[0][0] == 11);
	assert(rs[0][1] == "aaa");
	assert(rs[1].length == 2);
	assert(rs[1][0] == 22);
	assert(rs[1][1] == "bbb");
	assert(rs[2].length == 2);
	assert(rs[2][0] == 33);
	assert(rs[2][1] == "ccc");
	assert(rs[2][$-1] == "ccc");

	// Test prepared querySet
	rs = prepared.querySet();
	assert(rs.length == 3);
	assert(rs[0].length == 2);
	assert(rs[0][0] == 11);
	assert(rs[0][1] == "aaa");
	assert(rs[1].length == 2);
	assert(rs[1][0] == 22);
	assert(rs[1][1] == "bbb");
	assert(rs[2].length == 2);
	assert(rs[2][0] == 33);
	assert(rs[2][1] == "ccc");
	
	{
		// Test query
		ResultRange rseq = cn.query(selectSQL);
		assert(!rseq.empty);
		assert(rseq.front.length == 2);
		assert(rseq.front[0] == 11);
		assert(rseq.front[1] == "aaa");
		rseq.popFront();
		assert(!rseq.empty);
		assert(rseq.front.length == 2);
		assert(rseq.front[0] == 22);
		assert(rseq.front[1] == "bbb");
		rseq.popFront();
		assert(!rseq.empty);
		assert(rseq.front.length == 2);
		assert(rseq.front[0] == 33);
		assert(rseq.front[1] == "ccc");
		rseq.popFront();
		assert(rseq.empty);
	}

	{
		// Test prepared query
		ResultRange rseq = prepared.query();
		assert(!rseq.empty);
		assert(rseq.front.length == 2);
		assert(rseq.front[0] == 11);
		assert(rseq.front[1] == "aaa");
		rseq.popFront();
		assert(!rseq.empty);
		assert(rseq.front.length == 2);
		assert(rseq.front[0] == 22);
		assert(rseq.front[1] == "bbb");
		rseq.popFront();
		assert(!rseq.empty);
		assert(rseq.front.length == 2);
		assert(rseq.front[0] == 33);
		assert(rseq.front[1] == "ccc");
		rseq.popFront();
		assert(rseq.empty);
	}

	{
		// Test reusing the same ResultRange
		ResultRange rseq = cn.query(selectSQL);
		assert(!rseq.empty);
		rseq.each();
		assert(rseq.empty);
		rseq = cn.query(selectSQL);
		//assert(!rseq.empty); //TODO: Why does this fail???
		rseq.each();
		assert(rseq.empty);
	}

	{
		Nullable!Row nullableRow;

		// Test queryRow
		nullableRow = cn.queryRow(selectSQL);
		assert(!nullableRow.isNull);
		assert(nullableRow[0] == 11);
		assert(nullableRow[1] == "aaa");
		// Were all results correctly purged? Can I still issue another command?
		cn.querySet(selectSQL);

		nullableRow = cn.queryRow(selectNoRowsSQL);
		assert(nullableRow.isNull);

		// Test prepared queryRow
		nullableRow = prepared.queryRow();
		assert(!nullableRow.isNull);
		assert(nullableRow[0] == 11);
		assert(nullableRow[1] == "aaa");
		// Were all results correctly purged? Can I still issue another command?
		cn.querySet(selectSQL);

		nullableRow = preparedSelectNoRows.queryRow();
		assert(nullableRow.isNull);
	}

	{
		int resultI;
		string resultS;

		// Test queryRowTuple
		cn.queryRowTuple(selectSQL, resultI, resultS);
		assert(resultI == 11);
		assert(resultS == "aaa");
		// Were all results correctly purged? Can I still issue another command?
		cn.querySet(selectSQL);

		// Test prepared queryRowTuple
		prepared.queryRowTuple(resultI, resultS);
		assert(resultI == 11);
		assert(resultS == "aaa");
		// Were all results correctly purged? Can I still issue another command?
		cn.querySet(selectSQL);
	}

	{
		Nullable!Variant result;

		// Test queryValue
		result = cn.queryValue(selectSQL);
		assert(result.peek!(int) !is null);
		assert(*result.peek!(int) == 11);
		// Were all results correctly purged? Can I still issue another command?
		cn.querySet(selectSQL);

		result = cn.queryValue(selectNoRowsSQL);
		assert(result.isNull);

		// Test prepared queryValue
		result = prepared.queryValue();
		assert(result.peek!(int) !is null);
		assert(*result.peek!(int) == 11);
		// Were all results correctly purged? Can I still issue another command?
		cn.querySet(selectSQL);

		result = preparedSelectNoRows.queryValue();
		assert(result.isNull);
	}

	{
		// Issue new command before old command was purged
		ResultRange rseq1 = cn.query(selectSQL);
		rseq1.popFront();
		assert(!rseq1.empty);
		assert(rseq1.front[0] == 22);

		assertThrown!MYXDataPending(cn.query(selectBackwardsSQL));
	}

	{
		// Test using outdated ResultRange
		ResultRange rseq1 = cn.query(selectSQL);
		rseq1.popFront();
		assert(!rseq1.empty);
		assert(rseq1.front[0] == 22);

		cn.purgeResult();

		assert(rseq1.empty);
		assertThrown!MYXInvalidatedRange(rseq1.front);
		assertThrown!MYXInvalidatedRange(rseq1.popFront());
		assertThrown!MYXInvalidatedRange(rseq1.asAA());

		ResultRange rseq2 = cn.query(selectBackwardsSQL);
		assert(!rseq2.empty);
		assert(rseq2.front.length == 2);
		assert(rseq2.front[0] == "ccc");
		assert(rseq2.front[1] == 33);

		assert(rseq1.empty);
		assertThrown!MYXInvalidatedRange(rseq1.front);
		assertThrown!MYXInvalidatedRange(rseq1.popFront());
		assertThrown!MYXInvalidatedRange(rseq1.asAA());
	}
}
