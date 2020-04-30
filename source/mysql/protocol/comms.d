/++
Internal - Low-level communications.

Consider this module the main entry point for the low-level MySQL/MariaDB
protocol code. The other modules in `mysql.protocol` are mainly tools
to support this module.

Previously, the code handling low-level protocol details was scattered all
across the library. Such functionality has been factored out into this module,
to be kept in one place for better encapsulation and to facilitate further
cleanup and refactoring.

EXPECT MAJOR CHANGES to this entire `mysql.protocol` sub-package until it
eventually settles into what will eventually become a low-level library
containing the bulk of the MySQL/MariaDB-specific code. Hang on tight...

Next tasks for this sub-package's cleanup:
- Reduce this module's reliance on Connection.
- Abstract out a PacketStream to clean up getPacket and related functionality.
+/
module mysql.protocol.comms;

import std.algorithm;
import std.conv;
import std.digest.sha;
import std.exception;
import std.range;

import mysql.connection;
import mysql.exceptions;
import mysql.safe.prepared;
import mysql.result;
import mysql.types;

import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packet_helpers;
import mysql.protocol.packets;
import mysql.protocol.sockets;

import taggedalgebraic.taggedalgebraic;

// Trick tagged algebraic into getting the value based on the kind enum. Much
// easier than dealing with types when I already have the kind.
auto kget(alias K, U)(auto ref TaggedAlgebraic!U ta) if (is(typeof(K) == TaggedAlgebraic!U.Kind))
{
	import taggedalgebraic.taggedunion;
	return (cast(TaggedUnion!U)ta).value!K;
}

@safe:

