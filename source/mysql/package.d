/++
Imports all of $(LINK2 https://github.com/mysql-d/mysql-native, mysql-native).

MySQL_to_D_Type_Mappings:

$(TABLE
	$(TR $(TH MySQL      ) $(TH D            ))

	$(TR $(TD NULL       ) $(TD typeof(null) ))
	$(TR $(TD BIT        ) $(TD bool         ))
	$(TR $(TD TINY       ) $(TD (u)byte      ))
	$(TR $(TD SHORT      ) $(TD (u)short     ))
	$(TR $(TD INT24      ) $(TD (u)int       ))
	$(TR $(TD INT        ) $(TD (u)int       ))
	$(TR $(TD LONGLONG   ) $(TD (u)long      ))
	$(TR $(TD FLOAT      ) $(TD float        ))
	$(TR $(TD DOUBLE     ) $(TD double       ))
)

$(TABLE
	$(TR $(TH MySQL      ) $(TH D            ))

	$(TR $(TD TIMESTAMP  ) $(TD DateTime     ))
	$(TR $(TD TIME       ) $(TD TimeOfDay    ))
	$(TR $(TD YEAR       ) $(TD ushort       ))
	$(TR $(TD DATE       ) $(TD Date         ))
	$(TR $(TD DATETIME   ) $(TD DateTime     ))
)

$(TABLE
	$(TR $(TH MySQL                                             ) $(TH D                    ))

	$(TR $(TD VARCHAR, ENUM, SET, VARSTRING, STRING, NEWDECIMAL ) $(TD string               ))
	$(TR $(TD TINYBLOB, MEDIUMBLOB, BLOB, LONGBLOB              ) $(TD ubyte[]              ))
	$(TR $(TD TINYTEXT, MEDIUMTEXT, TEXT, LONGTEXT              ) $(TD string               ))
	$(TR $(TD other                                             ) $(TD unsupported (throws) ))
)

D_to_MySQL_Type_Mappings:

$(TABLE
	$(TR $(TH D            ) $(TH MySQL               ))
	
	$(TR $(TD typeof(null) ) $(TD NULL                ))
	$(TR $(TD bool         ) $(TD BIT                 ))
	$(TR $(TD (u)byte      ) $(TD (UNSIGNED) TINY     ))
	$(TR $(TD (u)short     ) $(TD (UNSIGNED) SHORT    ))
	$(TR $(TD (u)int       ) $(TD (UNSIGNED) INT      ))
	$(TR $(TD (u)long      ) $(TD (UNSIGNED) LONGLONG ))
	$(TR $(TD float        ) $(TD (UNSIGNED) FLOAT    ))
	$(TR $(TD double       ) $(TD (UNSIGNED) DOUBLE   ))
	
	$(TR $(TD $(STD_DATETIME_DATE Date)     ) $(TD DATE      ))
	$(TR $(TD $(STD_DATETIME_DATE TimeOfDay)) $(TD TIME      ))
	$(TR $(TD $(STD_DATETIME_DATE Time)     ) $(TD TIME      ))
	$(TR $(TD $(STD_DATETIME_DATE DateTime) ) $(TD DATETIME  ))
	$(TR $(TD `mysql.types.Timestamp`       ) $(TD TIMESTAMP ))

	$(TR $(TD string    ) $(TD VARCHAR              ))
	$(TR $(TD char[]    ) $(TD VARCHAR              ))
	$(TR $(TD (u)byte[] ) $(TD SIGNED TINYBLOB      ))
	$(TR $(TD other     ) $(TD unsupported (throws) ))
)

+/
module mysql;

public import mysql.commands;
public import mysql.connection;
public import mysql.escape;
public import mysql.exceptions;
public import mysql.metadata;
public import mysql.pool;
public import mysql.prepared;
public import mysql.protocol.constants : SvrCapFlags;
public import mysql.result;
public import mysql.types;

debug(MYSQLN_TESTS)      version = DoCoreTests;
debug(MYSQLN_CORE_TESTS) version = DoCoreTests;

version(DoCoreTests)
{
	public import mysql.protocol.comms;
	public import mysql.protocol.constants;
	public import mysql.protocol.extra_types;
	public import mysql.protocol.packet_helpers;
	public import mysql.protocol.packets;
	public import mysql.protocol.sockets;

	public import mysql.test.common;
	public import mysql.test.regression;

	version(MYSQLN_TESTS_NO_MAIN) {} else
	{
		void main() {}
	}
}
