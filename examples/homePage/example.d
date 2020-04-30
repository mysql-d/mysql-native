import std.array : array;
import std.variant;
import mysql;

void main(string[] args)
{
	// Connect
	auto connectionStr = "host=localhost;port=3306;user=yourname;pwd=pass123;db=mysqln_testdb";
	if(args.length > 1)
		connectionStr = args[1];
	Connection conn = new Connection(connectionStr);
	scope(exit) conn.close();

	// Insert
	ulong rowsAffected = conn.exec(
		"INSERT INTO `tablename` (`id`, `name`) VALUES (1, 'Ann'), (2, 'Bob')");

	// Query
	ResultRange range = conn.query("SELECT * FROM `tablename`");
	Row row = range.front;
	Variant id = row[0];
	Variant name = row[1];
	assert(id == 1);
	assert(name == "Ann");

	range.popFront();
	assert(range.front[0] == 2);
	assert(range.front[1] == "Bob");

	// Simplified prepared statements
	ResultRange bobs = conn.query(
		"SELECT * FROM `tablename` WHERE `name`=? OR `name`=?",
		"Bob", "Bobby");
	bobs.close(); // Skip them

	Row[] rs = conn.query( // Same SQL as above, but only prepared once and is reused!
		"SELECT * FROM `tablename` WHERE `name`=? OR `name`=?",
		"Bob", "Ann").array; // Get ALL the rows at once
	assert(rs.length == 2);
	assert(rs[0][0] == 1);
	assert(rs[0][1] == "Ann");
	assert(rs[1][0] == 2);
	assert(rs[1][1] == "Bob");

	// Full-featured prepared statements
	Prepared prepared = conn.prepare("SELECT * FROM `tablename` WHERE `name`=? OR `name`=?");
	prepared.setArgs("Bob", "Bobby");
	bobs = conn.query(prepared);
	bobs.close(); // Skip them

	// Nulls
	conn.exec(
		"INSERT INTO `tablename` (`id`, `name`) VALUES (?,?)",
		null, "Cam"); // Can also take Nullable!T
	range = conn.query("SELECT * FROM `tablename` WHERE `name`='Cam'");
	assert( range.front[0].type == typeid(typeof(null)) );
}
