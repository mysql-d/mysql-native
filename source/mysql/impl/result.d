/++
Implementation - Data result structures.

WARNING:
This module is used to consolidate the common implementation of the safe and
unafe API. DO NOT directly import this module, please import one of
`mysql.result`, `mysql.safe.result`, or `mysql.unsafe.result`. This module will
be removed in a future version without deprecation.

$(SAFE_MIGRATION)
+/
module mysql.impl.result;

import std.conv;
import std.exception;
import std.range;
import std.string;

import mysql.exceptions;
import mysql.protocol.comms;
import mysql.protocol.extra_types;
import mysql.protocol.packets;
public import mysql.types;
import std.typecons : Nullable;
import std.variant;

/++
A struct to represent a single row of a result set.

Type_Mappings: $(TYPE_MAPPINGS)
+/
/+
The row struct is used for both 'traditional' and 'prepared' result sets.
It consists of parallel arrays of MySQLVal and bool, with the bool array
indicating which of the result set columns are NULL.

I have been agitating for some kind of null indicator that can be set for a
MySQLVal without destroying its inherent type information. If this were the
case, then the bool array could disappear.
+/
struct SafeRow
{

package(mysql):
	MySQLVal[]   _values; // Temporarily "package" instead of "private"
private:
	import mysql.impl.connection;
	bool[]      _nulls;
	string[]    _names;

public:
	@safe:

	/++
	A constructor to extract the column data from a row data packet.

	If the data for the row exceeds the server's maximum packet size, then several packets will be
	sent for the row that taken together constitute a logical row data packet. The logic of the data
	recovery for a Row attempts to minimize the quantity of data that is bufferred. Users can assist
	in this by specifying chunked data transfer in cases where results sets can include long
	column values.

	Type_Mappings: $(TYPE_MAPPINGS)
	+/
	this(Connection con, ref ubyte[] packet, ResultSetHeaders rh, bool binary)
	{
		ctorRow(con, packet, rh, binary, _values, _nulls, _names);
	}

	/++
	Simplify retrieval of a column value by index.

	To check for null, use MySQLVal's `kind` property:
	`row[index].kind == MySQLVal.Kind.Null`
	or use a direct comparison to null:
	`row[index] == null`

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: i = the zero based index of the column whose value is required.
	Returns: A MySQLVal holding the column value.
	+/
	ref inout(MySQLVal) opIndex(size_t i) inout
	{
		enforce!MYX(_nulls.length > 0, format("Cannot get column index %d. There are no columns", i));
		enforce!MYX(i < _nulls.length, format("Cannot get column index %d. The last available index is %d", i, _nulls.length-1));
		return _values[i];
	}

	/++
	Get the name of the column with specified index.
	+/
	inout(string) getName(size_t index) inout
	{
		return _names[index];
	}

	@("getName")
	debug(MYSQLN_TESTS)
	@system unittest
	{
		static void test(bool isSafe)()
		{
			import mysql.test.common;
			mixin(doImports(isSafe, "commands"));
			mixin(scopedCn);
			cn.exec("DROP TABLE IF EXISTS `row_getName`");
			cn.exec("CREATE TABLE `row_getName` (someValue INTEGER, another INTEGER) ENGINE=InnoDB DEFAULT CHARSET=utf8");
			cn.exec("INSERT INTO `row_getName` VALUES (1, 2), (3, 4)");

			enum sql = "SELECT another, someValue FROM `row_getName`";

			auto rows = cn.query(sql).array;
			assert(rows.length == 2);
			assert(rows[0][0] == 2);
			assert(rows[0][1] == 1);
			assert(rows[0].getName(0) == "another");
			assert(rows[0].getName(1) == "someValue");
			assert(rows[1][0] == 4);
			assert(rows[1][1] == 3);
			assert(rows[1].getName(0) == "another");
			assert(rows[1].getName(1) == "someValue");
		}

		test!false();
		() @safe { test!true(); } ();
	}

	/++
	Check if a column in the result row was NULL

	Params: i = The zero based column index.
	+/
	bool isNull(size_t i) const pure nothrow { return _nulls[i]; }

	/++
	Get the number of elements (columns) in this row.
	+/
	@property size_t length() const pure nothrow { return _values.length; }

