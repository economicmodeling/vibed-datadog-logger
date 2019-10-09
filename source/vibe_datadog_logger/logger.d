module vibed_datadog_logger.logger;

import std.algorithm.iteration : each, map;
import std.algorithm.searching;
import std.stdio;
import vibe.core.log : Logger, LogLine, LogLevel;
import vibe.core.net : connectTCP;
import std.array : appender;
import core.time : Duration;
import std.datetime : Clock, SysTime;
import std.socket;
import std.conv : to;
import std.string : indexOf;
import std.format : format;
import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse, HTTPMethod;

private alias MessageBuffer = typeof(appender!(char[])());

// Bypass to!string for log levels because we look them up frequently
private immutable string[LogLevel.max + 1] levelToString;

private string escapeChars(char ch) pure nothrow @safe
{
	switch (ch)
	{
		case '"':
		return `\"`;
		default:
		return () @trusted { return cast(string)[ch]; }();
	}
}

private void putEscapedString(ref typeof(appender!string()) buffer, const(char)[] str) @safe
{
	import std.utf : byCodeUnit;

	str.byCodeUnit().map!(ch => escapeChars(ch)).each!(s => buffer.put(s));
}

shared static this()
{
	levelToString[LogLevel.trace] = "trace";
	levelToString[LogLevel.debugV] = "debugVerbose";
	levelToString[LogLevel.debug_] = "debug";
	levelToString[LogLevel.diagnostic] = "diagnostic";
	levelToString[LogLevel.info] = "info";
	levelToString[LogLevel.warn] = "warn";
	levelToString[LogLevel.error] = "error";
	levelToString[LogLevel.critical] = "critical";
	levelToString[LogLevel.fatal] = "fatal";
	levelToString[LogLevel.none] = "none";
}

struct DatadogInfo
{
	string ingestEndpoint;
	ushort portNumber;
	string apiKey;
	string hostName;
	string serviceName;
	string sourceName;
	string environment;
}

class DatadogLogger : Logger
{
	this(const DatadogInfo datadogInfo, const Duration maxLogInterval, 
		const size_t messageQueueSize)
	{

		this.maxLogInterval = maxLogInterval;
		this.entries = new LogEntry[](messageQueueSize);
		this.multilineLogger = true;
		this.minLevel = LogLevel.info;
		this.lastFlushTime = Clock.currTime();
		this.datadogInfo = datadogInfo;
		this.logQueueIndex = 0;
		this.flushing = false;
	}

	override void beginLine(ref LogLine line) @safe
	{
		if (flushing)
			return;

		LogEntry* l = &entries[logQueueIndex];
		l.level = levelToString[line.level];
		l.lLevel = line.level;
		l.time = line.time.toISOExtString();
		l.buffer.clear();
	}

	override void endLine() @safe
	{
		if (flushing)
			return;

		immutable r = logQueueIndex;
		logQueueIndex++;
		if (logQueueIndex == entries.length || entries[r].lLevel >= LogLevel.critical
			|| (entries[r].lLevel == LogLevel.diagnostic
				&& entries[r].buffer.data == "Main thread exiting")
			|| lastFlushTime + maxLogInterval < Clock.currTime())
			flush();
	}

	override void put(scope const(char)[] text) @safe
	{
		if (flushing)
			return;

		entries[logQueueIndex].buffer.put(text);
	}

private:

	void flush() @safe
	{
		
		flushing = true;
		scope(exit) flushing = false;

		immutable url = format!"%s/v1/input/%s"(datadogInfo.ingestEndpoint, datadogInfo.apiKey);

		writeln(url);

        version(debug_datadog_logger)
        {
            () @trusted { stderr.writeln("\033[01;33m", url, "\033[0m"); }();
        }
        auto requestBody = appender!string();
        requestBody.put(`[`);

        foreach (i, ref entry; entries[0 .. logQueueIndex])
        {
        	if (entry.buffer.data.canFind("add route"))
        		continue;
        	
        	requestBody.put(`{"message":"`);
        	requestBody.putEscapedString(entry.buffer.data);
        	requestBody.put(`", "service" : "`~datadogInfo.serviceName~`"`);
        	requestBody.put(`, "ddtags" : "hostname:`~datadogInfo.hostName~`,`~datadogInfo.environment~`"`);
        	requestBody.put(`, "ddsource" : "`~datadogInfo.sourceName~`"`);
        	requestBody.put(`}`);

        	if(i+1 != logQueueIndex)
        		requestBody.put(`, `);


        }
        requestBody.put(`]`);
        writeln(requestBody.data);
		version(debug_datadog_logger)
        {
            () @trusted { stderr.writeln("\033[01;33m", requestBody.data, "\033[0m"); }();
        }

		logQueueIndex = 0;
		this.lastFlushTime = Clock.currTime();

		requestHTTP(url,
			(scope request) {
				request.method = HTTPMethod.POST;
				request.writeBody(cast(ubyte[]) requestBody.data, "application/json");
			},
			(scope response) {
				version(debug_datadog_logger)
				{
					import vibe.stream.operations : readAllUTF8;
					() @trusted { stderr.writeln("\033[01;33mStatus code: ", response.statusCode, "\033[0m"); }();
                    () @trusted { stderr.writeln("\033[01;33mResponse message: ", response.bodyReader.readAllUTF8(), "\033[0m"); }();
				}
				response.dropBody();
			});
	}

	struct LogEntry
	{
		string message;
		LogLevel lLevel;
		string level;
		string time;
		MessageBuffer buffer;
	}

    // See constructor docs
    const Duration maxLogInterval;
    // See constructor docs
    const DatadogInfo datadogInfo;
    // Time that the last flush happened
    SysTime lastFlushTime;
    // Message queue
    LogEntry[] entries;
    // Index into the `entries` buffer.
    size_t logQueueIndex;
    // True if the logger is currently flushing log info to the server. Prevents
    // the HTTP request code from causing an infinite recursion.
    bool flushing;
}