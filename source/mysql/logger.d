module mysql.logger;

/*
  The aliased log functions in this module map to equivelant functions in either vibe.core.log or std.experimental.logger.
  For this reason, only log levels common to both are used. The exception to this is logDebug which is uses trace when
  using std.experimental.logger, only because it's commonly used and trace/debug/verbose are all similar in use.
  Also, I've chosen not to support fatal errors as std.experimental.logger will create an exception if you choose to
  log at this level, which is an unhelpful side effect.

  See the following table for how they are mapped:

  | Our logger		| vibe.core.log | LogLevel (std.experimental.logger) |
  | --------------- | ------------- | ---------------------------------- |
  | logTrace 		| logTrace 		| LogLevel.trace		  			 |
  |	N/A				| logDebugV		| N/A				      			 |
  | logDebug		| logDebug		| LogLevel.trace					 |
  | N/A				| logDiagnostic | N/A				      			 |
  | logInfo			| logInfo		| LogLevel.info 		  			 |
  | logWarn			| logWarn		| LogLevel.warning  	  			 |
  | logError		| logError		| LogLevel.error 		  			 |
  | logCritical		| logCritical	| LogLevel.critical 	  			 |
  | N/A				| logFatal		| LogLevel.fatal 		  			 |

*/
version(Have_vibe_core) {
	import vibe.core.log;

	alias logTrace = vibe.core.log.logTrace;
	alias logDebug = vibe.core.log.logDebug;
	alias logInfo = vibe.core.log.logInfo;
	alias logWarn = vibe.core.log.logWarn;
	alias logError = vibe.core.log.logError;
	alias logCritical = vibe.core.log.logCritical;
	//alias logFatal = vibe.core.log.logFatal;
} else static if(__traits(compiles, (){ import std.experimental.logger; } )) {
	import std.experimental.logger;

	alias logTrace = std.experimental.logger.tracef;
	alias logDebug = std.experimental.logger.tracef; // no debug level in std.experimental.logger but arguably trace/debug/verbose all mean the same
	alias logInfo = std.experimental.logger.infof;
	alias logWarn = std.experimental.logger.warningf;
	alias logError = std.experimental.logger.errorf;
	alias logCritical = std.experimental.logger.criticalf;
	//alias logFatal = std.experimental.logger.fatalf;
}

unittest {
	version(Have_vibe_core) {
		import std.stdio : writeln;
		writeln("Running the logger tests using (vibe.core.log)");
		// Althouth there are no asserts here, this confirms that the alias compiles ok also the output
		// is shown in the terminal when running 'dub test' and the levels logged using different colours.
		logTrace("Test that a call to mysql.logger.logTrace maps to vibe.core.log.logTrace");
		logDebug("Test that a call to mysql.logger.logDebug maps to vibe.core.log.logDebug");
		logInfo("Test that a call to mysql.logger.logInfo maps to vibe.core.log.logInfo");
		logWarn("Test that a call to mysql.logger.logWarn maps to vibe.core.log.logWarn");
		logError("Test that a call to mysql.logger.logError maps to vibe.core.log.logError");
		logCritical("Test that a call to mysql.logger.logCritical maps to vibe.core.log.logCritical");
		//logFatal("Test that a call to mysql.logger.logFatal maps to vibe.core.log.logFatal");
	} else static if(__traits(compiles, (){ import std.experimental.logger; } )) {
		// Checks that when using std.experimental.logger the log entry is correct.
		// This test kicks in when commenting out the 'vibe-core' dependency and running 'dub test', although
		// not ideal if vibe-core is availble the logging goes through vibe anyway.
		// Output can be seen in terminal when running 'dub test'.
		import std.experimental.logger : Logger, LogLevel, sharedLog;
		import std.stdio : writeln, writefln;
		import std.conv : to;

		writeln("Running the logger tests using (std.experimental.logger)");

		class TestLogger : Logger {
			LogLevel logLevel;
			string file;
			string moduleName;
			string msg;

			this(LogLevel lv) @safe {
				super(lv);
			}

			override void writeLogMsg(ref LogEntry payload) @trusted {
				this.logLevel = payload.logLevel;
				this.file = payload.file;
				this.moduleName = payload.moduleName;
				this.msg = payload.msg;
				// now output it to stdio so it can be seen in terminal when testing
				writefln(" - testing [%s] %s(%s) : %s", payload.logLevel, payload.file, to!string(payload.line), payload.msg);
			}
		}

		auto logger = new TestLogger(LogLevel.all);
		sharedLog = logger;

		// check that the various log alias functions get the expected results
		logDebug("This is a TRACE message");
		assert(logger.logLevel == LogLevel.trace, "expected 'LogLevel.trace' got: " ~ logger.logLevel);
		assert(logger.msg == "This is a TRACE message", "The logger should have logged 'This is a TRACE message' but instead was: " ~ logger.msg);
		assert(logger.file == "source/mysql/logger.d", "expected 'source/mysql/logger.d' got: " ~ logger.file);
		assert(logger.moduleName == "mysql.logger", "expected 'mysql.logger' got: " ~ logger.moduleName);

		logDebug("This is a DEBUG message (maps to trace)");
		assert(logger.logLevel == LogLevel.trace, "expected 'LogLevel.trace' got: " ~ logger.logLevel);
		assert(logger.msg == "This is a DEBUG message (maps to trace)", "The logger should have logged 'This is a DEBUG message (maps to trace)' but instead was: " ~ logger.msg);
		assert(logger.file == "source/mysql/logger.d", "expected 'source/mysql/logger.d' got: " ~ logger.file);
		assert(logger.moduleName == "mysql.logger", "expected 'mysql.logger' got: " ~ logger.moduleName);

		logInfo("This is an INFO message");
		assert(logger.logLevel == LogLevel.info, "expected 'LogLevel.info' got: " ~ logger.logLevel);
		assert(logger.msg == "This is an INFO message", "The logger should have logged 'This is an INFO message' but instead was: " ~ logger.msg);

		logWarn("This is a WARNING message");
		assert(logger.logLevel == LogLevel.warning, "expected 'LogLevel.warning' got: " ~ logger.logLevel);
		assert(logger.msg == "This is a WARNING message", "The logger should have logged 'This is a WARNING message' but instead was: " ~ logger.msg);

		logError("This is a ERROR message");
		assert(logger.logLevel == LogLevel.error, "expected 'LogLevel.error' got: " ~ logger.logLevel);
		assert(logger.msg == "This is a ERROR message", "The logger should have logged 'This is a ERROR message' but instead was: " ~ logger.msg);

		logCritical("This is a CRITICAL message");
		assert(logger.logLevel == LogLevel.critical, "expected 'LogLevel.critical' got: " ~ logger.logLevel);
		assert(logger.msg == "This is a CRITICAL message", "The logger should have logged 'This is a CRITICAL message' but instead was: " ~ logger.msg);
	}
}
