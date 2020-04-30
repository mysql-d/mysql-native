/++
This module publicly imports `mysql.unsafe.result`. Please see that module for
more documentation.

In the future, this will migrate to importing `mysql.safe.result`. In the far
future, the unsafe version will be deprecated and removed, and the safe version
moved to this location.

$(SAFE_MIGRATION)
++/
module mysql.result;

public import mysql.unsafe.result;
