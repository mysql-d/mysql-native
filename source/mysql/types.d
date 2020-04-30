/// Structures for MySQL types not built-in to D/Phobos.
module mysql.types;
import taggedalgebraic.taggedalgebraic;
import std.datetime : DateTime, TimeOfDay, Date;
import std.typecons : Nullable;

/++
A simple struct to represent time difference.

D's std.datetime does not have a type that is closely compatible with the MySQL
interpretation of a time difference, so we define a struct here to hold such
values.
+/
struct TimeDiff
{
	bool negative;
	int days;
	ubyte hours, minutes, seconds;
}

/++
A D struct to stand for a TIMESTAMP

It is assumed that insertion of TIMESTAMP values will not be common, since in general,
such columns are used for recording the time of a row insertion, and are filled in
automatically by the server. If you want to force a timestamp value in a prepared insert,
set it into a timestamp struct as an unsigned long in the format YYYYMMDDHHMMSS
and use that for the appropriate parameter. When TIMESTAMPs are retrieved as part of
a result set it will be as DateTime structs.
+/
struct Timestamp
{
	ulong rep;
}

private union _MYTYPE
{
@safeOnly:
	// blobs are const because of the indirection. In this case, it's not
	// important because nobody is going to use MySQLVal to maintain their
	// ubyte array.
	ubyte[] Blob;
	const(ubyte)[] CBlob;

	typeof(null) Null;
	bool Bit;
	ubyte UByte;
	byte Byte;
	ushort UShort;
	short Short;
	uint UInt;
	int Int;
	ulong ULong;
	long Long;
	float Float;
	double Double;
	.DateTime DateTime;
	TimeOfDay Time;
	.Timestamp Timestamp;
	.Date Date;

	@disableIndex string Text;
	@disableIndex const(char)[] CText;

	// pointers
	const(bool)* BitRef;
	const(ubyte)* UByteRef;
	const(byte)* ByteRef;
	const(ushort)* UShortRef;
	const(short)* ShortRef;
	const(uint)* UIntRef;
	const(int)* IntRef;
	const(ulong)* ULongRef;
	const(long)* LongRef;
	const(float)* FloatRef;
	const(double)* DoubleRef;
	const(.DateTime)* DateTimeRef;
	const(TimeOfDay)* TimeRef;
	const(.Date)* DateRef;
	const(string)* TextRef;
	const(char[])* CTextRef;
	const(ubyte[])* BlobRef;
	const(.Timestamp)* TimestampRef;
}

