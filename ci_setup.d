import std.file;
import std.process;
import std.stdio : writefln;

bool envBool(string name)
{
	return environment.get(name, null) == "true";
}

string envGet(string name)
{
	return environment.get(name, null);
}

void copyIfExists(string from, string to)
{
	if(exists(from) && isFile(from))
		copy(from, to);
}

void main()
{
	auto haveRdmd = executeShell("rdmd --help").status == 0;
	if(!haveRdmd)
	{
		auto dmdVersion = "2.088.0";
		auto dmdZip = "dmd."~dmdVersion~"."~environment["TRAVIS_OS_NAME"]~".zip";
		writefln("Downloading %s from downloads.dlang.org", dmdZip);
		spawnShell("wget http://downloads.dlang.org/releases/2.x/"~dmdVersion~"/"~dmdZip).wait;
		spawnShell("unzip -q -d local-dmd "~dmdZip).wait;
	}

	// MySQL is not installed by default on OSX build agents
	if(environment["TRAVIS_OS_NAME"] == "osx")
	{
		spawnShell("brew update").wait;
		spawnShell("brew install mysql && brew services start mysql").wait;
	}

	// If an alternate dub.selections.json was requested, use it.
	if(environment.get("DUB_SELECT") != null) {
		string dubSelections = "dub.selections."~envGet("DUB_SELECT")~".json";
		writefln("Using alternative dub dependencies file: %s", dubSelections);
		copyIfExists(dubSelections, "dub.selections.json");
		copyIfExists("examples/homePage/dub.selections."~envGet("DUB_SELECT")~".json", "examples/homePage/dub.selections.json");
	}

	if(envBool("DUB_UPGRADE"))
	{
		// Update all dependencies
		//
		// As a bonus, this downloads & resolves deps now so intermittent
		// failures are more likely to be correctly marked as "job error"
		// rather than "tests failed".
		spawnShell("dub upgrade").wait;
		chdir("examples/homePage");
		spawnShell("dub upgrade").wait;
		chdir("../..");
	}
	else
	{
		// Don't upgrade dependencies.
		//
		// But download & resolve deps now so intermittent failures are more likely
		// to be correctly marked as "job error" rather than "tests failed".
		spawnShell("dub upgrade --missing-only").wait;
		chdir("examples/homePage");
		spawnShell("dub upgrade --missing-only").wait;
		chdir("../..");
	}

	// Setup DB
	spawnShell(`mysql -u root -e 'SHOW VARIABLES LIKE "%version%";'`).wait;
	spawnShell(`mysql -u root -e 'CREATE DATABASE mysqln_testdb;'`).wait;
	write("testConnectionStr.txt", "host=127.0.0.1;port=3306;user=root;pwd=;db=mysqln_testdb");
}