/// Low-level comms code relating to prepared statements.
package struct ProtocolPrepared
{
	@safe:
	import std.conv;
	import std.datetime;
	import mysql.types;

	static ubyte[] makeBitmap(in MySQLVal[] inParams)
	{
		size_t bml = (inParams.length+7)/8;
		ubyte[] bma;
		bma.length = bml;
		foreach (i; 0..inParams.length)
		{
			if(inParams[i].kind != MySQLVal.Kind.Null)
				continue;
			size_t bn = i/8;
			size_t bb = i%8;
			ubyte sr = 1;
			sr <<= bb;
			bma[bn] |= sr;
		}
		return bma;
	}

	static ubyte[] makePSPrefix(uint hStmt, ubyte flags = 0) pure nothrow
	{
		ubyte[] prefix;
		prefix.length = 14;

		prefix[4] = CommandType.STMT_EXECUTE;
		hStmt.packInto(prefix[5..9]);
		prefix[9] = flags;   // flags, no cursor
		prefix[10] = 1; // iteration count - currently always 1
		prefix[11] = 0;
		prefix[12] = 0;
		prefix[13] = 0;

		return prefix;
	}

	static ubyte[] analyseParams(MySQLVal[] inParams, ParameterSpecialization[] psa,
		out ubyte[] vals, out bool longData)
	{
		size_t pc = inParams.length;
		ubyte[] types;
		types.length = pc*2;
		size_t alloc = pc*20;
		vals.length = alloc;
		uint vcl = 0, len;
		int ct = 0;

		void reAlloc(size_t n)
		{
			if (vcl+n < alloc)
				return;
			size_t inc = (alloc*3)/2;
			if (inc <  n)
				inc = n;
			alloc += inc;
			vals.length = alloc;
		}

		foreach (size_t i; 0..pc)
		{
			enum UNSIGNED  = 0x80;
			enum SIGNED    = 0;
			if (psa[i].chunkSize)
				longData= true;
			if (inParams[i].kind == MySQLVal.Kind.Null)
			{
				types[ct++] = SQLType.NULL;
				types[ct++] = SIGNED;
				continue;
			}
			MySQLVal v = inParams[i];
			SQLType ext = psa[i].type;
			auto ts = v.kind;
			bool isRef = false;

			// TODO: use v.visit instead for more efficiency and shorter code.
			with(MySQLVal.Kind) final switch (ts)
			{
				case BitRef:
					isRef = true; goto case;
				case Bit:
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.BIT;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					reAlloc(2);
					bool bv = isRef? *v.kget!BitRef : v.kget!Bit;
					vals[vcl++] = 1;
					vals[vcl++] = bv? 0x31: 0x30;
					break;
				case ByteRef:
					isRef = true; goto case;
				case Byte:
					types[ct++] = SQLType.TINY;
					types[ct++] = SIGNED;
					reAlloc(1);
					vals[vcl++] = isRef? *v.kget!ByteRef : v.kget!Byte;
					break;
				case UByteRef:
					isRef = true; goto case;
				case UByte:
					types[ct++] = SQLType.TINY;
					types[ct++] = UNSIGNED;
					reAlloc(1);
					vals[vcl++] = isRef? *v.kget!UByteRef : v.kget!UByte;
					break;
				case ShortRef:
					isRef = true; goto case;
				case Short:
					types[ct++] = SQLType.SHORT;
					types[ct++] = SIGNED;
					reAlloc(2);
					short si = isRef? *v.kget!ShortRef : v.kget!Short;
					vals[vcl++] = cast(ubyte) (si & 0xff);
					vals[vcl++] = cast(ubyte) ((si >> 8) & 0xff);
					break;
				case UShortRef:
					isRef = true; goto case;
				case UShort:
					types[ct++] = SQLType.SHORT;
					types[ct++] = UNSIGNED;
					reAlloc(2);
					ushort us = isRef? *v.kget!UShortRef : v.kget!UShort;
					vals[vcl++] = cast(ubyte) (us & 0xff);
					vals[vcl++] = cast(ubyte) ((us >> 8) & 0xff);
					break;
				case IntRef:
					isRef = true; goto case;
				case Int:
					types[ct++] = SQLType.INT;
					types[ct++] = SIGNED;
					reAlloc(4);
					int ii = isRef? *v.kget!IntRef : v.kget!Int;
					vals[vcl++] = cast(ubyte) (ii & 0xff);
					vals[vcl++] = cast(ubyte) ((ii >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((ii >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((ii >> 24) & 0xff);
					break;
				case UIntRef:
					isRef = true; goto case;
				case UInt:
					types[ct++] = SQLType.INT;
					types[ct++] = UNSIGNED;
					reAlloc(4);
					uint ui = isRef? *v.kget!UIntRef : v.kget!UInt;
					vals[vcl++] = cast(ubyte) (ui & 0xff);
					vals[vcl++] = cast(ubyte) ((ui >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((ui >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((ui >> 24) & 0xff);
					break;
				case LongRef:
					isRef = true; goto case;
				case Long:
					types[ct++] = SQLType.LONGLONG;
					types[ct++] = SIGNED;
					reAlloc(8);
					long li = isRef? *v.kget!LongRef : v.kget!Long;
					vals[vcl++] = cast(ubyte) (li & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 24) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 32) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 40) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 48) & 0xff);
					vals[vcl++] = cast(ubyte) ((li >> 56) & 0xff);
					break;
				case ULongRef:
					isRef = true; goto case;
				case ULong:
					types[ct++] = SQLType.LONGLONG;
					types[ct++] = UNSIGNED;
					reAlloc(8);
					ulong ul = isRef? *v.kget!ULongRef : v.kget!ULong;
					vals[vcl++] = cast(ubyte) (ul & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 8) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 16) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 24) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 32) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 40) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 48) & 0xff);
					vals[vcl++] = cast(ubyte) ((ul >> 56) & 0xff);
					break;
				case FloatRef:
					isRef = true; goto case;
				case Float:
					types[ct++] = SQLType.FLOAT;
					types[ct++] = SIGNED;
					reAlloc(4);
					float[1] f = [isRef? *v.kget!FloatRef : v.kget!Float];
					ubyte[] uba = cast(ubyte[]) f[];
					vals[vcl .. vcl + uba.length] = uba[];
					vcl += uba.length;
					break;
				case DoubleRef:
					isRef = true; goto case;
				case Double:
					types[ct++] = SQLType.DOUBLE;
					types[ct++] = SIGNED;
					reAlloc(8);
					double[1] d = [isRef? *v.kget!DoubleRef : v.kget!Double];
					ubyte[] uba = cast(ubyte[]) d[];
					vals[vcl .. uba.length] = uba[];
					vcl += uba.length;
					break;
				case DateRef:
					isRef = true; goto case;
				case Date:
					types[ct++] = SQLType.DATE;
					types[ct++] = SIGNED;
					auto date = isRef? *v.kget!DateRef : v.kget!Date;
					ubyte[] da = pack(date);
					size_t l = da.length;
					reAlloc(l);
					vals[vcl..vcl+l] = da[];
					vcl += l;
					break;
				case TimeRef:
					isRef = true; goto case;
				case Time:
					types[ct++] = SQLType.TIME;
					types[ct++] = SIGNED;
					auto time = isRef? *v.kget!TimeRef : v.kget!Time;
					ubyte[] ta = pack(time);
					size_t l = ta.length;
					reAlloc(l);
					vals[vcl..vcl+l] = ta[];
					vcl += l;
					break;
				case DateTimeRef:
					isRef = true; goto case;
				case DateTime:
					types[ct++] = SQLType.DATETIME;
					types[ct++] = SIGNED;
					auto dt = isRef? *v.kget!DateTimeRef : v.kget!DateTime;
					ubyte[] da = pack(dt);
					size_t l = da.length;
					reAlloc(l);
					vals[vcl..vcl+l] = da[];
					vcl += l;
					break;
				case TimestampRef:
					isRef = true; goto case;
				case Timestamp:
					types[ct++] = SQLType.TIMESTAMP;
					types[ct++] = SIGNED;
					auto tms = isRef? *v.kget!TimestampRef : v.kget!Timestamp;
					auto dt = mysql.protocol.packet_helpers.toDateTime(tms.rep);
					ubyte[] da = pack(dt);
					size_t l = da.length;
					reAlloc(l);
					vals[vcl..vcl+l] = da[];
					vcl += l;
					break;
				case TextRef:
					isRef = true; goto case;
				case Text:
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.VARCHAR;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					const char[] ca = isRef? *v.kget!TextRef : v.kget!Text;
					ubyte[] packed = packLCS(ca);
					reAlloc(packed.length);
					vals[vcl..vcl+packed.length] = packed[];
					vcl += packed.length;
					break;
				case CTextRef:
					isRef = true; goto case;
				case CText:
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.VARCHAR;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					const char[] ca = isRef? *v.kget!CTextRef : v.kget!CText;
					ubyte[] packed = packLCS(ca);
					reAlloc(packed.length);
					vals[vcl..vcl+packed.length] = packed[];
					vcl += packed.length;
					break;
				case BlobRef:
					isRef = true; goto case;
				case Blob:
				case CBlob:
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.TINYBLOB;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					const ubyte[] uba = isRef? *v.kget!BlobRef : (ts == Blob ? v.kget!Blob : v.kget!CBlob);
					ubyte[] packed = packLCS(uba);
					reAlloc(packed.length);
					vals[vcl..vcl+packed.length] = packed[];
					vcl += packed.length;
					break;
				case Null:
					throw new MYX("Unbound parameter " ~ to!string(i), __FILE__, __LINE__);
			}
		}
		vals.length = vcl;
		return types;
	}

	static void sendLongData(MySQLSocket socket, uint hStmt, ParameterSpecialization[] psa)
	{
		assert(psa.length <= ushort.max); // parameter number is sent as short
		foreach (size_t i, PSN psn; psa)
		{
			if (!psn.chunkSize) continue;
			uint cs = psn.chunkSize;
			uint delegate(ubyte[]) @safe dg = psn.chunkDelegate;

			ubyte[] chunk;
			chunk.length = cs+11;
			chunk.setPacketHeader(0 /*each chunk is separate cmd*/);
			chunk[4] = CommandType.STMT_SEND_LONG_DATA;
			hStmt.packInto(chunk[5..9]); // statement handle
			packInto(cast(ushort)i, chunk[9..11]); // parameter number

			// byte 11 on is payload
			for (;;)
			{
				uint sent = dg(chunk[11..cs+11]);
				if (sent < cs)
				{
					if (sent == 0)    // data was exact multiple of chunk size - all sent
						break;
					chunk.length = chunk.length - (cs-sent);     // trim the chunk
					sent += 7;        // adjust for non-payload bytes
					packInto!(uint, true)(cast(uint)sent, chunk[0..3]);
					socket.send(chunk);
					break;
				}
				socket.send(chunk);
			}
		}
	}

	static void sendCommand(Connection conn, uint hStmt, PreparedStmtHeaders psh,
		MySQLVal[] inParams, ParameterSpecialization[] psa)
	{
		conn.autoPurge();

		ubyte[] packet;
		conn.resetPacket();

		ubyte[] prefix = makePSPrefix(hStmt, 0);
		size_t len = prefix.length;
		bool longData;

		if (psh.paramCount)
		{
			ubyte[] one = [ 1 ];
			ubyte[] vals;
			ubyte[] types = analyseParams(inParams, psa, vals, longData);
			ubyte[] nbm = makeBitmap(inParams);
			packet = prefix ~ nbm ~ one ~ types ~ vals;
		}
		else
			packet = prefix;

		if (longData)
			sendLongData(conn._socket, hStmt, psa);

		assert(packet.length <= uint.max);
		packet.setPacketHeader(conn.pktNumber);
		conn.bumpPacket();
		conn._socket.send(packet);
	}
}

