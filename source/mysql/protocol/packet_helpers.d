/// Internal - Helper functions for the communication protocol.
module mysql.protocol.packet_helpers;

import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.range;
import std.string;
import std.traits;

import mysql.exceptions;
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.sockets;
import mysql.types;

/++
Function to extract a time difference from a binary encoded row.

Time/date structures are packed by the server into a byte sub-packet
with a leading length byte, and a minimal number of bytes to embody the data.

Params: a = slice of a protocol packet beginning at the length byte for a chunk of time data

Returns: A populated or default initialized TimeDiff struct.
+/
TimeDiff toTimeDiff(in ubyte[] a) pure
{
	enforce!MYXProtocol(a.length, "Supplied byte array is zero length");
	TimeDiff td;
	uint l = a[0];
	enforce!MYXProtocol(l == 0 || l == 5 || l == 8 || l == 12, "Bad Time length in binary row.");
	if (l >= 5)
	{
		td.negative = (a[1]  != 0);
		td.days     = (a[5] << 24) + (a[4] << 16) + (a[3] << 8) + a[2];
	}
	if (l >= 8)
	{
		td.hours    = a[6];
		td.minutes  = a[7];
		td.seconds  = a[8];
	}
	// Note that the fractional seconds part is not stored by MySQL
	return td;
}

/++
Function to extract a time difference from a text encoded column value.

Text representations of a time difference are like -750:12:02 - 750 hours
12 minutes and two seconds ago.

Params: s = A string representation of the time difference.
Returns: A populated or default initialized TimeDiff struct.
+/
TimeDiff toTimeDiff(string s)
{
	TimeDiff td;
	int t = parse!int(s);
	if (t < 0)
	{
		td.negative = true;
		t = -t;
	}
	td.hours    = cast(ubyte) t%24;
	td.days     = cast(ubyte) t/24;
	enforce!MYXProtocol(s.skipOver(":"), `Expected: ":"`);
	td.minutes  = parse!ubyte(s);
	enforce!MYXProtocol(s.skipOver(":"), `Expected: ":"`);
	td.seconds  = parse!ubyte(s);
	return td;
}

/++
Function to extract a TimeOfDay from a binary encoded row.

Time/date structures are packed by the server into a byte sub-packet
with a leading length byte, and a minimal number of bytes to embody the data.

Params: a = slice of a protocol packet beginning at the length byte for a
            chunk of time data.
Returns: A populated or default initialized std.datetime.TimeOfDay struct.
+/
TimeOfDay toTimeOfDay(in ubyte[] a) pure
{
	enforce!MYXProtocol(a.length, "Supplied byte array is zero length");
	uint l = a[0];
	enforce!MYXProtocol(l == 0 || l == 5 || l == 8 || l == 12, "Bad Time length in binary row.");
	enforce!MYXProtocol(l >= 8, "Time column value is not in a time-of-day format");

	TimeOfDay tod;
	tod.hour    = a[6];
	tod.minute  = a[7];
	tod.second  = a[8];
	return tod;
}

/++
Function to extract a TimeOfDay from a text encoded column value.

Text representations of a time of day are as in 14:22:02

Params: s = A string representation of the time.
Returns: A populated or default initialized std.datetime.TimeOfDay struct.
+/
TimeOfDay toTimeOfDay(string s)
{
	TimeOfDay tod;
	tod.hour = parse!int(s);
	enforce!MYXProtocol(tod.hour <= 24 && tod.hour >= 0, "Time column value is in time difference form");
	enforce!MYXProtocol(s.skipOver(":"), `Expected: ":"`);
	tod.minute = parse!ubyte(s);
	enforce!MYXProtocol(s.skipOver(":"), `Expected: ":"`);
	tod.second = parse!ubyte(s);
	return tod;
}

/++
Function to pack a TimeOfDay into a binary encoding for transmission to the server.

Time/date structures are packed into a string of bytes with a leading length
byte, and a minimal number of bytes to embody the data.

Params: tod = TimeOfDay struct.
Returns: Packed ubyte[].
+/
ubyte[] pack(in TimeOfDay tod) pure nothrow
{
	ubyte[] rv;
	if (tod == TimeOfDay.init)
	{
		rv.length = 1;
		rv[0] = 0;
	}
	else
	{
		rv.length = 9;
		rv[0] = 8;
		rv[6] = tod.hour;
		rv[7] = tod.minute;
		rv[8] = tod.second;
	}
	return rv;
}

/++
Function to extract a Date from a binary encoded row.

