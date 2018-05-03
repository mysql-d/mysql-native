/// Internal - Tools for working with MySQL's communications packets.
module mysql.protocol.packets;

import std.exception;
import std.range;
import std.string;

import mysql.commands : ColumnSpecialization, CSN;
import mysql.exceptions;
import mysql.protocol.comms;
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.sockets;
public import mysql.protocol.packet_helpers;

void enforcePacketOK(string file = __FILE__, size_t line = __LINE__)(OKErrorPacket okp)
{
	enforce(!okp.error, new MYXReceived(okp, file, line));
}

/++
A struct representing an OK or Error packet.

OK packets begin with a zero byte - Error packets with 0xff

See_Also: $(LINK http://forge.mysql.com/wiki/MySQL_Internals_ClientServer_Protocol#Types_Of_Result_Packets)
+/
struct OKErrorPacket
{
	bool     error;
	ulong    affected;
	ulong    insertID;
	ushort   serverStatus;
	ushort   warnings;
	char[5]  sqlState;
	string   message;

	this(ubyte[] packet)
	{
		if (packet.front == ResultPacketMarker.error)
		{
			packet.popFront(); // skip marker/field code
			error = true;

			enforce!MYXProtocol(packet.length > 2, "Malformed Error packet - Missing error code");
			serverStatus = packet.consume!short(); // error code into server state
			if (packet.front == cast(ubyte) '#') //4.1+ error packet
			{
				packet.popFront(); // skip 4.1 marker
				enforce!MYXProtocol(packet.length > 5, "Malformed Error packet - Missing SQL state");
				sqlState[] = (cast(char[])packet[0 .. 5])[];
				packet = packet[5..$];
			}
		}
		else if(packet.front == ResultPacketMarker.ok)
		{
			packet.popFront(); // skip marker/field code

			enforce!MYXProtocol(packet.length > 1, "Malformed OK packet - Missing affected rows");
			auto lcb = packet.consumeIfComplete!LCB();
			assert(!lcb.isNull);
			assert(!lcb.isIncomplete);
			affected = lcb.value;

			enforce!MYXProtocol(packet.length > 1, "Malformed OK packet - Missing insert id");
			lcb = packet.consumeIfComplete!LCB();
			assert(!lcb.isNull);
			assert(!lcb.isIncomplete);
			insertID = lcb.value;

			enforce!MYXProtocol(packet.length > 2,
					format("Malformed OK packet - Missing server status. Expected length > 2, got %d", packet.length));
			serverStatus = packet.consume!short();

			enforce!MYXProtocol(packet.length >= 2, "Malformed OK packet - Missing warnings");
			warnings = packet.consume!short();
		}
		else
			throw new MYXProtocol("Malformed OK/Error packet - Incorrect type of packet", __FILE__, __LINE__);

		// both OK and Error packets end with a message for the rest of the packet
		message = cast(string)packet.idup;
	}
}

/++
A struct representing a field (column) description packet.

These packets, one for each column are sent before the data of a result set,
followed by an EOF packet.

See_Also: $(LINK http://forge.mysql.com/wiki/MySQL_Internals_ClientServer_Protocol#Field_Packet)
+/
struct FieldDescription
{
private:
	string   _db;
	string   _table;
	string   _originalTable;
	string   _name;
	string   _originalName;
	ushort   _charSet;
	uint     _length;
	SQLType  _type;
	FieldFlags _flags;
	ubyte    _scale;
	ulong    _deflt;
	uint     chunkSize;
	void delegate(const(ubyte)[], bool) chunkDelegate;

public:
	/++
	Construct a `FieldDescription` from the raw data packet
	
	Params:
	packet = The packet contents excluding the 4 byte packet header
	+/
	this(ubyte[] packet)
	in
	{
		assert(packet.length);
	}
	out
	{
		assert(!packet.length, "not all bytes read during FieldDescription construction");
	}
	body
	{
		packet.skip(4); // Skip catalog - it's always 'def'
		_db             = packet.consume!LCS();
		_table          = packet.consume!LCS();
		_originalTable  = packet.consume!LCS();
		_name           = packet.consume!LCS();
		_originalName   = packet.consume!LCS();

		enforce!MYXProtocol(packet.length >= 13, "Malformed field specification packet");
		packet.popFront(); // one byte filler here
		_charSet    = packet.consume!short();
		_length     = packet.consume!int();
		_type       = cast(SQLType)packet.consume!ubyte();
		_flags      = cast(FieldFlags)packet.consume!short();
		_scale      = packet.consume!ubyte();
		packet.skip(2); // two byte filler

		if(packet.length)
		{
			packet.skip(1); // one byte filler
			auto lcb = packet.consumeIfComplete!LCB();
			assert(!lcb.isNull);
			assert(!lcb.isIncomplete);
			_deflt = lcb.value;
		}
	}

	/// Database name for column as string
	@property string db() pure const nothrow { return _db; }

	/// Table name for column as string - this could be an alias as in 'from tablename as foo'
	@property string table() pure const nothrow { return _table; }

	/// Real table name for column as string
	@property string originalTable() pure const nothrow { return _originalTable; }

	/// Column name as string - this could be an alias
	@property string name() pure const nothrow { return _name; }

	/// Real column name as string
	@property string originalName() pure const nothrow { return _originalName; }

	/// The character set in force
	@property ushort charSet() pure const nothrow { return _charSet; }

	/// The 'length' of the column as defined at table creation
	@property uint length() pure const nothrow { return _length; }

	/// The type of the column hopefully (but not always) corresponding to enum `mysql.protocol.constants.SQLType`.
	/// Only the low byte currently used.
	@property SQLType type() pure const nothrow { return _type; }

	/// Column flags - unsigned, binary, null and so on
	@property FieldFlags flags() pure const nothrow { return _flags; }

	/// Precision for floating point values
	@property ubyte scale() pure const nothrow { return _scale; }

	/// NotNull from flags
	@property bool notNull() pure const nothrow { return (_flags & FieldFlags.NOT_NULL) != 0; }

	/// Unsigned from flags
	@property bool unsigned() pure const nothrow { return (_flags & FieldFlags.UNSIGNED) != 0; }

	/// Binary from flags
	@property bool binary() pure const nothrow { return (_flags & FieldFlags.BINARY) != 0; }

	/// Is-enum from flags
	@property bool isenum() pure const nothrow { return (_flags & FieldFlags.ENUM) != 0; }

	/// Is-set (a SET column that is) from flags
	@property bool isset() pure const nothrow { return (_flags & FieldFlags.SET) != 0; }

	void show() const
	{
		import std.stdio;

		writefln("%s %d %x %016b", _name, _length, _type, _flags);
	}
}

/++
A struct representing a prepared statement parameter description packet.

These packets, one for each parameter are sent in response to the prepare
command, followed by an EOF packet.

Sadly it seems that this facility is only a stub. The correct number of
packets is sent, but they contain no useful information and are all the same.
+/
struct ParamDescription
{
private:
	ushort _type;
	FieldFlags _flags;
	ubyte _scale;
	uint _length;

public:
	this(ubyte[] packet)
	{
		_type   = packet.consume!short();
		_flags  = cast(FieldFlags)packet.consume!short();
		_scale  = packet.consume!ubyte();
		_length = packet.consume!int();
		assert(!packet.length);
	}
	@property uint length() pure const nothrow { return _length; }
	@property ushort type() pure const nothrow { return _type; }
	@property FieldFlags flags() pure const nothrow { return _flags; }
	@property ubyte scale() pure const nothrow { return _scale; }
	@property bool notNull() pure const nothrow { return (_flags & FieldFlags.NOT_NULL) != 0; }
	@property bool unsigned() pure const nothrow { return (_flags & FieldFlags.UNSIGNED) != 0; }
}

bool isEOFPacket(in ubyte[] packet) pure nothrow
in
{
	assert(!packet.empty);
}
body
{
	return packet.front == ResultPacketMarker.eof && packet.length < 9;
}

/++
A struct representing an EOF packet from the server.

An EOF packet is sent from the server after each sequence of field
description and parameter description packets, and after a sequence of
result set row packets.
An EOF packet is also called "Last Data Packet" or "End Packet".

These EOF packets contain a server status and a warning count.

See_Also: $(LINK http://forge.mysql.com/wiki/MySQL_Internals_ClientServer_Protocol#EOF_Packet)
+/
struct EOFPacket
{
private:
	ushort _warnings;
	ushort _serverStatus;

public:

	/++
	Construct an `EOFPacket` struct from the raw data packet
	
	Params:
	packet = The packet contents excluding the 4 byte packet header
	+/
	this(ubyte[] packet)
	in
	{
		assert(packet.isEOFPacket());
		assert(packet.length == 5);
	}
	out
	{
		assert(!packet.length);
	}
	body
	{
		packet.popFront(); // eof marker
		_warnings = packet.consume!short();
		_serverStatus = packet.consume!short();
	}

	/// Retrieve the warning count
	@property ushort warnings() pure const nothrow { return _warnings; }

	/// Retrieve the server status
	@property ushort serverStatus() pure const nothrow { return _serverStatus; }
}


/++
A struct representing the collation of a sequence of `FieldDescription` packets.

This data gets filled in after a query (prepared or otherwise) that creates
a result set completes. All the FD packets, and an EOF packet must be eaten
before the row data packets can be read.
+/
struct ResultSetHeaders
{
	import mysql.connection;

private:
	FieldDescription[] _fieldDescriptions;
	string[] _fieldNames;
	ushort _warnings;

public:

	/++
	Construct a `ResultSetHeaders` struct from a sequence of `FieldDescription`
	packets and an EOF packet.
	
	Params:
		con = A `mysql.connection.Connection` via which the packets are read
		fieldCount = the number of fields/columns generated by the query
	+/
	this(Connection con, uint fieldCount)
	{
		scope(failure) con.kill();

		_fieldNames.length = _fieldDescriptions.length = fieldCount;
		foreach (size_t i; 0 .. fieldCount)
		{
			auto packet = con.getPacket();
			enforce!MYXProtocol(!packet.isEOFPacket(),
					"Expected field description packet, got EOF packet in result header sequence");

			_fieldDescriptions[i]   = FieldDescription(packet);
			_fieldNames[i]          = _fieldDescriptions[i]._name;
		}
		auto packet = con.getPacket();
		enforce!MYXProtocol(packet.isEOFPacket(),
				"Expected EOF packet in result header sequence");
		auto eof = EOFPacket(packet);
		con._serverStatus = eof._serverStatus;
		_warnings = eof._warnings;
	}

	/++
	Add specialization information to one or more field descriptions.
	
	Currently, no specializations are implemented yet.

	Params:
		csa = An array of ColumnSpecialization structs
	+/
	/+
	Future text:
	Currently the only specialization supported is the capability to deal with long data
	e.g. BLOB or TEXT data in chunks by stipulating a chunkSize and a delegate to sink
	the data.
	+/
	void addSpecializations(ColumnSpecialization[] csa)
	{
		foreach(CSN csn; csa)
		{
			enforce!MYX(csn.cIndex < fieldCount && _fieldDescriptions[csn.cIndex].type == csn.type,
					"Column specialization index or type does not match the corresponding column.");
			_fieldDescriptions[csn.cIndex].chunkSize = csn.chunkSize;
			_fieldDescriptions[csn.cIndex].chunkDelegate = csn.chunkDelegate;
		}
	}

	/// Index into the set of field descriptions
	FieldDescription opIndex(size_t i) pure nothrow { return _fieldDescriptions[i]; }
	/// Get the number of fields in a result row.
	@property size_t fieldCount() pure const nothrow { return _fieldDescriptions.length; }
	/// Get the warning count as per the EOF packet
	@property ushort warnings() pure const nothrow { return _warnings; }
	/// Get an array of strings representing the column names
	@property string[] fieldNames() pure nothrow { return _fieldNames; }
	/// Get an array of the field descriptions
	@property FieldDescription[] fieldDescriptions() pure nothrow { return _fieldDescriptions; }

	void show() const
	{
		foreach (FieldDescription fd; _fieldDescriptions)
			fd.show();
	}
}

/++
A struct representing the collation of a prepared statement parameter description sequence.

As noted in `ParamDescription` description, parameter descriptions are not fully implemented by MySQL.
+/
struct PreparedStmtHeaders
{
	import mysql.connection;
	
package:
	Connection _con;
	ushort _colCount, _paramCount;
	FieldDescription[] _colDescriptions;
	ParamDescription[] _paramDescriptions;
	ushort _warnings;

	bool getEOFPacket()
	{
		auto packet = _con.getPacket();
		if (!packet.isEOFPacket())
			return false;
		EOFPacket eof = EOFPacket(packet);
		_con._serverStatus = eof._serverStatus;
		_warnings += eof._warnings;
		return true;
	}

public:
	this(Connection con, ushort cols, ushort params)
	{
		scope(failure) con.kill();

		_con = con;
		_colCount = cols;
		_paramCount = params;
		_colDescriptions.length = cols;
		_paramDescriptions.length = params;

		// The order in which fields are sent is params first, followed by EOF,
		// then cols followed by EOF The parameter specs are useless - they are
		// all the same. This observation is coroborated by the fact that the
		// C API does not have any information about parameter types either.
		// WireShark gives up on these records also.
		foreach (size_t i; 0.._paramCount)
			_con.getPacket();  // just eat them - they are not useful

		if (_paramCount)
			enforce!MYXProtocol(getEOFPacket(), "Expected EOF packet in result header sequence");

		foreach(size_t i; 0.._colCount)
		   _colDescriptions[i] = FieldDescription(_con.getPacket());

		if (_colCount)
			enforce!MYXProtocol(getEOFPacket(), "Expected EOF packet in result header sequence");
	}

	ParamDescription param(size_t i) pure const nothrow { return _paramDescriptions[i]; }
	FieldDescription col(size_t i) pure const nothrow { return _colDescriptions[i]; }

	@property ParamDescription[] paramDescriptions() pure nothrow { return _paramDescriptions; }
	@property FieldDescription[] fieldDescriptions() pure nothrow { return _colDescriptions; }

	@property paramCount() pure const nothrow { return _paramCount; }
	@property ushort warnings() pure const nothrow { return _warnings; }

	void showCols() const
	{
		import std.stdio;

		writefln("%d columns", _colCount);
		foreach (FieldDescription fd; _colDescriptions)
		{
			writefln("%10s %10s %10s %10s %10s %d %d %02x %016b %d",
					fd._db, fd._table, fd._originalTable, fd._name, fd._originalName,
					fd._charSet, fd._length, fd._type, fd._flags, fd._scale);
		}
	}
}