package(mysql) struct ExecQueryImplInfo
{
	bool isPrepared;

	// For non-prepared statements:
	const(char[]) sql;

	// For prepared statements:
	uint hStmt;
	PreparedStmtHeaders psh;
	MySQLVal[] inParams;
	ParameterSpecialization[] psa;
}

/++
Internal implementation for the exec and query functions.

Execute a one-off SQL command.

Any result set can be accessed via Connection.getNextRow(), but you should really be
using the query function for such queries.

Params: ra = An out parameter to receive the number of rows affected.
Returns: true if there was a (possibly empty) result set.
+/
package(mysql) bool execQueryImpl(Connection conn, ExecQueryImplInfo info, out ulong ra)
{
	scope(failure) conn.kill();

	// Send data
	if(info.isPrepared)
		ProtocolPrepared.sendCommand(conn, info.hStmt, info.psh, info.inParams, info.psa);
	else
	{
		conn.sendCmd(CommandType.QUERY, info.sql);
		conn._fieldCount = 0;
	}

	// Handle response
	ubyte[] packet = conn.getPacket();
	bool rv;
	if (packet.front == ResultPacketMarker.ok || packet.front == ResultPacketMarker.error)
	{
		conn.resetPacket();
		auto okp = OKErrorPacket(packet);
		enforcePacketOK(okp);
		ra = okp.affected;
		conn._serverStatus = okp.serverStatus;
		conn._insertID = okp.insertID;
		rv = false;
	}
	else
	{
		// There was presumably a result set
		assert(packet.front >= 1 && packet.front <= 250); // Result set packet header should have this value
		conn._headersPending = conn._rowsPending = true;
		conn._binaryPending = info.isPrepared;
		auto lcb = packet.consumeIfComplete!LCB();
		assert(!lcb.isNull);
		assert(!lcb.isIncomplete);
		conn._fieldCount = cast(ushort)lcb.value;
		assert(conn._fieldCount == lcb.value);
		rv = true;
		ra = 0;
	}
	return rv;
}