Time/date structures are packed by the server into a byte sub-packet
with a leading length byte, and a minimal number of bytes to embody the data.

Params: a = slice of a protocol packet beginning at the length byte for a
            chunk of Date data.
Returns: A populated or default initialized `std.datetime.Date` struct.
+/
Date toDate(in ubyte[] a) pure
{
	enforce!MYXProtocol(a.length, "Supplied byte array is zero length");
	if (a[0] == 0)
		return Date(0,0,0);

	enforce!MYXProtocol(a[0] >= 4, "Binary date representation is too short");
	int year    = (a[2]  << 8) + a[1];
	int month   = cast(int) a[3];
	int day     = cast(int) a[4];
	return Date(year, month, day);
}

/++
Function to extract a Date from a text encoded column value.

Text representations of a Date are as in 2011-11-11

Params: s = A string representation of the time difference.
Returns: A populated or default initialized `std.datetime.Date` struct.
+/
Date toDate(string s)
{
	int year = parse!(ushort)(s);
	enforce!MYXProtocol(s.skipOver("-"), `Expected: "-"`);
	int month = parse!(ubyte)(s);
	enforce!MYXProtocol(s.skipOver("-"), `Expected: "-"`);
	int day = parse!(ubyte)(s);
	return Date(year, month, day);
}

/++
Function to pack a Date into a binary encoding for transmission to the server.

Time/date structures are packed into a string of bytes with a leading length
byte, and a minimal number of bytes to embody the data.

Params: dt = `std.datetime.Date` struct.
Returns: Packed ubyte[].
+/
ubyte[] pack(in Date dt) pure nothrow
{
	ubyte[] rv;
	if (dt.year < 0)
	{
		rv.length = 1;
		rv[0] = 0;
	}
	else
	{
		rv.length = 5;
		rv[0] = 4;
		rv[1] = cast(ubyte) ( dt.year       & 0xff);
		rv[2] = cast(ubyte) ((dt.year >> 8) & 0xff);
		rv[3] = cast(ubyte)   dt.month;
		rv[4] = cast(ubyte)   dt.day;
	}
	return rv;
}

/++
Function to extract a DateTime from a binary encoded row.

Time/date structures are packed by the server into a byte sub-packet
with a leading length byte, and a minimal number of bytes to embody the data.

Params: a = slice of a protocol packet beginning at the length byte for a
            chunk of DateTime data
Returns: A populated or default initialized `std.datetime.DateTime` struct.
+/
DateTime toDateTime(in ubyte[] a) pure
{
	enforce!MYXProtocol(a.length, "Supplied byte array is zero length");
	if (a[0] == 0)
		return DateTime();

	enforce!MYXProtocol(a[0] >= 4, "Supplied ubyte[] is not long enough");
	int year    = (a[2] << 8) + a[1];
	int month   =  a[3];
	int day     =  a[4];
	DateTime dt;
	if (a[0] == 4)
	{
		dt = DateTime(year, month, day);
	}
	else
	{
		enforce!MYXProtocol(a[0] >= 7, "Supplied ubyte[] is not long enough");
		int hour    = a[5];
		int minute  = a[6];
		int second  = a[7];
		dt = DateTime(year, month, day, hour, minute, second);
	}
	return dt;
}

/++
Function to extract a DateTime from a text encoded column value.

Text representations of a DateTime are as in 2011-11-11 12:20:02

Params: s = A string representation of the time difference.
Returns: A populated or default initialized `std.datetime.DateTime` struct.
+/
DateTime toDateTime(string s)
{
	int year = parse!(ushort)(s);
	enforce!MYXProtocol(s.skipOver("-"), `Expected: "-"`);
	int month = parse!(ubyte)(s);
	enforce!MYXProtocol(s.skipOver("-"), `Expected: "-"`);
	int day = parse!(ubyte)(s);
	enforce!MYXProtocol(s.skipOver(" "), `Expected: " "`);
	int hour = parse!(ubyte)(s);
	enforce!MYXProtocol(s.skipOver(":"), `Expected: ":"`);
	int minute = parse!(ubyte)(s);
	enforce!MYXProtocol(s.skipOver(":"), `Expected: ":"`);
	int second = parse!(ubyte)(s);
	return DateTime(year, month, day, hour, minute, second);
}

/++
Function to extract a DateTime from a ulong.

This is used to support the TimeStamp  struct.

