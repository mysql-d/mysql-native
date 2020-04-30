/++
Implementation - Prepared statements.

WARNING:
This module is used to consolidate the common implementation of the safe and
unafe API. DO NOT directly import this module, please import one of
`mysql.prepared`, `mysql.safe.prepared`, or `mysql.unsafe.prepared`. This
module will be removed in a future version without deprecation.

$(SAFE_MIGRATION)
+/
module mysql.impl.prepared;

import std.exception;
import std.range;
import std.traits;
import std.typecons;
import std.variant;

import mysql.exceptions;
import mysql.protocol.comms;
import mysql.protocol.constants;
import mysql.protocol.packets;
import mysql.types;
import mysql.impl.result;
import mysql.safe.commands : ColumnSpecialization, CSN;
debug(MYSQLN_TESTS)
	import mysql.test.common;

/++
A struct to represent specializations of prepared statement parameters.

If you need to send large objects to the database it might be convenient to
send them in pieces. The `chunkSize` and `chunkDelegate` variables allow for this.
If both are provided then the corresponding column will be populated by calling the delegate repeatedly.
The source should fill the indicated slice with data and arrange for the delegate to
return the length of the data supplied (in bytes). If that is less than the `chunkSize`
then the chunk will be assumed to be the last one.

Please use one of the aliases instead of the Impl struct, as this name likely will be removed without deprecation in a future release.
+/
struct ParameterSpecializationImpl(bool isSafe)
{
	import mysql.protocol.constants;

	size_t pIndex;    //parameter number 0 - number of params-1
	SQLType type = SQLType.INFER_FROM_D_TYPE;
	uint chunkSize; /// In bytes
	static if(isSafe)
		uint delegate(ubyte[]) @safe chunkDelegate;
	else
		uint delegate(ubyte[]) @system chunkDelegate;
}

/// ditto
alias SafeParameterSpecialization = ParameterSpecializationImpl!true;
/// ditto
alias UnsafeParameterSpecialization = ParameterSpecializationImpl!false;
/// ditto
alias SPSN = SafeParameterSpecialization;
/// ditto
alias UPSN = UnsafeParameterSpecialization;

@("paramSpecial")
debug(MYSQLN_TESTS)
@system unittest
{
	static void test(bool isSafe)()
	{
		import std.array;
		import std.range;
		import mysql.test.common;
		mixin(doImports(isSafe, "connection", "commands", "prepared"));
		mixin(scopedCn);

		// Setup
		cn.exec("DROP TABLE IF EXISTS `paramSpecial`");
		cn.exec("CREATE TABLE `paramSpecial` (
											  `data` LONGBLOB
											 ) ENGINE=InnoDB DEFAULT CHARSET=utf8");

		immutable totalSize = 1000; // Deliberately not a multiple of chunkSize below
		auto alph = cast(const(ubyte)[]) "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
		auto data = alph.cycle.take(totalSize).array;

		int chunkSize;
		const(ubyte)[] dataToSend;
		bool finished;
		uint sender(ubyte[] chunk)
		{
			assert(!finished);
			assert(chunk.length == chunkSize);

			if(dataToSend.length < chunkSize)
			{
				auto actualSize = cast(uint) dataToSend.length;
				chunk[0..actualSize] = dataToSend[];
				finished = true;
				dataToSend.length = 0;
				return actualSize;
			}
			else
			{
				chunk[] = dataToSend[0..chunkSize];
				dataToSend = dataToSend[chunkSize..$];
				return chunkSize;
			}
		}

		immutable selectSQL = "SELECT `data` FROM `paramSpecial`";

		// Sanity check
		cn.exec("INSERT INTO `paramSpecial` VALUES (\""~(cast(const(char)[])data)~"\")");
		auto value = cn.queryValue(selectSQL);
		assert(!value.isNull);
		assert(value.get == data);

		{
			// Clear table
			cn.exec("DELETE FROM `paramSpecial`");
			value = cn.queryValue(selectSQL); // Ensure deleted
			assert(value.isNull);

			// Test: totalSize as a multiple of chunkSize
			chunkSize = 100;
			assert(cast(int)(totalSize / chunkSize) * chunkSize == totalSize);
			auto paramSpecial = ParameterSpecialization(0, SQLType.INFER_FROM_D_TYPE, chunkSize, &sender);

			finished = false;
			dataToSend = data;
			auto prepared = cn.prepare("INSERT INTO `paramSpecial` VALUES (?)");
			prepared.setArg(0, cast(ubyte[])[], paramSpecial);
			assert(cn.exec(prepared) == 1);
			value = cn.queryValue(selectSQL);
			assert(!value.isNull);
			assert(value.get == data);
		}

		{
			// Clear table
			cn.exec("DELETE FROM `paramSpecial`");
			value = cn.queryValue(selectSQL); // Ensure deleted
			assert(value.isNull);

			// Test: totalSize as a non-multiple of chunkSize
			chunkSize = 64;
			assert(cast(int)(totalSize / chunkSize) * chunkSize != totalSize);
			auto paramSpecial = ParameterSpecialization(0, SQLType.INFER_FROM_D_TYPE, chunkSize, &sender);

			finished = false;
			dataToSend = data;
			auto prepared = cn.prepare("INSERT INTO `paramSpecial` VALUES (?)");
			prepared.setArg(0, cast(ubyte[])[], paramSpecial);
			assert(cn.exec(prepared) == 1);
			value = cn.queryValue(selectSQL);
			assert(!value.isNull);
			assert(value.get == data);
		}
	}

	test!false();
	() @safe {test!true();} ();
}