///ditto
package(mysql) bool execQueryImpl(Connection conn, ExecQueryImplInfo info)
{
	ulong rowsAffected;
	return execQueryImpl(conn, info, rowsAffected);
}

package(mysql) void immediateReleasePrepared(Connection conn, uint statementId)
{
	scope(failure) conn.kill();

	if(conn.closed())
		return;

	ubyte[9] packet_buf;
	ubyte[] packet = packet_buf;
	packet.setPacketHeader(0/*packet number*/);
	conn.bumpPacket();
	packet[4] = CommandType.STMT_CLOSE;
	statementId.packInto(packet[5..9]);
	conn.purgeResult();
	conn._socket.send(packet);
	// It seems that the server does not find it necessary to send a response
	// for this command.
}

// Moved here from `struct Row`
package(mysql) bool[] consumeNullBitmap(ref ubyte[] packet, uint fieldCount) pure
{
	uint bitmapLength = calcBitmapLength(fieldCount);
	enforce!MYXProtocol(packet.length >= bitmapLength, "Packet too small to hold null bitmap for all fields");
	auto bitmap = packet.consume(bitmapLength);
	return decodeNullBitmap(bitmap, fieldCount);
}

// Moved here from `struct Row`
private static uint calcBitmapLength(uint fieldCount) pure nothrow
{
	return (fieldCount+7+2)/8;
}

