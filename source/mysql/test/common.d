/++
Package mysql.test contains integration and regression tests, not unittests.
Unittests (including regression unittests) are located together with the
units they test.
+/
module mysql.test.common;

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

import mysql.safe.commands;
import mysql.safe.connection;
import mysql.exceptions;
import mysql.protocol.extra_types;
import mysql.protocol.sockets;
import mysql.safe.result;
import mysql.types;

/+
To enable these tests, you have to add the MYSQLN_TESTS
debug specifier. The reason it uses debug and not version is because dub
doesn't allow adding version specifiers on the command-line.
+/
debug(MYSQLN_TESTS)      version = DoCoreTests;
debug(MYSQLN_CORE_TESTS) version = DoCoreTests;

version(DoCoreTests)
{
	public import std.stdio;
	import std.conv;
	import std.datetime;

	@safe:
	private @property string testConnectionStrFile()
	{
		import std.file, std.path;

		static string cached;
		if(!cached)
			cached = buildPath(thisExePath.dirName.dirName, "testConnectionStr.txt");

		return cached;
	}

	@property string testConnectionStr()
	{
		import std.file, std.string;

		static string cached;
		if(!cached)
		{
			if(!testConnectionStrFile.exists())
			{
				// Create a default file
				std.file.write(
					testConnectionStrFile,
					"host=localhost;port=3306;user=mysqln_test;pwd=pass123;db=mysqln_testdb"
				);

				import std.stdio;
				writeln(
					"Connection string file for tests wasn't found, so a default "~
					"has been created. Please open it, verify its settings, and "~
					"run the mysql-native tests again:"
				);
				writeln(testConnectionStrFile);
				assert(false, "Halting so the user can check connection string settings.");
			}

			cached = std.file.readText(testConnectionStrFile);
			cached = cached.strip();
		}

		return cached;
	}

	Connection createCn(string cnStr = testConnectionStr)
	{
		return new Connection(cnStr);
	}

	enum scopedCn = "auto cn = createCn(); scope(exit) cn.close();";

	void assertScalar(T, U)(Connection cn, string query, U expected)
	{
		auto result = cn.queryValue(query);
		assert(!result.isNull);

		// Timestamp is a bit special as it's converted to a DateTime when
		// returning from MySQL to avoid having to use a mysql specific type.
		static if(is(T == DateTime) && is(U == Timestamp))
			assert(result.get.get!DateTime == expected.toDateTime());
		else
			assert(result.get.get!T == expected);
	}

	void truncate(Connection cn, string table)
	{
		cn.exec("TRUNCATE `"~table~"`;");
	}

	void initDB(Connection cn, string db)
	{
		scope(exit) cn.resetPacket();
		//cn.sendCommand(CommandType.INIT_DB, db);
		cn.selectDB(db);
		auto packet = cn.pktNumber();
		//packet.enforceOK();
	}

	/// Convert a Timestamp to DateTime
	DateTime toDateTime(Timestamp value) pure
	{
		auto x = value.rep;
		int second = cast(int) (x%100);
		x /= 100;
		int minute = cast(int) (x%100);
		x /= 100;
		int hour   = cast(int) (x%100);
		x /= 100;
		int day    = cast(int) (x%100);
		x /= 100;
		int month  = cast(int) (x%100);
		x /= 100;
		int year   = cast(int) (x%10000);

		return DateTime(year, month, day, hour, minute, second);
	}

	// generate safe or unsafe imports for unittests.
	string doImports(bool isSafe, string[] imports...)
	{
		string result;
		string subpackage = isSafe ? "safe" : "unsafe";
		foreach(im; imports)
		{
			result ~= "import mysql." ~ subpackage ~ "." ~ im ~ ";";
		}
		return result;
	}
}