/++
Encapsulation of a prepared statement.

Create this via the function `mysql.safe.connection.prepare`. Set your arguments (if any) via
the functions provided, and then run the statement by passing it to
`mysql.safe.commands.exec`/`mysql.safe.commands.query`/etc in place of the sql string parameter.

Commands that are expected to return a result set - queries - have distinctive
methods that are enforced. That is it will be an error to call such a method
with an SQL command that does not produce a result set. So for commands like
SELECT, use the `mysql.safe.commands.query` functions. For other commands, like
INSERT/UPDATE/CREATE/etc, use `mysql.safe.commands.exec`.
+/
struct SafePrepared
{
	@safe:
private:
	const(char)[] _sql;

package(mysql):
	ushort _numParams; /// Number of parameters this prepared statement takes
	PreparedStmtHeaders _headers;
	MySQLVal[] _inParams;
	SPSN[] _psa;
	CSN[] _columnSpecials;
	ulong _lastInsertID;

	ExecQueryImplInfo getExecQueryImplInfo(uint statementId)
	{
		return ExecQueryImplInfo(true, null, statementId, _headers, _inParams, _psa);
	}

public:
	/++
	Constructor. You probably want `mysql.safe.connection.prepare` instead of this.

	Call `mysqln.safe.connection.prepare` instead of this, unless you are creating
	your own transport bypassing `mysql.impl.connection.Connection` entirely.
	The prepared statement must be registered on the server BEFORE this is
	called (which `mysqln.safe.connection.prepare` does).

	Internally, the result of a successful outcome will be a statement handle - an ID -
	for the prepared statement, a count of the parameters required for
	execution of the statement, and a count of the columns that will be present
	in any result set that the command generates.

	The server will then proceed to send prepared statement headers,
	including parameter descriptions, and result set field descriptions,
	followed by an EOF packet.
	+/
	this(const(char[]) sql, PreparedStmtHeaders headers, ushort numParams)
	{
		this._sql        = sql;
		this._headers    = headers;
		this._numParams  = numParams;
		_inParams.length = numParams;
		_psa.length      = numParams;
	}

	/++
	Prepared statement parameter setter.

	The value may, but doesn't have to be, wrapped in a MySQLVal. If so,
	null is handled correctly.

	The value may, but doesn't have to be, a pointer to the desired value.

	The value may, but doesn't have to be, wrapped in a Nullable!T. If so,
	null is handled correctly.

	The value can be null.

	Parameter specializations (ie, for chunked transfer) can be added if required.
	If you wish to use chunked transfer (via `psn`), note that you must supply
	a dummy value for `val` that's typed `ubyte[]`. For example: `cast(ubyte[])[]`.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: index = The zero based index
	+/
	void setArg(T)(size_t index, T val, SafeParameterSpecialization psn = SPSN.init)
		if(!isInstanceOf!(Nullable, T) && !is(T == Variant))
	{
		// Now in theory we should be able to check the parameter type here, since the
		// protocol is supposed to send us type information for the parameters, but this
		// capability seems to be broken. This assertion is supported by the fact that
		// the same information is not available via the MySQL C API either. It is up
		// to the programmer to ensure that appropriate type information is embodied
		// in the variant array, or provided explicitly. This sucks, but short of
		// having a client side SQL parser I don't see what can be done.

		enforce!MYX(index < _numParams, "Parameter index out of range.");

		_inParams[index] = val;
		psn.pIndex = index;
		_psa[index] = psn;
	}