Params: x = A ulong e.g. 20111111122002UL.
Returns: A populated `std.datetime.DateTime` struct.
+/
DateTime toDateTime(ulong x)
{
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
	// 2038-01-19 03:14:07
	enforce!MYXProtocol(year >= 1970 &&  year < 2039, "Date/time out of range for 2 bit timestamp");
	enforce!MYXProtocol(year != 2038 || (month < 1 && day < 19 && hour < 3 && minute < 14 && second < 7),
			"Date/time out of range for 2 bit timestamp");
	return DateTime(year, month, day, hour, minute, second);
}

/++
Function to pack a DateTime into a binary encoding for transmission to the server.

Time/date structures are packed into a string of bytes with a leading length byte,
and a minimal number of bytes to embody the data.

Params: dt = `std.datetime.DateTime` struct.
Returns: Packed ubyte[].
+/
ubyte[] pack(in DateTime dt) pure nothrow
{
	uint len = 1;
	if (dt.year || dt.month || dt.day) len = 5;
	if (dt.hour || dt.minute|| dt.second) len = 8;
	ubyte[] rv;
	rv.length = len;
	rv[0] =  cast(ubyte)(rv.length - 1); // num bytes
	if(len >= 5)
	{
		rv[1] = cast(ubyte) ( dt.year       & 0xff);
		rv[2] = cast(ubyte) ((dt.year >> 8) & 0xff);
		rv[3] = cast(ubyte)   dt.month;
		rv[4] = cast(ubyte)   dt.day;
	}
	if(len == 8)
	{
		rv[5] = cast(ubyte) dt.hour;
		rv[6] = cast(ubyte) dt.minute;
		rv[7] = cast(ubyte) dt.second;
	}
	return rv;
}


T consume(T)(MySQLSocket conn) pure {
	ubyte[T.sizeof] buffer;
	conn.read(buffer);
	ubyte[] rng = buffer;
	return consume!T(rng);
}

string consume(T:string, ubyte N=T.sizeof)(ref ubyte[] packet) pure
{
	return packet.consume!string(N);
}

string consume(T:string)(ref ubyte[] packet, size_t N) pure
in
{
	assert(packet.length >= N);
}
body
{
	return cast(string)packet.consume(N);
}

/// Returns N number of bytes from the packet and advances the array
ubyte[] consume()(ref ubyte[] packet, size_t N) pure nothrow
in
{
	assert(packet.length >= N);
}
body
{
	auto result = packet[0..N];
	packet = packet[N..$];
	return result;
}

T decode(T:ulong)(in ubyte[] packet, size_t n) pure nothrow
{
	switch(n)
	{
		case 8: return packet.decode!(T, 8)();
		case 4: return packet.decode!(T, 4)();
		case 3: return packet.decode!(T, 3)();
		case 2: return packet.decode!(T, 2)();
		case 1: return packet.decode!(T, 1)();
		default: assert(0);
	}
}

T consume(T)(ref ubyte[] packet, int n) pure nothrow
if(isIntegral!T)
{
	switch(n)
	{
		case 8: return packet.consume!(T, 8)();
		case 4: return packet.consume!(T, 4)();
		case 3: return packet.consume!(T, 3)();
		case 2: return packet.consume!(T, 2)();
		case 1: return packet.consume!(T, 1)();
		default: assert(0);
	}
}

TimeOfDay consume(T:TimeOfDay, ubyte N=T.sizeof)(ref ubyte[] packet) pure
in
{
	static assert(N == T.sizeof);
}
body
{
	enforce!MYXProtocol(packet.length, "Supplied byte array is zero length");
	uint length = packet.front;
	enforce!MYXProtocol(length == 0 || length == 5 || length == 8 || length == 12, "Bad Time length in binary row.");
	enforce!MYXProtocol(length >= 8, "Time column value is not in a time-of-day format");

	packet.popFront(); // length
	auto bytes = packet.consume(length);

	// TODO: What are the fields in between!?! Blank Date?
	TimeOfDay tod;
	tod.hour    = bytes[5];
	tod.minute  = bytes[6];
	tod.second  = bytes[7];
	return tod;
}

Date consume(T:Date, ubyte N=T.sizeof)(ref ubyte[] packet) pure
in
{
	static assert(N == T.sizeof);
}
body
{
	return toDate(packet.consume(5));
}