// Moved here from `struct Row`
// This is to decode the bitmap in a binary result row. First two bits are skipped
private bool[] decodeNullBitmap(ubyte[] bitmap, uint numFields) pure nothrow
in
{
	assert(bitmap.length >= calcBitmapLength(numFields),
		"bitmap not large enough to store all null fields");
}
out(result)
{
	assert(result.length == numFields);
}
body
{
	bool[] nulls;
	nulls.length = numFields;

	// the current byte we are processing for nulls
	ubyte bits = bitmap.front();
	// strip away the first two bits as they are reserved
	bits >>= 2;
	// .. and then we only have 6 bits left to process for this byte
	ubyte bitsLeftInByte = 6;
	foreach(ref isNull; nulls)
	{
		assert(bitsLeftInByte <= 8);
		// processed all bits? fetch new byte
		if (bitsLeftInByte == 0)
		{
			assert(bits == 0, "not all bits are processed!");
			assert(!bitmap.empty, "bits array too short for number of columns");
			bitmap.popFront();
			bits = bitmap.front;
			bitsLeftInByte = 8;
		}
		assert(bitsLeftInByte > 0);
		isNull = (bits & 0b0000_0001) != 0;

		// get ready to process next bit
		bits >>= 1;
		--bitsLeftInByte;
	}
	return nulls;
}

// Moved here from `struct Row.this`
package(mysql) void ctorRow(Connection conn, ref ubyte[] packet, ResultSetHeaders rh, bool binary,
	out MySQLVal[] _values, out bool[] _nulls, out string[] _names)
in
{
	assert(rh.fieldCount <= uint.max);
}
body
{
	scope(failure) conn.kill();

	uint fieldCount = cast(uint)rh.fieldCount;
	_values.length = _nulls.length = _names.length = fieldCount;

	if(binary)
	{
		// There's a null byte header on a binary result sequence, followed by some bytes of bitmap
		// indicating which columns are null
		enforce!MYXProtocol(packet.front == 0, "Expected null header byte for binary result row");
		packet.popFront();
		_nulls = consumeNullBitmap(packet, fieldCount);
	}

	foreach(size_t i; 0..fieldCount)
	{
		if(binary && _nulls[i])
		{
			_values[i] = null;
			continue;
		}

		SQLValue sqlValue;
		do
		{
			FieldDescription fd = rh[i];
			_names[i] = fd.name;
			sqlValue = packet.consumeIfComplete(fd.type, binary, fd.unsigned, fd.charSet);
			// TODO: Support chunk delegate
			if(sqlValue.isIncomplete)
				packet ~= conn.getPacket();
		} while(sqlValue.isIncomplete);
		assert(!sqlValue.isIncomplete);

		if(sqlValue.isNull)
		{
			assert(!binary);
			assert(!_nulls[i]);
			_nulls[i] = true;
			_values[i] = null;
		}
		else
		{
			_values[i] = sqlValue.value;
		}
	}
}

////// Moved here from Connection /////////////////////////////////

package(mysql) ubyte[] getPacket(Connection conn)
{
	scope(failure) conn.kill();

	ubyte[4] header;
	conn._socket.read(header);
	// number of bytes always set as 24-bit
	uint numDataBytes = (header[2] << 16) + (header[1] << 8) + header[0];
	enforce!MYXProtocol(header[3] == conn.pktNumber, "Server packet out of order");
	conn.bumpPacket();

	ubyte[] packet = new ubyte[numDataBytes];
	conn._socket.read(packet);
	assert(packet.length == numDataBytes, "Wrong number of bytes read");
	return packet;
}

package(mysql) void send(MySQLSocket _socket, const(ubyte)[] packet)
in
{
	assert(packet.length > 4); // at least 1 byte more than header
}
body
{
	_socket.write(packet);
}