	///ditto
	void setArg(T)(size_t index, Nullable!T val, SafeParameterSpecialization psn = SPSN.init)
	{
		if(val.isNull)
			setArg(index, null, psn);
		else
			setArg(index, val.get(), psn);
	}

	@("setArg-typeMods")
	debug(MYSQLN_TESTS)
	@system unittest
	{
		void test(bool isSafe)()
		{
			import mysql.test.common;
			mixin(doImports(isSafe, "commands"));
			mixin(scopedCn);

			// Setup
			cn.exec("DROP TABLE IF EXISTS `setArg-typeMods`");
			cn.exec("CREATE TABLE `setArg-typeMods` (
													 `i` INTEGER
													) ENGINE=InnoDB DEFAULT CHARSET=utf8");

			auto insertSQL = "INSERT INTO `setArg-typeMods` VALUES (?)";

			// Sanity check
			{
				int i = 111;
				assert(cn.exec(insertSQL, i) == 1);
				auto value = cn.queryValue("SELECT `i` FROM `setArg-typeMods`");
				assert(!value.isNull);
				assert(value.get == i);
			}

			// Test const(int)
			{
				const(int) i = 112;
				assert(cn.exec(insertSQL, i) == 1);
			}

			// Test immutable(int)
			{
				immutable(int) i = 113;
				assert(cn.exec(insertSQL, i) == 1);
			}

			// Note: Variant doesn't seem to support
			// `shared(T)` or `shared(const(T)`. Only `shared(immutable(T))`.

			// Further note, shared immutable(int) is really
			// immutable(int). This test is a duplicate, so removed.
			// Test shared immutable(int)
			/*{
			shared immutable(int) i = 113;
			assert(cn.exec(insertSQL, i) == 1);
			}*/
		}

		test!false();
		() @safe {test!true();} ();
	}

	/++
	Bind a tuple of D variables to the parameters of a prepared statement.

	You can use this method to bind a set of variables if you don't need any specialization,
	that is chunked transfer is not neccessary.

	The tuple must match the required number of parameters, and it is the programmer's
	responsibility to ensure that they are of appropriate types.

	Type_Mappings: $(TYPE_MAPPINGS)
	+/
	void setArgs(T...)(T args)
		if(T.length == 0 || (!is(T[0] == Variant[]) && !is(T[0] == MySQLVal[])))
	{
		enforce!MYX(args.length == _numParams, "Argument list supplied does not match the number of parameters.");

		foreach (size_t i, arg; args)
			setArg(i, arg);
	}

	/++
	Bind a MySQLVal[] as the parameters of a prepared statement.

	You can use this method to bind a set of variables in MySQLVal form to
	the parameters of a prepared statement.

	Parameter specializations (ie, for chunked transfer) can be added if required.
	If you wish to use chunked transfer (via `psn`), note that you must supply
	a dummy value for `val` that's typed `ubyte[]`. For example: `cast(ubyte[])[]`.

	This method could be
	used to add records from a data entry form along the lines of
	------------
	auto stmt = conn.prepare("INSERT INTO `table42` VALUES(?, ?, ?)");
	DataRecord dr;    // Some data input facility
	ulong ra;
	do
	{
	    dr.get();
	    stmt.setArgs(dr("Name"), dr("City"), dr("Whatever"));
	    ulong rowsAffected = conn.exec(stmt);
	} while(!dr.done);
	------------

	Type_Mappings: $(TYPE_MAPPINGS)

	Params:
	args = External list of MySQLVal to be used as parameters
	psnList = Any required specializations
	+/
	void setArgs(MySQLVal[] args, SafeParameterSpecialization[] psnList=null)
	{
		enforce!MYX(args.length == _numParams, "Param count supplied does not match prepared statement");
		_inParams[] = args[];
		if (psnList !is null)
		{
			foreach (psn; psnList)
				_psa[psn.pIndex] = psn;
		}
	}