	///ditto
	alias opDollar = length;

	/++
	Move the content of the row into a compatible struct

	This method takes no account of NULL column values. If a column was NULL,
	the corresponding MySQLVal value would be unchanged in those cases.

	The method will throw if the type of the MySQLVal is not implicitly
	convertible to the corresponding struct member.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params:
	S = A struct type.
	s = A ref instance of the type
	+/
	void toStruct(S)(ref S s) if (is(S == struct))
	{
		foreach (i, dummy; s.tupleof)
		{
			static if(__traits(hasMember, s.tupleof[i], "nullify") &&
					  is(typeof(s.tupleof[i].nullify())) && is(typeof(s.tupleof[i].get)))
			{
				if(!_nulls[i])
				{
					enforce!MYX(_values[i].convertsTo!(typeof(s.tupleof[i].get))(),
						"At col "~to!string(i)~" the value is not implicitly convertible to the structure type");
					s.tupleof[i] = _values[i].get!(typeof(s.tupleof[i].get));
				}
				else
					s.tupleof[i].nullify();
			}
			else
			{
				if(!_nulls[i])
				{
					enforce!MYX(_values[i].convertsTo!(typeof(s.tupleof[i]))(),
						"At col "~to!string(i)~" the value is not implicitly convertible to the structure type");
					s.tupleof[i] = _values[i].get!(typeof(s.tupleof[i]));
				}
				else
					s.tupleof[i] = typeof(s.tupleof[i]).init;
			}
		}
	}

	void show()
	{
		import std.stdio;

		writefln("%(%s, %)", _values);
	}
}

/+
An UnsafeRow is almost identical to a SafeRow, except that it provides access
to its values via Variant instead of MySQLVal. This makes the access unsafe.
Only value access is unsafe, every other operation is forwarded to the internal
SafeRow.

Use the safe or unsafe UFCS methods to convert to and from these two types if
needed.

Note that there is a performance penalty when accessing via a Variant as the MySQLVal must be converted on every access.

$(SAFE_MIGRATION)
+/
struct UnsafeRow
{
	SafeRow _safe;
	alias _safe this;
	/// Converts SafeRow.opIndex result to Variant.
	Variant opIndex(size_t idx) {
		return _safe[idx].asVariant;
	}
}

/// ditto
UnsafeRow unsafe(SafeRow r) @safe
{
	return UnsafeRow(r);
}

/// ditto
Nullable!UnsafeRow unsafe(Nullable!SafeRow r) @safe
{
	if(r.isNull)
		return Nullable!UnsafeRow();
	return Nullable!UnsafeRow(r.get.unsafe);
}


/// ditto
SafeRow safe(UnsafeRow r) @safe
{
	return r._safe;
}


/// ditto
Nullable!SafeRow safe(Nullable!UnsafeRow r) @safe
{
	if(r.isNull)
		return Nullable!SafeRow();
	return Nullable!SafeRow(r.get.safe);
}

