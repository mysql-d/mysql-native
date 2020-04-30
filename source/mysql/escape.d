/++
Escape special characters in MySQL strings.

Note, it is strongly recommended to use prepared statements instead of relying
on manual escaping, as prepared statements are always safer, better and more
reliable (see `mysql.prepared`). But if you absolutely must escape manually,
the functionality is provided here.
+/
module mysql.escape;


/++
Simple escape function for dangerous SQL characters

Params:
	input = string to escape
	buffer = buffer to use for the output
+/
void mysql_escape ( Buffer, Input ) ( Input input, Buffer buffer )
{
	import std.string : translate;

	immutable string[dchar] transTable = [
		'\\' : "\\\\",
		'\'' : "\\'",
		'\0' : "\\0",
		'\n' : "\\n",
		'\r' : "\\r",
		'"'  : "\\\"",
		'\032' : "\\Z"
	];

	translate(input, transTable, null, buffer);
}


/++
Struct to wrap around a string so it can be passed to formattedWrite and be
properly escaped all using the buffer that formattedWrite provides.

Params:
	Input = (Template Param) Type of the input

Note:
    The delegate is expected to be @safe as of version 3.1.0.
+/
struct MysqlEscape ( Input )
{
	Input input;

	const void toString ( scope void delegate(const(char)[]) @safe sink )
	{
		mysql_escape(input, sink);
	}
}

/++
Helper function to easily construct a escape wrapper struct

Params:
	T = (Template Param) Type of the input
	input = Input to escape
+/
MysqlEscape!(T) mysqlEscape ( T ) ( T input )
{
	return MysqlEscape!(T)(input);
}

@("mysqlEscape")
debug(MYSQLN_TESTS)
@safe unittest
{
	import std.array : appender;

	auto buf = appender!string();

	import std.format : formattedWrite;

	formattedWrite(buf, "%s, %s, %s, mkay?", 1, 2,
			mysqlEscape("\0, \r, \n, \", \\"));

	assert(buf.data() == `1, 2, \0, \r, \n, \", \\, mkay?`);
}