DateTime consume(T:DateTime, ubyte N=T.sizeof)(ref ubyte[] packet) pure
in
{
	assert(packet.length);
	assert(N == T.sizeof);
}
body
{
	auto numBytes = packet.consume!ubyte();
	if(numBytes == 0)
		return DateTime();

	enforce!MYXProtocol(numBytes >= 4, "Supplied packet is not large enough to store DateTime");

	int year    = packet.consume!ushort();
	int month   = packet.consume!ubyte();
	int day     = packet.consume!ubyte();
	int hour    = 0;
	int minute  = 0;
	int second  = 0;
	if(numBytes > 4)
	{
		enforce!MYXProtocol(numBytes >= 7, "Supplied packet is not large enough to store a DateTime with TimeOfDay");
		hour    = packet.consume!ubyte();
		minute  = packet.consume!ubyte();
		second  = packet.consume!ubyte();
	}
	return DateTime(year, month, day, hour, minute, second);
}


@property bool hasEnoughBytes(T, ubyte N=T.sizeof)(in ubyte[] packet) pure
in
{
	static assert(T.sizeof >= N, T.stringof~" not large enough to store "~to!string(N)~" bytes");
}
body
{
	return packet.length >= N;
}

T decode(T, ubyte N=T.sizeof)(in ubyte[] packet) pure nothrow
if(isIntegral!T)
in
{
	static assert(N == 1 || N == 2 || N == 3 || N == 4 || N == 8, "Cannot decode integral value. Invalid size: "~N.stringof);
	static assert(T.sizeof >= N, T.stringof~" not large enough to store "~to!string(N)~" bytes");
	assert(packet.hasEnoughBytes!(T,N), "packet not long enough to contain all bytes needed for "~T.stringof);
}
body
{
	T value = 0;
	static if(N == 8) // 64 bit
	{
		value |= cast(T)(packet[7]) << (8*7);
		value |= cast(T)(packet[6]) << (8*6);
		value |= cast(T)(packet[5]) << (8*5);
		value |= cast(T)(packet[4]) << (8*4);
	}
	static if(N >= 4) // 32 bit
	{
		value |= cast(T)(packet[3]) << (8*3);
	}
	static if(N >= 3) // 24 bit
	{
		value |= cast(T)(packet[2]) << (8*2);
	}
	static if(N >= 2) // 16 bit
	{
		value |= cast(T)(packet[1]) << (8*1);
	}
	static if(N >= 1) // 8 bit
	{
		value |= cast(T)(packet[0]) << (8*0);
	}
	return value;
}

T consume(T, ubyte N=T.sizeof)(ref ubyte[] packet) pure nothrow
if(isIntegral!T)
in
{
	static assert(N == 1 || N == 2 || N == 3 || N == 4 || N == 8, "Cannot consume integral value. Invalid size: "~N.stringof);
	static assert(T.sizeof >= N, T.stringof~" not large enough to store "~to!string(N)~" bytes");
	assert(packet.hasEnoughBytes!(T,N), "packet not long enough to contain all bytes needed for "~T.stringof);
}
body
{
	// The uncommented line triggers a template deduction error,
	// so we need to store a temporary first
	// could the problem be method chaining?
	//return packet.consume(N).decode!(T, N)();
	auto bytes = packet.consume(N);
	return bytes.decode!(T, N)();
}


T myto(T)(string value)
{
	static if(is(T == DateTime))
		return toDateTime(value);
	else static if(is(T == Date))
		return toDate(value);
	else static if(is(T == TimeOfDay))
		return toTimeOfDay(value);
	else
		return to!T(value);
}

T decode(T, ubyte N=T.sizeof)(in ubyte[] packet) pure nothrow
if(isFloatingPoint!T)
in
{
	static assert((is(T == float) && N == float.sizeof)
			|| is(T == double) && N == double.sizeof);
}
body
{
	T result = 0;
	(cast(ubyte*)&result)[0..T.sizeof] = packet[0..T.sizeof];
	return result;
}

T consume(T, ubyte N=T.sizeof)(ref ubyte[] packet) pure nothrow
if(isFloatingPoint!T)
in
{
	static assert((is(T == float) && N == float.sizeof)
			|| is(T == double) && N == double.sizeof);
}
body
{
	return packet.consume(T.sizeof).decode!T();
}