	/++
	Prepared statement parameter getter.

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: index = The zero based index
	Returns: The MySQLVal representing the argument.
	+/
	MySQLVal getArg(size_t index)
	{
		enforce!MYX(index < _numParams, "Parameter index out of range.");
		return _inParams[index];
	}

	/++
	Sets a prepared statement parameter to NULL.

	This is here mainly for legacy reasons. You can set a field to null
	simply by saying `prepared.setArg(index, null);`

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: index = The zero based index
	+/
	deprecated("Please use setArg(index, null)")
	void setNullArg(size_t index)
	{
		setArg(index, null);
	}

	/// Gets the SQL command for this prepared statement.
	const(char)[] sql() pure const
	{
		return _sql;
	}

	@("setNullArg")
	debug(MYSQLN_TESTS)
	unittest
	{
		static void test(bool isSafe)()
		{
			import mysql.test.common;
			mixin(doImports(isSafe, "connection", "commands"));
			mixin(scopedCn);

			cn.exec("DROP TABLE IF EXISTS `setNullArg`");
			cn.exec("CREATE TABLE `setNullArg` (
												`val` INTEGER
											   ) ENGINE=InnoDB DEFAULT CHARSET=utf8");

			immutable insertSQL = "INSERT INTO `setNullArg` VALUES (?)";
			immutable selectSQL = "SELECT * FROM `setNullArg`";
			auto preparedInsert = cn.prepare(insertSQL);
			assert(preparedInsert.sql == insertSQL);
			SafeRow[] rs;

			{
				Nullable!int nullableInt;
				nullableInt.nullify();
				preparedInsert.setArg(0, nullableInt);
				assert(preparedInsert.getArg(0).kind == MySQLVal.Kind.Null);
				nullableInt = 7;
				preparedInsert.setArg(0, nullableInt);
				assert(preparedInsert.getArg(0) == 7);

				nullableInt.nullify();
				preparedInsert.setArgs(nullableInt);
				assert(preparedInsert.getArg(0).kind == MySQLVal.Kind.Null);
				nullableInt = 7;
				preparedInsert.setArgs(nullableInt);
				assert(preparedInsert.getArg(0) == 7);
			}

			preparedInsert.setArg(0, 5);
			cn.exec(preparedInsert);
			rs = cn.query(selectSQL).array;
			assert(rs.length == 1);
			assert(rs[0][0] == 5);

			preparedInsert.setArg(0, null);
			cn.exec(preparedInsert);
			rs = cn.query(selectSQL).array;
			assert(rs.length == 2);
			assert(rs[0][0] == 5);
			assert(rs[1].isNull(0));
			assert(rs[1][0].kind == MySQLVal.Kind.Null);

			preparedInsert.setArg(0, MySQLVal(null));
			cn.exec(preparedInsert);
			rs = cn.query(selectSQL).array;
			assert(rs.length == 3);
			assert(rs[0][0] == 5);
			assert(rs[1].isNull(0));
			assert(rs[2].isNull(0));
			assert(rs[1][0].kind == MySQLVal.Kind.Null);
			assert(rs[2][0] == null);
		}
	}

	/// Gets the number of arguments this prepared statement expects to be passed in.
	@property ushort numArgs() pure const nothrow
	{
		return _numParams;
	}

	/// After a command that inserted a row into a table with an auto-increment
	/// ID column, this method allows you to retrieve the last insert ID generated
	/// from this prepared statement.
	@property ulong lastInsertID() pure const nothrow { return _lastInsertID; }

	@("lastInsertID")
	debug(MYSQLN_TESTS)
	@system unittest
	{
		static void test(bool isSafe)()
		{
			mixin(doImports(isSafe, "connection", "commands"));
			mixin(scopedCn);
			cn.exec("DROP TABLE IF EXISTS `testPreparedLastInsertID`");
			cn.exec("CREATE TABLE `testPreparedLastInsertID` (
				`a` INTEGER NOT NULL AUTO_INCREMENT,
				PRIMARY KEY (a)
			) ENGINE=InnoDB DEFAULT CHARSET=utf8");

			auto stmt = cn.prepare("INSERT INTO `testPreparedLastInsertID` VALUES()");
			cn.exec(stmt);
			assert(stmt.lastInsertID == 1);
			cn.exec(stmt);
			assert(stmt.lastInsertID == 2);
			cn.exec(stmt);
			assert(stmt.lastInsertID == 3);
		}

		test!false();
		() @safe { test!true(); }();
	}

