/// Internal - Protocol-related data types.
module mysql.protocol.extra_types;

import std.exception;
import std.variant;

import mysql.commands;
import mysql.exceptions;
import mysql.protocol.sockets;
import mysql.result;

struct SQLValue
{
	bool isNull;
	bool isIncomplete;
	Variant _value;

	// empty template as a template and non-template won't be added to the same overload set
	@property inout(Variant) value()() inout
	{
		enforce!MYX(!isNull, "SQL value is null");
		enforce!MYX(!isIncomplete, "SQL value not complete");
		return _value;
	}

	@property void value(T)(T value)
	{
		enforce!MYX(!isNull, "SQL value is null");
		enforce!MYX(!isIncomplete, "SQL value not complete");
		_value = value;
	}

	pure const nothrow invariant()
	{
		isNull && assert(!isIncomplete);
		isIncomplete && assert(!isNull);
	}
}


/// Length Coded Binary Value
struct LCB
{
	/// True if the `LCB` contains a null value
	bool isNull;

	/// True if the packet that created this `LCB` didn't have enough bytes
	/// to store a value of the size specified. More bytes have to be fetched from the server.
	bool isIncomplete;

	/// Number of bytes needed to store the value (Extracted from the LCB header. The header byte is not included)
	ubyte numBytes;

	/// Number of bytes total used for this `LCB`
	@property ubyte totalBytes() pure const nothrow
	{
		return cast(ubyte)(numBytes <= 1 ? 1 : numBytes+1);
	}

	/// The decoded value. This is always 0 if `isNull` or `isIncomplete` is set.
	ulong value;

	pure const nothrow invariant()
	{
		if(isIncomplete)
		{
			assert(!isNull);
			assert(value == 0);
			assert(numBytes > 0);
		}
		else if(isNull)
		{
			assert(!isIncomplete);
			assert(value == 0);
			assert(numBytes == 0);
		}
		else
		{
			assert(!isNull);
			assert(!isIncomplete);
			assert(numBytes > 0);
		}
	}
}

/// Length Coded String
///
/// Dummy struct just to tell what value we are using.
/// We don't need to store anything here as the result is always a string.
struct LCS
{
	// Nothing
}
