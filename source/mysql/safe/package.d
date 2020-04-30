/++
Imports all of $(LINK2 https://github.com/mysql-d/mysql-native, mysql-native) (safe versions).

This module will import all modules that use the safe API of the mysql library.
In a future version, this will become the default.

$(SAFE_MIGRATION)
+/
module mysql.safe;

public import mysql.safe.commands;
public import mysql.safe.result;
public import mysql.safe.pool;
public import mysql.safe.prepared;
public import mysql.safe.connection;

// common imports
public import mysql.escape;
public import mysql.exceptions;
public import mysql.metadata;
public import mysql.protocol.constants : SvrCapFlags;
public import mysql.types;
