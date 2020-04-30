/++
This module publicly imports `mysql.impl.prepared` (unsafe version). See that
module for documentation on using prepared statements with a MySQL server.

This module also aliases the unsafe versions of structs to the original struct
names to aid in backwards compatibility.

$(SAFE_MIGRATION)
++/
module mysql.unsafe.prepared;

public import mysql.impl.prepared;

/++
Unsafe aliases. Use these instead of the real name. See the documentation on
the aliased types for usage.
++/
alias Prepared = UnsafePrepared;
/// ditto
alias ParameterSpecialization = UnsafeParameterSpecialization;
/// ditto
alias PSN = UnsafeParameterSpecialization;
