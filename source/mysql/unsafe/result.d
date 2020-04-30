/++
This module publicly imports `mysql.impl.result`. See that module for documentation on how to use result and result range structures (unsafe versions).

This module also aliases the unsafe versions of structs to the original struct
names to aid in backwards compatibility.

$(SAFE_MIGRATION)
+/
module mysql.unsafe.result;

public import mysql.impl.result;

/++
Unsafe aliases. Use these instead of the real name. See the documentation on
the aliased types for usage.
+/
alias Row = UnsafeRow;
/// ditto
alias ResultRange = UnsafeResultRange;