/++
MySQLVal is MySQL's tagged algebraic type that supports only @safe usage
(see $(LINK2, http://code.dlang.org/packages/taggedalgebraic, TaggedAlgebraic)
for more information on the features of this type). Note that TaggedAlgebraic
has UFCS methods that are not available without importing that module in your
code.

The type can hold any possible type that MySQL can use or return. The _MYTYPE
union, which is a private union for the project, defines the names of the types
that can be stored. These names double as the names for the MySQLVal.Kind
enumeration. To that end, this is the entire union definition:

------
private union _MYTYPE
{
	ubyte[] Blob;
	const(ubyte)[] CBlob;

	typeof(null) Null;
	bool Bit;
	ubyte UByte;
	byte Byte;
	ushort UShort;
	short Short;
	uint UInt;
	int Int;
	ulong ULong;
	long Long;
	float Float;
	double Double;
	std.datetime.DateTime DateTime;
	std.datetime.TimeOfDay Time;
	mysql.types.Timestamp Timestamp;
	std.datetime.Date Date;

	string Text;
	const(char)[] CText;

	// pointers
	const(bool)* BitRef;
	const(ubyte)* UByteRef;
	const(byte)* ByteRef;
	const(ushort)* UShortRef;
	const(short)* ShortRef;
	const(uint)* UIntRef;
	const(int)* IntRef;
	const(ulong)* ULongRef;
	const(long)* LongRef;
	const(float)* FloatRef;
	const(double)* DoubleRef;
	const(DateTime)* DateTimeRef;
	const(TimeOfDay)* TimeRef;
	const(Date)* DateRef;
	const(string)* TextRef;
	const(char[])* CTextRef;
	const(ubyte[])* BlobRef;
	const(Timestamp)* TimestampRef;
}
------

Note that the pointers are all const, as the only use case in mysql-native for them is as rebindable parameters to a Prepared struct.

MySQLVal allows operations, field, and member function access for each of the supported types without unwrapping the MySQLVal value. For example:

------
import mysql.safe;

// support for comparison is valid for any type that supports it
assert(conn.queryValue("SELECT COUNT(*) FROM sometable") > 20);

// access members of supporting types without unwrapping or verifying type first
assert(conn.queryValue("SELECT updated_date FROM someTable WHERE id=5").year == 2020);

// arithmetic is supported, return type may vary
auto val = conn.queryValue("SELECT some_integer FROM sometable WHERE id=5") + 100;
static assert(is(typeof(val) == MySQLVal));
assert(val.kind == MySQLVal.Kind.Int);

// this will be a double and not a MySQLVal, because all types that support
// addition with a double result in a double.
auto val2 = conn.queryValue("SELECT some_float FROM sometable WHERE id=5") + 100.0;
static assert(is(typeof(val2) == double));
------

MySQLVal is used in all operations interally for mysql-native, and explicitly
for all safe API calls. Version 3.0.x and earlier of the mysql-native library
used Variant, so this module provides multiple shims to allow code to "just
work", and also provides conversion back to Variant.

$(SAFE_MIGRATION)
+/
alias MySQLVal = TaggedAlgebraic!_MYTYPE;

// helper to convert variants to MySQLVal. Used wherever variant is still used.
import std.variant : Variant;
package MySQLVal _toVal(Variant v)
{
	int x;
	// unfortunately, we need to use a giant switch. But hopefully people will stop using Variant, and this will go away.
	string ts = v.type.toString();
	bool isRef;
	if (ts[$-1] == '*')
	{
		ts.length = ts.length-1;
		isRef= true;
	}

	import std.meta;
	import std.traits;
	import mysql.exceptions;
	alias BasicTypes = AliasSeq!(bool, byte, ubyte, short, ushort, int, uint, long, ulong, float, double, DateTime, TimeOfDay, Date, Timestamp);
	alias ArrayTypes = AliasSeq!(char[], const(char)[], ubyte[], const(ubyte)[], immutable(ubyte)[]);
	switch (ts)
	{
		static foreach(Type; BasicTypes)
		{
		case fullyQualifiedName!Type:
		case "const(" ~ fullyQualifiedName!Type ~ ")":
		case "immutable(" ~ fullyQualifiedName!Type ~ ")":
		case "shared(immutable(" ~ fullyQualifiedName!Type ~ "))":
			if(isRef)
				return MySQLVal(v.get!(const(Type*)));
			else
				return MySQLVal(v.get!(const(Type)));
		}
		static foreach(Type; ArrayTypes)
		{
		case Type.stringof:
			{
				alias ET = Unqual!(typeof(Type.init[0]));
				if(isRef)
					return MySQLVal(v.get!(const(ET[]*)));
				else
					return MySQLVal(v.get!(Type));
			}
		}
	case "immutable(char)[]":
		// have to do this separately, because everything says "string" but
		// Variant says "immutable(char)[]"
		if(isRef)
			return MySQLVal(v.get!(const(char[]*)));
		else
			return MySQLVal(v.get!(string));
	case "typeof(null)":
		return MySQLVal(null);
	default:
		throw new MYX("Unsupported Database Variant Type: " ~ ts);
	}
}

/++
Convert a MySQLVal into a Variant. This provides a backwards-compatible shim to use if necessary when transitioning to the safe API.

$(SAFE_MIGRATION)
+/
Variant asVariant(MySQLVal v)
{
	return v.apply!((a) => Variant(a));
}

/// ditto
Nullable!Variant asVariant(Nullable!MySQLVal v)
{
	if(v.isNull)
		return Nullable!Variant();
	return Nullable!Variant(v.get.asVariant);
}

/++
Compatibility layer for MySQLVal. These functions provide methods that
$(LINK2, http://code.dlang.org/packages/taggedalgebraic, TaggedAlgebraic)
does not provide in order to keep functionality that was available with Variant.

Notes:

The `type` shim should be avoided in favor of using the `kind` property of
TaggedAlgebraic.

The `get` shim works differently than the TaggedAlgebraic version, as the
Variant get function would provide implicit type conversions, but the
TaggedAlgebraic version did not.

All shims other than `type` will likely remain as convenience features.

Note that `peek` is inferred @system because it returns a pointer to the
provided value.

$(SAFE_MIGRATION)
+/
bool convertsTo(T)(ref MySQLVal val)
{
	return val.apply!((a) => is(typeof(a) : T));
}

/// ditto
T get(T)(auto ref MySQLVal val)
{
	static T convert(V)(ref V v)
	{
		static if(is(V : T))
			return v;
		else
		{
			import mysql.exceptions;
			throw new MYX("Cannot get type " ~ T.stringof ~ " with MySQLVal storing type " ~ V.stringof);
		}
	}
	return val.apply!convert();
}

/// ditto
T coerce(T)(auto ref MySQLVal val)
{
	import std.conv : to;
	static T convert(V)(ref V v)
	{
		static if(is(V : T))
		{
			return v;
		}
		else static if(is(typeof(v.to!T())))
		{
			return v.to!T;
		}
		else
		{
			import mysql.exceptions;
			throw new MYX("Cannot coerce type " ~ V.stringof ~ " into type " ~ T.stringof);
		}
	}
	return val.apply!convert();
}

/// ditto
TypeInfo type(MySQLVal val) @safe pure nothrow
{
	return val.apply!((ref v) => typeid(v));
}

/// ditto
T *peek(T)(ref MySQLVal val)
{
	// use exact type.
	import taggedalgebraic.taggedalgebraic : get;
	if(val.hasType!T)
		return &val.get!T;
	return null;
}
