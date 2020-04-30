/++
This module publicly imports `mysql.unsafe.commands`. Please see that module for more documentation.

In the far future, the unsafe version will be deprecated and removed, and the
safe version moved to this location.

$(SAFE_MIGRATION)
+/
module mysql.commands;
public import mysql.unsafe.commands;
