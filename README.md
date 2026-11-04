MySQL native
============

[![DUB Package](https://img.shields.io/dub/v/mysql-native.svg)](https://code.dlang.org/packages/mysql-native)
[![GitHub - Builds](https://github.com/mysql-d/mysql-native/actions/workflows/dub.yml/badge.svg)](https://github.com/mysql-d/mysql-native/actions/workflows/dub.yml)
[![GitHub - Integration Tests](https://github.com/mysql-d/mysql-native/actions/workflows/integration-testing.yml/badge.svg)](https://github.com/mysql-d/mysql-native/actions/workflows/integration-testing.yml)

*NOTE: we are in the process of migrating to github actions. Documentation is now
being generated using github actions, and stored on github. This README
is in flux at the moment, and may contain outdated information*

A [Boost-licensed](http://www.boost.org/LICENSE_1_0.txt) native [D](http://dlang.org)
client driver for MySQL and MariaDB.

This package attempts to provide composite objects and methods that will
allow a wide range of common database operations, but be relatively easy to
use. It has no dependencies on GPL header files or libraries, instead communicating
directly with the server via the
[published client/server protocol](http://dev.mysql.com/doc/internals/en/client-server-protocol.html).

This package supports both [Phobos sockets](https://dlang.org/phobos/std_socket.html)
and [Vibe.d](http://vibed.org/) sockets. It will automatically use the correct
type based on whether Vibe.d is used in your project. (If you use
[DUB](http://code.dlang.org/getting_started), this is completely seamless.
Otherwise, you can use `-version=Have_vibe_d_core` to force Vibe.d sockets
instead of Phobos ones.)

Should work on D compilers from 2.068 through to the latest release but the CI only tests against version 2.085.1 and above. For a full list see the builds on Github Actions. Note that dub from prior to 2.085.0 will not work, but this is not an issue with mysql-native. To build with prior compilers, use a newer version of dub.

In this document:
* [API](#api)
* [Basic example](#basic-example)
* [Additional notes](#additional-notes)
* [Developers - How to run the test suite](#developers---how-to-run-the-test-suite)

See also:
* [API Reference](https://mysql-d.github.io/mysql-native/)

API
---

*NOTE: the most recent release of mysql-native has been updated to be usable from `@safe` code, using the `mysql.safe` package. Please see the [safe migration document](SAFE_MIGRATION.md) for more details*

[API Reference](https://mysql-d.github.io/mysql-native/)

The primary interfaces (all these are the safe versions):
- [Connection](https://mysql-d.github.io/mysql-native/mysql/impl/connection/Connection.html): Connection to the server, and querying and setting of server parameters.
- [MySQLPool](https://mysql-d.github.io/mysql-native/mysql/impl/pool/MySQLPoolImpl.html): Connection pool, for Vibe.d users.
- [exec()](https://mysql-d.github.io/mysql-native/mysql/safe/commands/exec.html): Plain old SQL statement that does NOT return rows (like INSERT/UPDATE/CREATE/etc), returns number of rows affected
- [query()](https://mysql-d.github.io/mysql-native/mysql/safe/commands/query.html): Execute an SQL statement that DOES return rows (ie, SELECT) and handle the rows one at a time, as an input range.
- [queryRow()](https://mysql-d.github.io/mysql-native/mysql/safe/commands/queryRow.html): Execute an SQL statement and get the first row.
- [queryValue()](https://mysql-d.github.io/mysql-native/mysql/safe/commands/queryValue.html): Execute an SQL statement and get the first value in the first row.
- [prepare()](https://mysql-d.github.io/mysql-native/mysql/safe/connection/prepare.html): Create a prepared statement
- [Prepared](https://mysql-d.github.io/mysql-native/mysql/impl/prepared/SafePrepared.html): A prepared statement, optionally pass it to the exec/query function in place of an SQL string.
- [Row](https://mysql-d.github.io/mysql-native/mysql/impl/result/SafeRow.html): One "row" of results, used much like an array of Variant.
- [ResultRange](https://mysql-d.github.io/mysql-native/mysql/impl/result/SafeResultRange.html): An input range of rows. Convert to random access with [std.array.array()](https://dlang.org/phobos/std_array.html#.array).

Also note the [MySQL <-> D type mappings tables](https://mysql-d.github.io/mysql-native/mysql.html)

Basic example
-------------
```d
import std.array : array;
import mysql.safe; // Please use the safe api, it's the future

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
	MySQLVal id = row[0];
	MySQLVal name = row[1];
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
	assert( range.front[0].kind == MySQLVal.Kind.Null );
}
```

Additional notes
----------------

This requires MySQL server v4.1.1 or later, or a MariaDB server. Older
versions of MySQL server are obsolete, use known-insecure authentication,
and are not supported by this package. Currently the github actions tests use
MySQL 5.7, 8.0, 8.4 and 9, and MariaDB 10 and 11.4.

Accounts may use the `mysql_native_password` or the `caching_sha2_password`
authentication plugin (the default of MySQL 8 and later). Since connections are
not encrypted, `caching_sha2_password` sends the password encrypted with the
server's RSA public key whenever the server doesn't have the account in its
cache (the first login after a server restart, for example). The client asks the
server for that key, so this relies on the network path to the server being
trusted, as unencrypted connections always do.

Normally, MySQL clients connect to a server on the same machine via a Unix
socket on *nix systems, and through a named pipe on Windows. Neither of these
conventions is currently supported. TCP is used for all connections.

Unfortunately, the original home page of Steve Teale's mysqln is no longer
available. You can see an archive on the [Internet Archive wayback
machine](https://web.archive.org/web/20120323165808/http://britseyeview.com/software/mysqln)

Developers - How to run the test suite
--------------------------------------

Unittests that do not require an actual server are located in the library
codebase. You can run just these tests using `dub test`.

Unittests that require a working server are all located in the
[integration-tests](integration-tests) subpackage. Due to a [dub
issue](https://github.com/dlang/dub/issues/2136), the integration tests are run
using the [integration-tests-phobos](integration-tests-phobos) and
[integration-tests-vibe](integration-tests-vibe) subpackages. At some point, if this dub issue
is fixed, they will simply become configurations in the main integration-tests
repository. You can run these directly from the main repository folder by
issuing the commands:

```sh
dub run :integration-tests-phobos
dub run :integration-tests-vibe
```
This will also run the library tests as well as the integration tests.

The first time you run an integration test, the file `testConnectionStr.txt`
will be created in your current directory

Open the `testConnectionStr.txt` file and verify the connection settings
inside, modifying them as needed, and if necessary, creating a test user and
blank test schema in your MySQL database.

The tests will completely clobber anything inside the db schema provided,
but they will ONLY modify that one db schema. No other schema will be
modified in any way.

After you've configured the connection string, run the integration tests again.

The integration tests use
[unit-threaded](https://code.dlang.org/packages/unit-threaded) which allows for
running individual named tests. Use this for running specific tests instead of
the whole suite.
