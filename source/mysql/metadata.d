/// Retrieve metadata from a DB.
module mysql.metadata;

import std.array;
import std.conv;
import std.datetime;
import std.exception;

import mysql.commands;
import mysql.exceptions;
import mysql.protocol.sockets;
import mysql.result;

/// A struct to hold column metadata
struct ColumnInfo
{
	/// The database that the table having this column belongs to.
	string schema;
	/// The table that this column belongs to.
	string table;
	/// The name of the column.
	string name;
	/// Zero based index of the column within a table row.
	size_t index;
	/// Is the default value NULL?
	bool defaultNull;
	/// The default value as a string if not NULL
	string defaultValue;
	/// Can the column value be set to NULL
	bool nullable;
	/// What type is the column - tinyint, char, varchar, blob, date etc
	string type;
	/// Capacity in characters, -1L if not applicable
	long charsMax;
	/// Capacity in bytes - same as chars if not a unicode table definition, -1L if not applicable.
	long octetsMax;
	/// Presentation information for numerics, -1L if not applicable.
	short numericPrecision;
	/// Scale information for numerics or NULL, -1L if not applicable.
	short numericScale;
	/// Character set, "<NULL>" if not applicable.
	string charSet;
	/// Collation, "<NULL>" if not applicable.
	string collation;
	/// More detail about the column type, e.g. "int(10) unsigned".
	string colType;
	/// Information about the column's key status, blank if none.
	string key;
	/// Extra information.
	string extra;
	/// Privileges for logged in user.
	string privileges;
	/// Any comment that was set at table definition time.
	string comment;
}

/// A struct to hold stored function metadata.
struct MySQLProcedure
{
	string db;
	string name;
	string type;
	string definer;
	DateTime modified;
	DateTime created;
	string securityType;
	string comment;
	string charSetClient;
	string collationConnection;
	string collationDB;
}

/++
Facilities to recover meta-data from a connection.

It is important to bear in mind that the methods provided will only return the
information that is available to the connected user. This may well be quite limited.
+/
struct MetaData
{
	import mysql.connection;
	
private:
	Connection _con;

	MySQLProcedure[] stored(bool procs)
	{
		enforce!MYX(_con.currentDB.length, "There is no selected database");
		string query = procs ? "SHOW PROCEDURE STATUS WHERE db='": "SHOW FUNCTION STATUS WHERE db='";
		query ~= _con.currentDB ~ "'";

		auto rs = _con.query(query).array;
		MySQLProcedure[] pa;
		pa.length = rs.length;
		foreach (size_t i; 0..rs.length)
		{
			MySQLProcedure foo;
			Row r = rs[i];
			foreach (int j; 0..11)
			{
				if (r.isNull(j))
					continue;
				auto value = r[j].toString();
				switch (j)
				{
					case 0:
						foo.db = value;
						break;
					case 1:
						foo.name = value;
						break;
					case 2:
						foo.type = value;
						break;
					case 3:
						foo.definer = value;
						break;
					case 4:
						foo.modified = r[j].get!(DateTime);
						break;
					case 5:
						foo.created = r[j].get!(DateTime);
						break;
					case 6:
						foo.securityType = value;
						break;
					case 7:
						foo.comment = value;
						break;
					case 8:
						foo.charSetClient = value;
						break;
					case 9:
						foo.collationConnection = value;
						break;
					case 10:
						foo.collationDB = value;
						break;
					default:
						assert(0);
				}
			}
			pa[i] = foo;
		}
		return pa;
	}

public:
	this(Connection con)
	{
		_con = con;
	}

	/++
	List the available databases
	
	Note that if you have connected using the credentials of a user with
	limited permissions you may not get many results.
	
	Returns:
		An array of strings
	+/
	string[] databases()
	{
		auto rs = _con.query("SHOW DATABASES").array;
		string[] dbNames;
		dbNames.length = rs.length;
		foreach (size_t i; 0..rs.length)
			dbNames[i] = rs[i][0].toString();
		return dbNames;
	}

	/++
	List the tables in the current database
	
	Returns:
		An array of strings
	+/
	string[] tables()
	{
		auto rs = _con.query("SHOW TABLES").array;
		string[] tblNames;
		tblNames.length = rs.length;
		foreach (size_t i; 0..rs.length)
			tblNames[i] = rs[i][0].toString();
		return tblNames;
	}

	/++
	Get column metadata for a table in the current database
	
	Params:
		table = The table name
	Returns:
		An array of `ColumnInfo` structs
	+/
	ColumnInfo[] columns(string table)
	{
		// Manually specify all fields to avoid problems when newer versions of
		// the server add or rearrange fields. (Issue #45)
		string query =
			"SELECT " ~
			" TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME," ~
			" COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT," ~
			" IS_NULLABLE, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH," ~
			" CHARACTER_OCTET_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE," ~
			" CHARACTER_SET_NAME, COLLATION_NAME, COLUMN_TYPE," ~
			" COLUMN_KEY, EXTRA, PRIVILEGES, COLUMN_COMMENT" ~
			" FROM information_schema.COLUMNS WHERE" ~
			" table_schema='" ~ _con.currentDB ~ "' AND table_name='" ~ table ~ "'";
		auto rs = _con.query(query).array;
		ColumnInfo[] ca;
		ca.length = rs.length;
		foreach (size_t i; 0..rs.length)
		{
			ColumnInfo col;
			Row r = rs[i];
			for (int j = 1; j < 19; j++)
			{
				string t;
				bool isNull = r.isNull(j);
				if (!isNull)
					t = to!string(r[j]);
				switch (j)
				{
					case 1:
						col.schema = t;
						break;
					case 2:
						col.table = t;
						break;
					case 3:
						col.name = t;
						break;
					case 4:
						if(isNull)
							col.index = -1;
						else
							col.index = cast(size_t)(r[j].coerce!ulong() - 1);
						//col.index = cast(size_t)(r[j].get!(ulong)-1);
						break;
					case 5:
						if (isNull)
							col.defaultNull = true;
						else
							col.defaultValue = t;
						break;
					case 6:
						if (t == "YES")
						col.nullable = true;
						break;
					case 7:
						col.type = t;
						break;
					case 8:
						col.charsMax = cast(long)(isNull? -1L: r[j].coerce!(ulong));
						break;
					case 9:
						col.octetsMax = cast(long)(isNull? -1L: r[j].coerce!(ulong));
						break;
					case 10:
						col.numericPrecision = cast(short) (isNull? -1: r[j].coerce!(ulong));
						break;
					case 11:
						col.numericScale = cast(short) (isNull? -1: r[j].coerce!(ulong));
						break;
					case 12:
						col.charSet = isNull? "<NULL>": t;
						break;
					case 13:
						col.collation = isNull? "<NULL>": t;
						break;
					case 14:
						col.colType = r[j].get!string();
						break;
					case 15:
						col.key = t;
						break;
					case 16:
						col.extra = t;
						break;
					case 17:
						col.privileges = t;
						break;
					case 18:
						col.comment = t;
						break;
					default:
						break;
				}
			}
			ca[i] = col;
		}
		return ca;
	}

	/// Get list of stored functions in the current database, and their properties.
	MySQLProcedure[] functions()
	{
		return stored(false);
	}

	/// Get list of stored procedures in the current database, and their properties.
	MySQLProcedure[] procedures()
	{
		return stored(true);
	}
}
