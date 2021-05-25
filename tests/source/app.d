/++

This content used to be in the main project source 'source/app.d' but has been moved here and adapted to suit being 
used either locally (with MySQL running via the included docker compose file) or during CI. See Github Actions.

Usage:
    Run the docker-compose file in the tests module and then simply run dub. Alternatively you can build an 
    executable and run it manually. It accepts args if you want to override the defaults:

    ./integration-test --host=localhost --port=3306 --db=testdb --user=testuser --pass=passw0rd

    You can also run "dub --config=use-vibe" to run this file with vibe-core which allows a pooled connection.
+/
import std.array : array;
import std.conv;
import std.getopt;
import std.stdio;
import std.variant;

import mysql;

struct ConnectionParams
{
    string host = "localhost";
	ushort port = 3306;
    string db = "testdb";
	string user = "testuser";
	string pass = "passw0rd";
}

int main(string[] args)
{
    immutable string helpMessage = "
        please supply args for:
            --host=localhost
            --port=3306
            --db=testdb
            --user=testuser
            --pass=passw0rd
    ";

    ConnectionParams param;

    try
	{
		getopt(args, "host",&param.host, "port",&param.port, "db",&param.db, "user",&param.user, "pass",&param.pass);
	}
	catch (GetOptException)
	{
		stderr.writefln(helpMessage);
		return 1;
	}

    // string connStr = "host=localhost;port=3306;user=testuser;pwd=testpassword;db=testdb";
	// if(args.length > 1)
	// 	connStr = args[1];
	// else
	// 	writeln("No connection string provided on cmdline, using default:\n", connStr);
	
	try {
        immutable string connStr = "host="~param.host~";port="~to!string(param.port)~";user="~param.user~";pwd="~param.pass~";db="~param.db~"";

        version(USE_CONNECTION_POOL)
        {
            writeln("Using vibe-d based connection pool: " ~ connStr);
            import mysql.pool;
            auto mdb = new MySQLPool(connStr);
            auto c = mdb.lockConnection();
            scope(exit) c.close();
        }
        else
        {
            writeln("Using single db connection (no vibe): " ~ connStr);
            auto c = new Connection(connStr);
            scope(exit) c.close();
        }

        listServerCapabilities(c);

        listAllTablesInAllDatabases(c);

        createSomeTables(c);

        insertSomeData(c);

        queryTheData(c);
    } catch( Exception e ) {
		writeln("Failed: ", e.toString());
        return 1;
	}

    return 0;
}

void listServerCapabilities(Connection c)
{
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

}

void listAllTablesInAllDatabases(Connection conn) {
    MetaData md = MetaData(conn);
	string[] dbList = md.databases();
	
    writefln("Found %s databases:", dbList.length);

	foreach( db; dbList )
	{
		conn.selectDB(db);
		auto curTables = md.tables();
		writefln("Database '%s' has %s table%s.", db, curTables.length, curTables.length == 1?"":"s");
		foreach(tbls ; curTables)
		{
			writefln("\t%s", tbls);
		}
	}
    writeln();
}

void createSomeTables(Connection conn) {
    writeln("Creating tables:");

    conn.exec("DROP TABLE IF EXISTS `people`");

    conn.exec("CREATE TABLE IF NOT EXISTS `people` (
				`id` INTEGER NOT NULL PRIMARY KEY AUTO_INCREMENT, 
				`username` VARCHAR(20) UNIQUE,
                `email` VARCHAR(80) UNIQUE,
                `firstname` VARCHAR(20),
                `surname` VARCHAR(20),
                `dob` DATE,
				`created` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
				`updated` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
				)");

    writeln("\tCreated table: 'people'");

    conn.exec("DROP TABLE IF EXISTS `things`");

	conn.exec("CREATE TABLE IF NOT EXISTS `things` (
				`id` INTEGER NOT NULL PRIMARY KEY AUTO_INCREMENT, 
				`name` VARCHAR(250),
                `description` MEDIUMTEXT,
                `value` INTEGER NOT NULL
				)");

    writeln("\tCreated table: 'things'\n");
}

void insertSomeData(Connection conn) {
    writeln("Inserting test data:");

    conn.exec("INSERT INTO people (`username`, `email`)
				VALUES
                ('blinky', 'red.ghost@hostname'),
                ('pinky', 'pink.ghost@hostname'),
                ('inky', 'blue.ghost@hostname'),
                ('clyde', 'orange.ghost@hostname')");
}

// regular Query to a ResultRange. Not recommended, use prepared statements
void queryTheData(Connection conn) {
    writeln("Performing SQL queries on test data");

	ResultRange range = conn.query("SELECT * FROM `people`");
	Row row = range.front;

	Variant id = row[0];
	assert(id == 1);
	
    Variant username = row[1];
    assert(username == "blinky");

    Variant email = row[2];
    assert(email == "red.ghost@hostname");

    range.popFront();
	assert(range.front[0] == 2);
	assert(range.front[1] == "pinky");
    assert(range.front[2] == "pink.ghost@hostname");
    assert(range.front[3].type == typeid(typeof(null)) ); // firstname
    assert(range.front[4].type == typeid(typeof(null)) ); // surname
    assert(range.front[5].type == typeid(typeof(null)) ); // dob
    assert(range.front[6].type != typeid(typeof(null)) ); // created
    assert(range.front[7].type != typeid(typeof(null)) ); // updated
}

// Simplified prepared statements
void simplePreparedStatements(Connection conn) {
	ResultRange results = conn.query("SELECT * FROM `people` WHERE `username`=? OR `username`=?", "inky", "clyde");

    Row row = results.front;

	Variant id = row[0];
	assert(id == 3);
	
    assert(row[1] == "inky");
    assert(row[2] == "blue.ghost@hostname");
    assert( row[3].type == typeid(typeof(null)) );
    assert( row[4].type == typeid(typeof(null)) );
    assert( row[5].type == typeid(typeof(null)) );
    assert( row[6].type != typeid(typeof(null)) );
    assert( row[7].type != typeid(typeof(null)) );

	results.close();
}

void fullPreparedStatements(Connection conn) {
    // Full-featured prepared statements
	Prepared prepared = conn.prepare("SELECT * FROM `people` WHERE `username`=? OR `username`=?");
	prepared.setArgs("inky", "clyde");

	ResultRange results = conn.query(prepared);
	
    Row row = results.front;

	Variant id = row[0];
	assert(id == 3);
	
    assert(row[1] == "inky");
    assert(row[2] == "blue.ghost@hostname");
    assert( row[3].type == typeid(typeof(null)) );
    assert( row[4].type == typeid(typeof(null)) );
    assert( row[5].type == typeid(typeof(null)) );
    assert( row[6].type != typeid(typeof(null)) );
    assert( row[7].type != typeid(typeof(null)) );

	results.close();
}

void dropTables(Connection conn) {
    writeln("Dropping tables:");

    conn.exec("DROP TABLE IF EXISTS `people`");
    conn.exec("DROP TABLE IF EXISTS `things`");
}