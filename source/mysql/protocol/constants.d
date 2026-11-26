/// Internal - Misc protocol constants.
module mysql.protocol.constants;

/++
Server capability flags.

During the connection handshake process, the server sends a uint of flags
describing its capabilities.

See_Also: $(LINK https://dev.mysql.com/doc/internals/en/capability-flags.html)
+/
enum SvrCapFlags: uint
{
	OLD_LONG_PASSWORD   = 0x0_0001, /// Long old-style passwords (Not 4.1+ passwords)
	FOUND_NOT_AFFECTED  = 0x0_0002, /// Report rows found rather than rows affected
	ALL_COLUMN_FLAGS    = 0x0_0004, /// Send all column flags
	WITH_DB             = 0x0_0008, /// Can take database as part of login
	NO_SCHEMA           = 0x0_0010, /// Can disallow database name as part of column name database.table.column
	CAN_COMPRESS        = 0x0_0020, /// Can compress packets
	ODBC                = 0x0_0040, /// Can handle ODBC
	LOCAL_FILES         = 0x0_0080, /// Can use LOAD DATA LOCAL
	IGNORE_SPACE        = 0x0_0100, /// Can ignore spaces before '$(LPAREN)'
	PROTOCOL41          = 0x0_0200, /// Can use 4.1+ protocol
	INTERACTIVE         = 0x0_0400, /// Interactive client?
	SSL                 = 0x0_0800, /// Can switch to SSL after handshake
	IGNORE_SIGPIPE      = 0x0_1000, /// Ignore sigpipes?
	TRANSACTIONS        = 0x0_2000, /// Transaction support
	RESERVED            = 0x0_4000, ///  Old flag for 4.1 protocol
	SECURE_CONNECTION   = 0x0_8000, /// 4.1+ authentication
	MULTI_STATEMENTS    = 0x1_0000, /// Multiple statement support
	MULTI_RESULTS       = 0x2_0000, /// Multiple result set support
}

/++
Column type codes

$(LINK2 https://dev.mysql.com/doc/internals/en/com-query-response.html#column-type, Reference)
+/
enum SQLType : short
{
	INFER_FROM_D_TYPE = -1,
	DECIMAL      = 0x00,
	TINY         = 0x01,
	SHORT        = 0x02,
	INT          = 0x03,
	FLOAT        = 0x04,
	DOUBLE       = 0x05,
	NULL         = 0x06,
	TIMESTAMP    = 0x07,
	LONGLONG     = 0x08,
	INT24        = 0x09,
	DATE         = 0x0a,
	TIME         = 0x0b,
	DATETIME     = 0x0c,
	YEAR         = 0x0d,
	NEWDATE      = 0x0e,
	VARCHAR      = 0x0f, // new in MySQL 5.0
	BIT          = 0x10, // new in MySQL 5.0
	JSON = 0xf5, // new in MySQL 5.7.8
	NEWDECIMAL   = 0xf6, // new in MYSQL 5.0
	ENUM         = 0xf7,
	SET          = 0xf8,
	TINYBLOB     = 0xf9,
	MEDIUMBLOB   = 0xfa,
	LONGBLOB     = 0xfb,
	BLOB         = 0xfc,
	VARSTRING    = 0xfd,
	STRING       = 0xfe,
	GEOMETRY     = 0xff
}

/++
Server refresh flags
+/
enum RefreshFlags : ubyte
{
	GRANT    =   1,
	LOG      =   2,
	TABLES   =   4,
	HOSTS    =   8,
	STATUS   =  16,
	THREADS  =  32,
	SLAVE    =  64,
	MASTER   = 128
}

/++
Type of Command Packet (COM_XXX)
See_Also: $(LINK https://dev.mysql.com/doc/internals/en/command-phase.html)
+/
enum CommandType : ubyte
{
	SLEEP               = 0x00,
	QUIT                = 0x01,
	INIT_DB             = 0x02,
	QUERY               = 0x03,
	FIELD_LIST          = 0x04,
	CREATE_DB           = 0x05,
	DROP_DB             = 0x06,
	REFRESH             = 0x07,
	SHUTDOWN            = 0x08,
	STATISTICS          = 0x09,
	PROCESS_INFO        = 0x0a,
	CONNECT             = 0x0b,
	PROCESS_KILL        = 0x0c,
	DEBUG               = 0x0d,
	PING                = 0x0e,
	TIME                = 0x0f,
	DELAYED_INSERT      = 0x10,
	CHANGE_USER         = 0x11,
	BINLOG_DUBP         = 0x12,
	TABLE_DUMP          = 0x13,
	CONNECT_OUT         = 0x14,
	REGISTER_SLAVE      = 0x15,
	STMT_PREPARE        = 0x16,
	STMT_EXECUTE        = 0x17,
	STMT_SEND_LONG_DATA = 0x18,
	STMT_CLOSE          = 0x19,
	STMT_RESET          = 0x1a,
	STMT_OPTION         = 0x1b,
	STMT_FETCH          = 0x1c,
}

/// Magic marker sent in the first byte of mysql results in response to auth or command packets.
enum ResultPacketMarker : ubyte
{
	/++
	Server reports an error
	See_Also: $(LINK https://dev.mysql.com/doc/internals/en/packet-ERR_Packet.html)
	+/
	error   = 0xff,

	/++
	No error, no result set.
	See_Also: $(LINK https://dev.mysql.com/doc/internals/en/packet-OK_Packet.html)
	+/
	ok      = 0x00,

	/++
	Server reports end of data
	See_Also: $(LINK https://dev.mysql.com/doc/internals/en/packet-EOF_Packet.html)
	+/
	eof     = 0xfe,
}

/++
Field Flags
See_Also: $(LINK https://dev.mysql.com/doc/dev/mysql-server/8.0.26/group__group__cs__column__definition__flags.html)
+/
enum FieldFlags : ushort
{
	NOT_NULL        = 0x0001,
	PRI_KEY         = 0x0002,
	UNIQUE_KEY      = 0x0004,
	MULTIPLE_KEY    = 0x0008,
	BLOB            = 0x0010,
	UNSIGNED        = 0x0020,
	ZEROFILL        = 0x0040,
	BINARY          = 0x0080,
	ENUM            = 0x0100,
	AUTO_INCREMENT  = 0x0200,
	TIMESTAMP       = 0x0400,
	SET             = 0x0800
}