/++
An $(LINK2 http://dlang.org/phobos/std_range_primitives.html#isInputRange, input range)
of SafeRow.

This is returned by the `mysql.safe.commands.query` functions.

The rows are downloaded one-at-a-time, as you iterate the range. This allows
for low memory usage, and quick access to the results as they are downloaded.
This is especially ideal in case your query results in a large number of rows.

However, because of that, this `SafeResultRange` cannot offer random access or
a `length` member. If you need random access, then just like any other range,
you can simply convert this range to an array via
$(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`).

A `SafeResultRange` becomes invalidated (and thus cannot be used) when the server
is sent another command on the same connection. When an invalidated
`SafeResultRange` is used, a `mysql.exceptions.MYXInvalidatedRange` is thrown.
If you need to send the server another command, but still access these results
afterwords, you can save the results for later by converting this range to an
array via
$(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`).

Type_Mappings: $(TYPE_MAPPINGS)

Example:
---
SafeResultRange oneAtATime = myConnection.query("SELECT * from myTable");
SafeRow[]       allAtOnce  = myConnection.query("SELECT * from myTable").array;
---
+/
struct SafeResultRange
{
private:
	import mysql.impl.connection;
@safe:
	Connection       _con;
	ResultSetHeaders _rsh;
	SafeRow          _row; // current row
	string[]         _colNames;
	size_t[string]   _colNameIndicies;
	ulong            _numRowsFetched;
	ulong            _commandID; // So we can keep track of when this is invalidated

	void ensureValid() const pure
	{
		enforce!MYXInvalidatedRange(isValid,
			"This ResultRange has been invalidated and can no longer be used.");
	}

package(mysql):
	this (Connection con, ResultSetHeaders rsh, string[] colNames)
	{
		_con       = con;
		_rsh       = rsh;
		_colNames  = colNames;
		_commandID = con.lastCommandID;
		popFront();
	}

public:
	/++
	Check whether the range can still be used, or has been invalidated.

	A `SafeResultRange` becomes invalidated (and thus cannot be used) when the
	server is sent another command on the same connection. When an invalidated
	`SafeResultRange` is used, a `mysql.exceptions.MYXInvalidatedRange` is
	thrown. If you need to send the server another command, but still access
	these results afterwords, you can save the results for later by converting
	this range to an array via
	$(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`).
	+/
	@property bool isValid() const pure nothrow
	{
		return _con !is null && _commandID == _con.lastCommandID;
	}

	/// Check whether there are any rows left
	@property bool empty() const pure nothrow
	{
		if(!isValid)
			return true;

		return !_con._rowsPending;
	}

	/++
	Gets the current row
	+/
	@property inout(SafeRow) front() pure inout
	{
		ensureValid();
		enforce!MYX(!empty, "Attempted 'front' on exhausted result sequence.");
		return _row;
	}

	/++
	Progresses to the next row of the result set - that will then be 'front'
	+/
	void popFront()
	{
		ensureValid();
		enforce!MYX(!empty, "Attempted 'popFront' when no more rows available");
		_row = _con.getNextRow();
		_numRowsFetched++;
	}

	/++
	Get the current row as an associative array by column name

	Type_Mappings: $(TYPE_MAPPINGS)
	+/
	MySQLVal[string] asAA()
	{
		ensureValid();
		enforce!MYX(!empty, "Attempted 'front' on exhausted result sequence.");
		MySQLVal[string] aa;
		foreach (size_t i, string s; _colNames)
			aa[s] = _row._values[i];
		return aa;
	}

	/// Get the names of all the columns
	@property const(string)[] colNames() const pure nothrow { return _colNames; }

	/// An AA to lookup a column's index by name
	@property const(size_t[string]) colNameIndicies() pure nothrow
	{
		if(_colNameIndicies is null)
		{
			foreach(index, name; _colNames)
				_colNameIndicies[name] = index;
		}

		return _colNameIndicies;
	}

	/// Explicitly clean up the MySQL resources and cancel pending results
	void close()
	out{ assert(!isValid); }
	body
	{
		if(isValid)
			_con.purgeResult();
	}

	/++
	Get the number of rows retrieved so far.

	Note that this is not neccessarlly the same as the length of the range.
	+/
	@property ulong rowCount() const pure nothrow { return _numRowsFetched; }
}

/+
A wrapper of a SafeResultRange which converts each row into an UnsafeRow.

Use the safe or unsafe UFCS methods to convert to and from these two types if
needed.

$(SAFE_MIGRATION)
+/
struct UnsafeResultRange
{
	/// The underlying range is a SafeResultRange.
	SafeResultRange safe;
	alias safe this;
	/// Equivalent to SafeResultRange.front, but wraps as an UnsafeRow.
	inout(UnsafeRow) front() inout { return inout(UnsafeRow)(safe.front); }

	/// Equivalent to SafeResultRange.asAA, but converts each value to a Variant
	Variant[string] asAA()
	{
		ensureValid();
		enforce!MYX(!safe.empty, "Attempted 'front' on exhausted result sequence.");
		Variant[string] aa;
		foreach (size_t i, string s; _colNames)
			aa[s] = _row._values[i].asVariant;
		return aa;
	}
}

/// Wrap a SafeResultRange as an UnsafeResultRange.
UnsafeResultRange unsafe(SafeResultRange r) @safe
{
	return UnsafeResultRange(r);
}