package(mysql) void send(MySQLSocket _socket, const(ubyte)[] header, const(ubyte)[] data)
in
{
	assert(header.length == 4 || header.length == 5/*command type included*/);
}
body
{
	_socket.write(header);
	if(data.length)
		_socket.write(data);
}

package(mysql) void sendCmd(T)(Connection conn, CommandType cmd, const(T)[] data)
in
{
	// Internal thread states. Clients shouldn't use this
	assert(cmd != CommandType.SLEEP);
	assert(cmd != CommandType.CONNECT);
	assert(cmd != CommandType.TIME);
	assert(cmd != CommandType.DELAYED_INSERT);
	assert(cmd != CommandType.CONNECT_OUT);

	// Deprecated
	assert(cmd != CommandType.CREATE_DB);
	assert(cmd != CommandType.DROP_DB);
	assert(cmd != CommandType.TABLE_DUMP);

	// cannot send more than uint.max bytes. TODO: better error message if we try?
	assert(data.length <= uint.max);
}
out
{
	// at this point we should have sent a command
	assert(conn.pktNumber == 1);
}
body
{
	scope(failure) conn.kill();

	conn._lastCommandID++;

	if(!conn._socket.connected)
	{
		if(cmd == CommandType.QUIT)
			return; // Don't bother reopening connection just to quit

		conn._open = Connection.OpenState.notConnected;
		conn.connect(conn._clientCapabilities);
	}

	conn.autoPurge();

	conn.resetPacket();

	ubyte[] header;
	header.length = 4 /*header*/ + 1 /*cmd*/;
	header.setPacketHeader(conn.pktNumber, cast(uint)data.length +1/*cmd byte*/);
	header[4] = cmd;
	conn.bumpPacket();

	conn._socket.send(header, cast(const(ubyte)[])data);
}

package(mysql) OKErrorPacket getCmdResponse(Connection conn, bool asString = false)
{
	auto okp = OKErrorPacket(conn.getPacket());
	enforcePacketOK(okp);
	conn._serverStatus = okp.serverStatus;
	return okp;
}

package(mysql) ubyte[] buildAuthPacket(Connection conn, ubyte[] token)
in
{
	assert(token.length == 20);
}
body
{
	ubyte[] packet;
	packet.reserve(4/*header*/ + 4 + 4 + 1 + 23 + conn._user.length+1 + token.length+1 + conn._db.length+1);
	packet.length = 4 + 4 + 4; // create room for the beginning headers that we set rather than append

	// NOTE: we'll set the header last when we know the size

	// Set the default capabilities required by the client
	conn._cCaps.packInto(packet[4..8]);

	// Request a conventional maximum packet length.
	1.packInto(packet[8..12]);

	packet ~= 33; // Set UTF-8 as default charSet

	// There's a statutory block of zero bytes here - fill them in.
	foreach(i; 0 .. 23)
		packet ~= 0;

	// Add the user name as a null terminated string
	foreach(i; 0 .. conn._user.length)
		packet ~= conn._user[i];
	packet ~= 0; // \0

	// Add our calculated authentication token as a length prefixed string.
	assert(token.length <= ubyte.max);
	if(conn._pwd.length == 0)  // Omit the token if the account has no password
		packet ~= 0;
	else
	{
		packet ~= cast(ubyte)token.length;
		foreach(i; 0 .. token.length)
			packet ~= token[i];
	}

	// Add the default database as a null terminated string
	foreach(i; 0 .. conn._db.length)
		packet ~= conn._db[i];
	packet ~= 0; // \0

	// The server sent us a greeting with packet number 0, so we send the auth packet
	// back with the next number.
	packet.setPacketHeader(conn.pktNumber);
	conn.bumpPacket();
	return packet;
}

package(mysql) ubyte[] makeToken(string password, ubyte[] authBuf)
{
	auto pass1 = sha1Of(cast(const(ubyte)[])password);
	auto pass2 = sha1Of(pass1);

	SHA1 sha1;
	sha1.start();
	sha1.put(authBuf);
	sha1.put(pass2);
	auto result = sha1.finish();
	foreach (size_t i; 0..20)
		result[i] = result[i] ^ pass1[i];
	return result.dup;
}

