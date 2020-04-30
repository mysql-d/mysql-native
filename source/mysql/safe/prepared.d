/++
This module publicly imports `mysql.impl.prepared` (safe version). See that
module for documentation on using prepared statements with a MySQL server.

This module also aliases the safe versions of structs to the original struct
names to aid in transitioning to using safe code with minimal impact.

$(SAFE_MIGRATION)
+/
module mysql.safe.prepared;

public import mysql.impl.prepared;

/++
Safe aliases. Use these instead of the real name. See the documentation on
the aliased types for usage.
+/
alias Prepared = SafePrepared;
/// ditto
alias ParameterSpecialization = SafeParameterSpecialization;
/// ditto
alias PSN = SafeParameterSpecialization;
