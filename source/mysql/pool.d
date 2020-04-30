/++
This module publicly imports `mysql.unsafe.pool`. Please see that module for more documentation.

In the future, this will migrate to importing `mysql.safe.pool`. In the far
future, the unsafe version will be deprecated and removed, and the safe version
moved to this location.

$(SAFE_MIGRATION)
+/
module mysql.pool;

public import mysql.unsafe.pool;