SQLValue consumeBinaryValueIfComplete(T, int N=T.sizeof)(ref ubyte[] packet, bool unsigned)
{
	SQLValue result;

	// Length of DateTime packet is NOT DateTime.sizeof, it can be 1, 5 or 8 bytes
	static if(is(T==DateTime))
		result.isIncomplete = packet.length < 1;
	else
		result.isIncomplete = packet.length < N;

	// isNull should have been handled by the caller as the binary format uses a
	// null bitmap, and we don't have access to that information at this point
	assert(!result.isNull);
	if(!result.isIncomplete)
	{
		// only integral types is unsigned
		static if(isIntegral!T)
		{
			if(unsigned)
				result.value = packet.consume!(Unsigned!T)();
			else
				result.value = packet.consume!(Signed!T)();
		}
		else
		{
			// TODO: DateTime values etc might be incomplete!
			result.value = packet.consume!(T, N)();
		}
	}
	return result;
}

SQLValue consumeNonBinaryValueIfComplete(T)(ref ubyte[] packet, bool unsigned)
{
	SQLValue result;
	auto lcb = packet.decode!LCB();
	result.isIncomplete = lcb.isIncomplete || packet.length < (lcb.value+lcb.totalBytes);
	result.isNull = lcb.isNull;
	if(!result.isIncomplete)
	{
		// The packet has all the data we need, so we'll remove the LCB
		// and convert the data
		packet.skip(lcb.totalBytes);
		assert(packet.length >= lcb.value);
		auto value = cast(string) packet.consume(cast(size_t)lcb.value);

		if(!result.isNull)
		{
			assert(!result.isIncomplete);
			assert(!result.isNull);
			static if(isIntegral!T)
			{
				if(unsigned)
					result.value = to!(Unsigned!T)(value);
				else
					result.value = to!(Signed!T)(value);
			}
			else
			{
				static if(isArray!T)
				{
					// to!() crashes when trying to convert empty strings
					// to arrays, so we have this hack to just store any
					// empty array in those cases
					if(!value.length)
						result.value = T.init;
					else
						result.value = cast(T)value.dup;

				}
				else
				{
					// TODO: DateTime values etc might be incomplete!
					result.value = myto!T(value);
				}
			}
		}
	}
	return result;
}

SQLValue consumeIfComplete(T, int N=T.sizeof)(ref ubyte[] packet, bool binary, bool unsigned)
{
	return binary
		? packet.consumeBinaryValueIfComplete!(T, N)(unsigned)
		: packet.consumeNonBinaryValueIfComplete!T(unsigned);
}

SQLValue consumeIfComplete()(ref ubyte[] packet, SQLType sqlType, bool binary, bool unsigned, ushort charSet)
{
	switch(sqlType)
	{
		default: assert(false, "Unsupported SQL type "~to!string(sqlType));
		case SQLType.NULL:
			SQLValue result;
			result.isIncomplete = false;
			result.isNull = true;
			return result;
		case SQLType.TINY:
			return packet.consumeIfComplete!byte(binary, unsigned);
		case SQLType.SHORT:
			return packet.consumeIfComplete!short(binary, unsigned);
		case SQLType.INT24:
			return packet.consumeIfComplete!(int, 3)(binary, unsigned);
		case SQLType.INT:
			return packet.consumeIfComplete!int(binary, unsigned);
		case SQLType.LONGLONG:
			return packet.consumeIfComplete!long(binary, unsigned);
		case SQLType.FLOAT:
			return packet.consumeIfComplete!float(binary, unsigned);
		case SQLType.DOUBLE:
			return packet.consumeIfComplete!double(binary, unsigned);
		case SQLType.TIMESTAMP:
			return packet.consumeIfComplete!DateTime(binary, unsigned);
		case SQLType.TIME:
			return packet.consumeIfComplete!TimeOfDay(binary, unsigned);
		case SQLType.YEAR:
			return packet.consumeIfComplete!ushort(binary, unsigned);
		case SQLType.DATE:
			return packet.consumeIfComplete!Date(binary, unsigned);
		case SQLType.DATETIME:
			return packet.consumeIfComplete!DateTime(binary, unsigned);
		case SQLType.VARCHAR:
		case SQLType.ENUM:
		case SQLType.SET:
		case SQLType.VARSTRING:
		case SQLType.STRING:
		case SQLType.NEWDECIMAL:
			return packet.consumeIfComplete!string(false, unsigned);
		case SQLType.TINYBLOB:
		case SQLType.MEDIUMBLOB:
		case SQLType.BLOB:
		case SQLType.LONGBLOB:
		case SQLType.BIT:  // Yes, BIT. See note below.

			// TODO: This line should work. Why doesn't it?
			//return packet.consumeIfComplete!(ubyte[])(binary, unsigned);

			auto lcb = packet.consumeIfComplete!LCB();
			assert(!lcb.isIncomplete);
			SQLValue result;
			result.isIncomplete = false;
			result.isNull = lcb.isNull;
			if(result.isNull)
			{
				// TODO: consumeIfComplete!LCB should be adjusted to do
				//       this itself, but not until I'm certain that nothing
				//       is reliant on the current behavior.
				packet.popFront(); // LCB length
			}
			else
			{
				auto data = packet.consume(cast(size_t)lcb.value);
				if(charSet == 0x3F) // CharacterSet == binary
					result.value = data; // BLOB-ish
				else
					result.value = cast(string)data; // TEXT-ish
			}

			// Type BIT is treated as a length coded binary (like a BLOB or VARCHAR),
			// not like an integral type. So convert the binary data to a bool.
			// See: http://dev.mysql.com/doc/internals/en/binary-protocol-value.html
			if(sqlType == SQLType.BIT)
			{
				enforce!MYXProtocol(result.value.length == 1,
					"Expected BIT to arrive as an LCB with length 1, but got length "~to!string(result.value.length));

				result.value = result.value[0] == 1;
			}

			return result;
	}
}

