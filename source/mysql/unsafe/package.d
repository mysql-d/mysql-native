/++
Imports all of $(LINK2 https://github.com/mysql-d/mysql-native, mysql-native) (unsafe versions).

This module will import all modules that use the unsafe API of the mysql
library. Please import `mysql.safe` for the safe version.

$(SAFE_MIGRATION)
+/
module mysql.unsafe;

public import mysql.unsafe.commands;
public import mysql.unsafe.result;
public import mysql.unsafe.pool;
public import mysql.unsafe.prepared;
public import mysql.unsafe.connection;

// common imports
public import mysql.escape;
public import mysql.exceptions;
public import mysql.metadata;
public import mysql.protocol.constants : SvrCapFlags;
public import mysql.types;