	/// Gets the prepared header's field descriptions.
	@property FieldDescription[] preparedFieldDescriptions() pure { return _headers.fieldDescriptions; }

	/// Gets the prepared header's param descriptions.
	@property ParamDescription[] preparedParamDescriptions() pure { return _headers.paramDescriptions; }

	/// Get/set the column specializations.
	@property ColumnSpecialization[] columnSpecials() pure { return _columnSpecials; }

	///ditto
	@property void columnSpecials(ColumnSpecialization[] csa) pure { _columnSpecials = csa; }
}

/++
Unsafe wrapper for SafePrepared.

This wrapper contains a SafePrepared, and forwards common functionality to that
type. It overrides the setting and fetching of arguments, converting them to
and from Variant for backwards compatibility.

It also sets up UnsafeParameterSpecialization items for the parameters. Note
that these are simply cast to SafeParameterSpecialization. There are runtime
guards in place to ensure a SafeParameterSpecialization with an unsafe delegate
is not accessible as a safe delegate.

$(SAFE_MIGRATION)
+/
struct UnsafePrepared
{
	private SafePrepared _safe;

	private this(SafePrepared sp) @safe
	{
		_safe = sp;
	}

	this(const(char[]) sql, PreparedStmtHeaders headers, ushort numParams) @safe
	{
		_safe = SafePrepared(sql, headers, numParams);
	}

	/++
	Redefine all functions that deal with MySQLVal to deal with Variant instead. Please see SafePrepared for details on how the methods work.

	$(SAFE_MIGRATION)
	+/
	void setArg(T)(size_t index, T val, UnsafeParameterSpecialization psn = UPSN.init) @system
		if(!is(T == Variant))
	{
		_safe.setArg(index, val, cast(SPSN)psn);
	}

	/// ditto
	void setArg(size_t index, Variant val, UnsafeParameterSpecialization psn = UPSN.init) @system
	{
		_safe.setArg(index, _toVal(val), cast(SPSN)psn);
	}

	/// ditto
	void setArgs(T...)(T args)
		if(T.length == 0 || (!is(T[0] == Variant[]) && !is(T[0] == MySQLVal[])))
	{
		_safe.setArgs(args);
	}

	/// ditto
	void setArgs(Variant[] args, UnsafeParameterSpecialization[] psnList=null) @system
	{
		enforce!MYX(args.length == _safe._numParams, "Param count supplied does not match prepared statement");
		foreach(i, ref arg; args)
			_safe.setArg(i, _toVal(arg));
		if (psnList !is null)
		{
			foreach (psn; psnList)
				_safe._psa[psn.pIndex] = cast(SPSN)psn;
		}
	}

	/// ditto
	Variant getArg(size_t index) @system
	{
		return _safe.getArg(index).asVariant;
	}

	/++
	Allow conversion to a SafePrepared. UnsafePrepared with
	UnsafeParameterSpecialization items that have chunk delegates are not
	allowed to convert, because the delegates are possibly unsafe.
	+/
	ref SafePrepared safe() scope return @safe
	{
		// first, ensure there are no parameter specializations with delegates as
		// those are possibly unsafe.
		foreach(ref s; _safe._psa)
			enforce!MYX(s.chunkDelegate is null, "Cannot convert UnsafePrepared into SafePrepared with unsafe chunk delegates");
		return _safe;
	}

	// this package method is to skip the ckeck for parameter specializations
	// with chunk delegates. It can only be used when using the safe prepared
	// statement for execution.
	package(mysql) ref SafePrepared safeForExec() @system
	{
		return _safe;
	}

	/// forward all the methods from the safe struct. See `SafePrepared` for
	/// details.
	deprecated("Please use setArg(index, null)")
	void setNullArg(size_t index) @safe
	{
		_safe.setArg(index, null);
	}

	@safe pure @property:

	/// ditto
	const(char)[] sql() const
	{
		return _safe.sql;
	}

	/// ditto
	ushort numArgs() const nothrow
	{
		return _safe.numArgs;
	}

	/// ditto
	ulong lastInsertID() const nothrow
   	{
	   	return _safe.lastInsertID;
   	}
	/// ditto
	FieldDescription[] preparedFieldDescriptions()
	{
	   	return _safe.preparedFieldDescriptions;
   	}