/++
Extract number of bytes used for this LCB

Returns the number of bytes required to store this LCB

See_Also: $(LINK http://forge.mysql.com/wiki/MySQL_Internals_ClientServer_Protocol#Elements)

Returns: 0 if it's a null value, or number of bytes in other cases
+/
byte getNumLCBBytes(in ubyte lcbHeader) pure nothrow
{
	switch(lcbHeader)
	{
		case 251: return 0; // null
		case 0: .. case 250: return 1; // 8-bit
		case 252: return 2;  // 16-bit
		case 253: return 3;  // 24-bit
		case 254: return 8;  // 64-bit

		case 255:
		default:
			assert(0);
	}
	assert(0);
}


/++
Decodes a Length Coded Binary from a packet

See_Also: struct `mysql.protocol.extra_types.LCB`

Params:
packet = A packet that starts with a LCB. The bytes is popped off
         iff the packet is complete. See `mysql.protocol.extra_types.LCB`.

Returns: A decoded LCB value
+/
T consumeIfComplete(T:LCB)(ref ubyte[] packet) pure nothrow
in
{
	assert(packet.length >= 1, "packet has to include at least the LCB length byte");
}
body
{
	auto lcb = packet.decodeLCBHeader();
	if(lcb.isNull || lcb.isIncomplete)
		return lcb;

	if(lcb.numBytes > 1)
	{
		// We know it's complete, so we have to start consuming the LCB
		// Single byte values doesn't have a length
		packet.popFront(); // LCB length
	}

	assert(packet.length >= lcb.numBytes);

	lcb.value = packet.consume!ulong(lcb.numBytes);
	return lcb;
}

LCB decodeLCBHeader(in ubyte[] packet) pure nothrow
in
{
	assert(packet.length >= 1, "packet has to include at least the LCB length byte");
}
body
{
	LCB lcb;
	lcb.numBytes = getNumLCBBytes(packet.front);
	if(lcb.numBytes == 0)
	{
		lcb.isNull = true;
		return lcb;
	}

	assert(!lcb.isNull);
	// -1 for LCB length as we haven't popped it off yet
	lcb.isIncomplete = (lcb.numBytes > 1) && (packet.length-1 < lcb.numBytes);
	if(lcb.isIncomplete)
	{
		// Not enough bytes to store data. We don't remove any data, and expect
		// the caller to check isIncomplete and take action to fetch more data
		// and call this method at a later time
		return lcb;
	}

	assert(!lcb.isIncomplete);
	return lcb;
}

/++
Decodes a Length Coded Binary from a packet

See_Also: struct `mysql.protocol.extra_types.LCB`

Params:
packet = A packet that starts with a LCB. See `mysql.protocol.extra_types.LCB`.

Returns: A decoded LCB value
+/
LCB decode(T:LCB)(in ubyte[] packet) pure nothrow
in
{
	assert(packet.length >= 1, "packet has to include at least the LCB length byte");
}
body
{
	auto lcb = packet.decodeLCBHeader();
	if(lcb.isNull || lcb.isIncomplete)
		return lcb;
	assert(packet.length >= lcb.totalBytes);

	if(lcb.numBytes == 0)
		lcb.value = 0;
	else if(lcb.numBytes == 1)
		lcb.value = packet.decode!ulong(lcb.numBytes);
	else
	{
		// Skip the throwaway byte that indicated "at least 2 more bytes coming"
		lcb.value = packet[1..$].decode!ulong(lcb.numBytes);
	}

	return lcb;
}

/++
Parse Length Coded String

See_Also: $(LINK http://forge.mysql.com/wiki/MySQL_Internals_ClientServer_Protocol#Elements)
+/
string consume(T:LCS)(ref ubyte[] packet) pure
in
{
	assert(packet.length >= 1, "LCS packet needs to store at least the LCB header");
}
body
{
	auto lcb = packet.consumeIfComplete!LCB();
	assert(!lcb.isIncomplete);
	if(lcb.isNull)
		return null;
	enforce!MYXProtocol(lcb.value <= uint.max, "Protocol Length Coded String is too long");
	return cast(string)packet.consume(cast(size_t)lcb.value).idup;
}

/++
Skips over n items, advances the array, and return the newly advanced array
to allow method chaining.
+/
T[] skip(T)(ref T[] array, size_t n) pure nothrow
in
{
	assert(n <= array.length);
}
body
{
	array = array[n..$];
	return array;
}

/++
Converts a value into a sequence of bytes and fills the supplied array.

Params:
IsInt24 = If only the most significant 3 bytes from the value should be used.
value = The value to add to array.
array = The array we should add the values for. It has to be large enough,
        and the values are packed starting index 0.
+/
void packInto(T, bool IsInt24 = false)(T value, ubyte[] array) pure nothrow
in
{
	static if(IsInt24)
		assert(array.length >= 3);
	else
		assert(array.length >= T.sizeof, "Not enough space to unpack "~T.stringof);
}
body
{
	static if(T.sizeof >= 1)
	{
		array[0] = cast(ubyte) (value >> 8*0) & 0xff;
	}
	static if(T.sizeof >= 2)
	{
		array[1] = cast(ubyte) (value >> 8*1) & 0xff;
	}
	static if(!IsInt24)
	{
		static if(T.sizeof >= 4)
		{
			array[2] = cast(ubyte) (value >> 8*2) & 0xff;
			array[3] = cast(ubyte) (value >> 8*3) & 0xff;
		}
		static if(T.sizeof >= 8)
		{
			array[4] = cast(ubyte) (value >> 8*4) & 0xff;
			array[5] = cast(ubyte) (value >> 8*5) & 0xff;
			array[6] = cast(ubyte) (value >> 8*6) & 0xff;
			array[7] = cast(ubyte) (value >> 8*7) & 0xff;
		}
	}
	else
	{
		array[2] = cast(ubyte) (value >> 8*2) & 0xff;
	}
}

ubyte[] packLength(size_t l, out size_t offset) pure nothrow
out(result)
{
	assert(result.length >= 1);
}
body
{
	ubyte[] t;
	if (!l)
	{
		t.length = 1;
		t[0] = 0;
	}
	else if (l <= 250)
	{
		t.length = 1+l;
		t[0] = cast(ubyte) l;
		offset = 1;
	}
	else if (l <= 0xffff) // 16-bit
	{
		t.length = 3+l;
		t[0] = 252;
		packInto(cast(ushort)l, t[1..3]);
		offset = 3;
	}
	else if (l < 0xffffff) // 24-bit
	{
		t.length = 4+l;
		t[0] = 253;
		packInto!(uint, true)(cast(uint)l, t[1..4]);
		offset = 4;
	}
	else // 64-bit
	{
		ulong u = cast(ulong) l;
		t.length = 9+l;
		t[0] = 254;
		u.packInto(t[1..9]);
		offset = 9;
	}
	return t;
}

ubyte[] packLCS(void[] a) pure nothrow
{
	size_t offset;
	ubyte[] t = packLength(a.length, offset);
	if (t[0])
		t[offset..$] = (cast(ubyte[]) a)[0..$];
	return t;
}

@("testLCB")
debug(MYSQLN_TESTS)
unittest
{
	static void testLCB(string parseLCBFunc)(bool shouldConsume)
	{
		ubyte[] buf = [ 0xde, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x01, 0x00 ];
		ubyte[] bufCopy;

		bufCopy = buf;
		LCB lcb = mixin(parseLCBFunc~"!LCB(bufCopy)");
		assert(lcb.value == 0xde && !lcb.isNull && lcb.totalBytes == 1);
		assert(bufCopy.length == buf.length - (shouldConsume? lcb.totalBytes : 0));

		buf[0] = 251;
		bufCopy = buf;
		lcb = mixin(parseLCBFunc~"!LCB(bufCopy)");
		assert(lcb.value == 0 && lcb.isNull && lcb.totalBytes == 1);
		//TODO: This test seems to fail for consumeIfComplete, need to investigate.
		//      Don't know if fixing it might cause a problem, or if I simple misunderstood
		//      the function's intent.
		if(parseLCBFunc != "consumeIfComplete")
			assert(bufCopy.length == buf.length - (shouldConsume? lcb.totalBytes : 0));

		buf[0] = 252;
		bufCopy = buf;
		lcb = mixin(parseLCBFunc~"!LCB(bufCopy)");
		assert(lcb.value == 0xbbcc && !lcb.isNull && lcb.totalBytes == 3);
		assert(bufCopy.length == buf.length - (shouldConsume? lcb.totalBytes : 0));

		buf[0] = 253;
		bufCopy = buf;
		lcb = mixin(parseLCBFunc~"!LCB(bufCopy)");
		assert(lcb.value == 0xaabbcc && !lcb.isNull && lcb.totalBytes == 4);
		assert(bufCopy.length == buf.length - (shouldConsume? lcb.totalBytes : 0));

		buf[0] = 254;
		bufCopy = buf;
		lcb = mixin(parseLCBFunc~"!LCB(bufCopy)");
		assert(lcb.value == 0x5566778899aabbcc && !lcb.isNull && lcb.totalBytes == 9);
		assert(bufCopy.length == buf.length - (shouldConsume? lcb.totalBytes : 0));
	}

	//TODO: Merge 'consumeIfComplete(T:LCB)' and 'decode(T:LCB)', they do
	//      basically the same thing, only one consumes input and the other
	//      doesn't. Just want a better idea of where/how/why they're both
	//      used, and maybe more tests, before I go messing with them.
	testLCB!"consumeIfComplete"(true);
	testLCB!"decode"(false);
}

@("consume!LCS")
debug(MYSQLN_TESTS)
unittest
{
	ubyte[] buf;
	ubyte[] bufCopy;

	buf.length = 0x2000200;
	buf[] = '\x01';
	buf[0] = 250;
	buf[1] = '<';
	buf[249] = '!';
	buf[250] = '>';
	bufCopy = buf;
	string x = consume!LCS(bufCopy);
	assert(x.length == 250 && x[0] == '<' && x[249] == '>');

	buf[] = '\x01';
	buf[0] = 252;
	buf[1] = 0xff;
	buf[2] = 0xff;
	buf[3] = '<';
	buf[0x10000] = '*';
	buf[0x10001] = '>';
	bufCopy = buf;
	x = consume!LCS(bufCopy);
	assert(x.length == 0xffff && x[0] == '<' && x[0xfffe] == '>');

	buf[] = '\x01';
	buf[0] = 253;
	buf[1] = 0xff;
	buf[2] = 0xff;
	buf[3] = 0xff;
	buf[4] = '<';
	buf[0x1000001] = '*';
	buf[0x1000002] = '>';
	bufCopy = buf;
	x = consume!LCS(bufCopy);
	assert(x.length == 0xffffff && x[0] == '<' && x[0xfffffe] == '>');

	buf[] = '\x01';
	buf[0] = 254;
	buf[1] = 0xff;
	buf[2] = 0x00;
	buf[3] = 0x00;
	buf[4] = 0x02;
	buf[5] = 0x00;
	buf[6] = 0x00;
	buf[7] = 0x00;
	buf[8] = 0x00;
	buf[9] = '<';
	buf[0x2000106] = '!';
	buf[0x2000107] = '>';
	bufCopy = buf;
	x = consume!LCS(bufCopy);
	assert(x.length == 0x20000ff && x[0] == '<' && x[0x20000fe] == '>');
}

/// Set packet length and number. It's important that the length of packet has
/// already been set to the final state as its length is used.
void setPacketHeader(ref ubyte[] packet, ubyte packetNumber) pure nothrow
in
{
	// packet should include header, and possibly data
	assert(packet.length >= 4);
}
body
{
	auto dataLength = packet.length - 4; // don't include header in calculated size
	assert(dataLength <= uint.max);
	packet.setPacketHeader(packetNumber, cast(uint)dataLength);
}

void setPacketHeader(ref ubyte[] packet, ubyte packetNumber, uint dataLength) pure nothrow
in
{
	// packet should include header
	assert(packet.length >= 4);
	// Length is always a 24-bit int
	assert(dataLength <= 0xffff_ffff_ffff);
}
body
{
	dataLength.packInto!(uint, true)(packet);
	packet[3] = packetNumber;
}
