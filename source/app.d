import vibe.vibe;
import mysql.db;
import std.stdio;


void main()
{
	try testMySql();
	catch( Exception e ){
		logError("Failed: %s", e.toString());
	}
}

void testMySql()
{
	auto mdb = new MysqlDB("localhost", "user", "password", "database");

	auto c = mdb.lockConnection();

//   writefln("You have connected to server version %s", c.serverVersion);
//   writefln("With currents stats : %s", c.serverStats());
	auto caps = c.serverCapabilities;
	writefln("MySQL Server %s with capabilities (%b):", c.serverVersion, caps);
	if(caps && SvrCapFlags.OLD_LONG_PASSWORD)
		writeln("\tLong passwords");
	if(caps && SvrCapFlags.FOUND_NOT_AFFECTED)
		writeln("\tReport rows found rather than rows affected");
	if(caps && SvrCapFlags.ALL_COLUMN_FLAGS)
		writeln("\tSend all column flags");
	if(caps && SvrCapFlags.WITH_DB)
		writeln("\tCan take database as part of login");
	if(caps && SvrCapFlags.NO_SCHEMA)
		writeln("\tCan disallow database name as part of column name database.table.column");
	if(caps && SvrCapFlags.CAN_COMPRESS)
		writeln("\tCan compress packets");
	if(caps && SvrCapFlags.ODBC)
		writeln("\tCan handle ODBC");
	if(caps && SvrCapFlags.LOCAL_FILES)
		writeln("\tCan use LOAD DATA LOCAL");
	if(caps && SvrCapFlags.IGNORE_SPACE)
		writeln("\tCan ignore spaces before '('");
	if(caps && SvrCapFlags.PROTOCOL41)
		writeln("\tCan use 4.1+ protocol");
	if(caps && SvrCapFlags.INTERACTIVE)
		writeln("\tInteractive client?");
	if(caps && SvrCapFlags.SSL)
		writeln("\tCan switch to SSL after handshake");
	if(caps && SvrCapFlags.IGNORE_SIGPIPE)
		writeln("\tIgnore sigpipes?");
	if(caps && SvrCapFlags.TRANSACTIONS)
		writeln("\tTransaction Support");
	if(caps && SvrCapFlags.SECURE_CONNECTION)
		writeln("\t4.1+ authentication");
	if(caps && SvrCapFlags.MULTI_STATEMENTS)
		writeln("\tMultiple statement support");
	if(caps && SvrCapFlags.MULTI_RESULTS)
		writeln("\tMultiple result set support");
	writeln();
	
	MetaData md = MetaData(c);
	auto dbList = md.databases();
	writefln("Found %s databases", dbList.length);
	foreach( db; dbList )
	{
		c.selectDB(db);
		auto curTables = md.tables();
		writefln("Database '%s' has %s table%s.", db, curTables.length, curTables.length == 1?"":"s");
		foreach(tbls ; curTables)
		{
			writefln("\t%s", tbls);
		}
	}
}