	/// ditto
	ParamDescription[] preparedParamDescriptions()
	{
	   	return _safe.preparedParamDescriptions;
   	}

	/// ditto
	ColumnSpecialization[] columnSpecials()
	{
	   	return _safe.columnSpecials;
   	}

	///ditto
	void columnSpecials(ColumnSpecialization[] csa)
   	{
	   	_safe.columnSpecials(csa);
   	}

}

/// Allow conversion to UnsafePrepared from SafePrepared.
UnsafePrepared unsafe(SafePrepared p) @safe
{
	return UnsafePrepared(p);
}

/// Template constraint for `PreparedRegistrations`
private enum isPreparedRegistrationsPayload(Payload) =
	__traits(compiles, (){
			static assert(Payload.init.queuedForRelease == false);
			Payload p;
			p.queuedForRelease = true;
		});

/++
Common functionality for recordkeeping of prepared statement registration
and queueing for unregister.

Used by `Connection` and `MySQLPoolImpl`.

Templated on payload type. The payload should be an aggregate that includes
the field: `bool queuedForRelease = false;`

Allowing access to `directLookup` from other parts of mysql-native IS intentional.
`PreparedRegistrations` isn't intended as 100% encapsulation, it's mainly just
to factor out common functionality needed by both `Connection` and `MySQLPool`.
+/
package(mysql) struct PreparedRegistrations(Payload)
	if(	isPreparedRegistrationsPayload!Payload)
{
	@safe:
	/++
	Lookup payload by sql string.

	Allowing access to `directLookup` from other parts of mysql-native IS intentional.
	`PreparedRegistrations` isn't intended as 100% encapsulation, it's mainly just
	to factor out common functionality needed by both `Connection` and `MySQLPool`.
	+/
	Payload[const(char[])] directLookup;

	/// Returns null if not found
	Nullable!Payload opIndex(const(char[]) sql) pure nothrow
	{
		Nullable!Payload result;

		auto pInfo = sql in directLookup;
		if(pInfo)
			result = *pInfo;

		return result;
	}

	/// Set `queuedForRelease` flag for a statement in `directLookup`.
	/// Does nothing if statement not in `directLookup`.
	private void setQueuedForRelease(const(char[]) sql, bool value)
	{
		if(auto pInfo = sql in directLookup)
		{
			pInfo.queuedForRelease = value;
			directLookup[sql] = *pInfo;
		}
	}

	/// Queue a prepared statement for release.
	void queueForRelease(const(char[]) sql)
	{
		setQueuedForRelease(sql, true);
	}

	/// Remove a statement from the queue to be released.
	void unqueueForRelease(const(char[]) sql)
	{
		setQueuedForRelease(sql, false);
	}

	/// Queues all prepared statements for release.
	void queueAllForRelease()
	{
		foreach(sql, info; directLookup)
			queueForRelease(sql);
	}

	// Note: AA.clear does not invalidate any keys or values. In fact, it
	// should really be safe/trusted, but is not. Therefore, we mark this
	// as trusted.
	/// Eliminate all records of both registered AND queued-for-release statements.
	void clear() @trusted
	{
		static if(__traits(compiles, (){ int[int] aa; aa.clear(); }))
			directLookup.clear();
		else
			directLookup = null;
	}

	/// If already registered, simply returns the cached Payload.
	Payload registerIfNeeded(const(char[]) sql, Payload delegate(const(char[])) @safe doRegister)
	out(info)
	{
		// I'm confident this can't currently happen, but
		// let's make sure that doesn't change.
		assert(!info.queuedForRelease);
	}
	body
	{
		if(auto pInfo = sql in directLookup)
		{
			// The statement is registered. It may, or may not, be queued
			// for release. Either way, all we need to do is make sure it's
			// un-queued and then return.
			pInfo.queuedForRelease = false;
			return *pInfo;
		}

		auto info = doRegister(sql);
		directLookup[sql] = info;

		return info;
	}
}