/// Get the next `mysql.result.Row` of a pending result set.
package(mysql) SafeRow getNextRow(Connection conn)
{
	scope(failure) conn.kill();

	if (conn._headersPending)
	{
		conn._rsh = ResultSetHeaders(conn, conn._fieldCount);
		conn._headersPending = false;
	}
	ubyte[] packet;
	SafeRow rr;
	packet = conn.getPacket();
	if(packet.front == ResultPacketMarker.error)
		throw new MYXReceived(OKErrorPacket(packet), __FILE__, __LINE__);

	if (packet.isEOFPacket())
	{
		conn._rowsPending = conn._binaryPending = false;
		return rr;
	}
	if (conn._binaryPending)
		rr = SafeRow(conn, packet, conn._rsh, true);
	else
		rr = SafeRow(conn, packet, conn._rsh, false);
	//rr._valid = true;
	return rr;
}

package(mysql) void consumeServerInfo(Connection conn, ref ubyte[] packet)
{
	scope(failure) conn.kill();

	conn._sCaps = cast(SvrCapFlags)packet.consume!ushort(); // server_capabilities (lower bytes)
	conn._sCharSet = packet.consume!ubyte(); // server_language
	conn._serverStatus = packet.consume!ushort(); //server_status
	conn._sCaps += cast(SvrCapFlags)(packet.consume!ushort() << 16); // server_capabilities (upper bytes)
	conn._sCaps |= SvrCapFlags.OLD_LONG_PASSWORD; // Assumed to be set since v4.1.1, according to spec

	enforce!MYX(conn._sCaps & SvrCapFlags.PROTOCOL41, "Server doesn't support protocol v4.1");
	enforce!MYX(conn._sCaps & SvrCapFlags.SECURE_CONNECTION, "Server doesn't support protocol v4.1 connection");
}

package(mysql) ubyte[] parseGreeting(Connection conn)
{
	scope(failure) conn.kill();

	ubyte[] packet = conn.getPacket();

	if (packet.length > 0 && packet[0] == ResultPacketMarker.error)
	{
		auto okp = OKErrorPacket(packet);
		enforce!MYX(!okp.error, "Connection failure: " ~ cast(string) okp.message);
	}

	conn._protocol = packet.consume!ubyte();

	conn._serverVersion = packet.consume!string(packet.countUntil(0));
	packet.skip(1); // \0 terminated _serverVersion

	conn._sThread = packet.consume!uint();

	// read first part of scramble buf
	ubyte[] authBuf;
	authBuf.length = 255;
	authBuf[0..8] = packet.consume(8)[]; // scramble_buff

	enforce!MYXProtocol(packet.consume!ubyte() == 0, "filler should always be 0");

	conn.consumeServerInfo(packet);

	packet.skip(1); // this byte supposed to be scramble length, but is actually zero
	packet.skip(10); // filler of \0

	// rest of the scramble
	auto len = packet.countUntil(0);
	enforce!MYXProtocol(len >= 12, "second part of scramble buffer should be at least 12 bytes");
	enforce(authBuf.length > 8+len);
	authBuf[8..8+len] = packet.consume(len)[];
	authBuf.length = 8+len; // cut to correct size
	enforce!MYXProtocol(packet.consume!ubyte() == 0, "Excepted \\0 terminating scramble buf");

	return authBuf;
}

package(mysql) SvrCapFlags getCommonCapabilities(SvrCapFlags server, SvrCapFlags client) pure
{
	SvrCapFlags common;
	uint filter = 1;
	foreach (size_t i; 0..uint.sizeof)
	{
		bool serverSupport = (server & filter) != 0; // can the server do this capability?
		bool clientSupport = (client & filter) != 0; // can we support it?
		if(serverSupport && clientSupport)
			common |= filter;
		filter <<= 1; // check next flag
	}
	return common;
}

package(mysql) SvrCapFlags setClientFlags(SvrCapFlags serverCaps, SvrCapFlags capFlags)
{
	auto cCaps = getCommonCapabilities(serverCaps, capFlags);

	// We cannot operate in <4.1 protocol, so we'll force it even if the user
	// didn't supply it
	cCaps |= SvrCapFlags.PROTOCOL41;
	cCaps |= SvrCapFlags.SECURE_CONNECTION;

	return cCaps;
}

