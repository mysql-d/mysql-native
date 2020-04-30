/++
This module publicly imports `mysql.impl.result`. See that module for documentation on how to use result and result range structures (safe versions).

This module also aliases the safe versions of these structs to the original
struct names to aid in transitioning to using safe code with minimal impact.

$(SAFE_MIGRATION)
+/
module mysql.safe.result;

public import mysql.impl.result;

/++
Safe aliases. Use these instead of the real name. See the documentation on
the aliased types for usage.
+/
alias Row = SafeRow;
/// ditto
alias ResultRange = SafeResultRange;