// Test PreparedRegistrations
debug(MYSQLN_TESTS)
{
	// Test template constraint
	struct TestPreparedRegistrationsBad1 { }
	struct TestPreparedRegistrationsBad2 { bool foo = false; }
	struct TestPreparedRegistrationsBad3 { int queuedForRelease = 1; }
	struct TestPreparedRegistrationsBad4 { bool queuedForRelease = true; }
	struct TestPreparedRegistrationsGood1 { bool queuedForRelease = false; }
	struct TestPreparedRegistrationsGood2 { bool queuedForRelease = false; const(char)[] id; }

	static assert(!isPreparedRegistrationsPayload!int);
	static assert(!isPreparedRegistrationsPayload!bool);
	static assert(!isPreparedRegistrationsPayload!TestPreparedRegistrationsBad1);
	static assert(!isPreparedRegistrationsPayload!TestPreparedRegistrationsBad2);
	static assert(!isPreparedRegistrationsPayload!TestPreparedRegistrationsBad3);
	static assert(!isPreparedRegistrationsPayload!TestPreparedRegistrationsBad4);
	//static assert(isPreparedRegistrationsPayload!TestPreparedRegistrationsGood1);
	//static assert(isPreparedRegistrationsPayload!TestPreparedRegistrationsGood2);
	PreparedRegistrations!TestPreparedRegistrationsGood1 testPreparedRegistrationsGood1;
	PreparedRegistrations!TestPreparedRegistrationsGood2 testPreparedRegistrationsGood2;

	@("PreparedRegistrations")
	unittest
	{
		// Test init
		PreparedRegistrations!TestPreparedRegistrationsGood2 pr;
		assert(pr.directLookup.keys.length == 0);

		void resetData(bool isQueued1, bool isQueued2, bool isQueued3)
		{
			pr.directLookup["1"] = TestPreparedRegistrationsGood2(isQueued1, "1");
			pr.directLookup["2"] = TestPreparedRegistrationsGood2(isQueued2, "2");
			pr.directLookup["3"] = TestPreparedRegistrationsGood2(isQueued3, "3");
			assert(pr.directLookup.keys.length == 3);
		}

		// Test resetData (sanity check)
		resetData(false, true, false);
		assert(pr.directLookup["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr.directLookup["2"] == TestPreparedRegistrationsGood2(true,  "2"));
		assert(pr.directLookup["3"] == TestPreparedRegistrationsGood2(false, "3"));

		// Test opIndex
		resetData(false, true, false);
		pr.directLookup["1"] = TestPreparedRegistrationsGood2(false, "1");
		pr.directLookup["2"] = TestPreparedRegistrationsGood2(true,  "2");
		pr.directLookup["3"] = TestPreparedRegistrationsGood2(false, "3");
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(true,  "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(false, "3"));
		assert(pr["4"].isNull);

		// Test queueForRelease
		resetData(false, true, false);
		pr.queueForRelease("2");
		assert(pr.directLookup.keys.length == 3);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(true,  "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(false, "3"));

		pr.queueForRelease("3");
		assert(pr.directLookup.keys.length == 3);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(true,  "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(true,  "3"));

		pr.queueForRelease("4");
		assert(pr.directLookup.keys.length == 3);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(true,  "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(true,  "3"));

		// Test unqueueForRelease
		resetData(false, true, false);
		pr.unqueueForRelease("1");
		assert(pr.directLookup.keys.length == 3);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(true,  "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(false, "3"));

		pr.unqueueForRelease("2");
		assert(pr.directLookup.keys.length == 3);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(false, "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(false, "3"));

		pr.unqueueForRelease("4");
		assert(pr.directLookup.keys.length == 3);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(false, "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(false, "3"));

		// Test queueAllForRelease
		resetData(false, true, false);
		pr.queueAllForRelease();
		assert(pr["1"] == TestPreparedRegistrationsGood2(true,  "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(true,  "2"));
		assert(pr["3"] == TestPreparedRegistrationsGood2(true,  "3"));
		assert(pr["4"].isNull);

		// Test clear
		resetData(false, true, false);
		pr.clear();
		assert(pr.directLookup.keys.length == 0);

		// Test registerIfNeeded
		auto doRegister(const(char[]) sql) { return TestPreparedRegistrationsGood2(false, sql); }
		pr.registerIfNeeded("1", &doRegister);
		assert(pr.directLookup.keys.length == 1);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));

		pr.registerIfNeeded("1", &doRegister);
		assert(pr.directLookup.keys.length == 1);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));

		pr.registerIfNeeded("2", &doRegister);
		assert(pr.directLookup.keys.length == 2);
		assert(pr["1"] == TestPreparedRegistrationsGood2(false, "1"));
		assert(pr["2"] == TestPreparedRegistrationsGood2(false, "2"));
	}
}