package(mysql) void authenticate(Connection conn, ubyte[] greeting)
in
{
	assert(conn._open == Connection.OpenState.connected);
}
out
{
	assert(conn._open == Connection.OpenState.authenticated);
}
body
{
	auto token = makeToken(conn._pwd, greeting);
	auto authPacket = conn.buildAuthPacket(token);
	conn._socket.send(authPacket);

	auto packet = conn.getPacket();
	auto okp = OKErrorPacket(packet);
	enforce!MYX(!okp.error, "Authentication failure: " ~ cast(string) okp.message);
	conn._open = Connection.OpenState.authenticated;
}

// Register prepared statement
package(mysql) PreparedServerInfo performRegister(Connection conn, const(char[]) sql)
{
	scope(failure) conn.kill();

	PreparedServerInfo info;

	conn.sendCmd(CommandType.STMT_PREPARE, sql);
	conn._fieldCount = 0;

	ubyte[] packet = conn.getPacket();
	if(packet.front == ResultPacketMarker.ok)
	{
		packet.popFront();
		info.statementId    = packet.consume!int();
		conn._fieldCount    = packet.consume!short();
		info.numParams      = packet.consume!short();

		packet.popFront(); // one byte filler
		info.psWarnings     = packet.consume!short();

		// At this point the server also sends field specs for parameters
		// and columns if there were any of each
		info.headers = PreparedStmtHeaders(conn, conn._fieldCount, info.numParams);
	}
	else if(packet.front == ResultPacketMarker.error)
	{
		auto error = OKErrorPacket(packet);
		enforcePacketOK(error);
		assert(0); // FIXME: what now?
	}
	else
		assert(0); // FIXME: what now?

	return info;
}

/++
Flush any outstanding result set elements.

When the server responds to a command that produces a result set, it
queues the whole set of corresponding packets over the current connection.
Before that `Connection` can embark on any new command, it must receive
all of those packets and junk them.

As of v1.1.4, this is done automatically as needed. But you can still
call this manually to force a purge to occur when you want.

See_Also: $(LINK http://www.mysqlperformanceblog.com/2007/07/08/mysql-net_write_timeout-vs-wait_timeout-and-protocol-notes/)
+/
package(mysql) ulong purgeResult(Connection conn)
{
	scope(failure) conn.kill();

	conn._lastCommandID++;

	ulong rows = 0;
	if (conn._headersPending)
	{
		for (size_t i = 0;; i++)
		{
			if (conn.getPacket().isEOFPacket())
			{
				conn._headersPending = false;
				break;
			}
			enforce!MYXProtocol(i < conn._fieldCount,
				text("Field header count (", conn._fieldCount, ") exceeded but no EOF packet found."));
		}
	}
	if (conn._rowsPending)
	{
		for (;;  rows++)
		{
			if (conn.getPacket().isEOFPacket())
			{
				conn._rowsPending = conn._binaryPending = false;
				break;
			}
		}
	}
	conn.resetPacket();
	return rows;
}

/++
Get a textual report on the server status.

(COM_STATISTICS)
+/
package(mysql) string serverStats(Connection conn) @trusted
{
	conn.sendCmd(CommandType.STATISTICS, []);
	return cast(string) conn.getPacket();
}

/++
Enable multiple statement commands.

This can be used later if this feature was not requested in the client capability flags.

Warning: This functionality is currently untested.

Params: on = Boolean value to turn the capability on or off.
+/
//TODO: Need to test this
package(mysql) void enableMultiStatements(Connection conn, bool on)
{
	scope(failure) conn.kill();

	ubyte[] t;
	t.length = 2;
	t[0] = on ? 0 : 1;
	t[1] = 0;
	conn.sendCmd(CommandType.STMT_OPTION, t);

	// For some reason this command gets an EOF packet as response
	auto packet = conn.getPacket();
	enforce!MYXProtocol(packet[0] == 254 && packet.length == 5, "Unexpected response to SET_OPTION command");
}
