#!/usr/bin/env dub
/+ dub.json:
{
	"name": "proxy_command",
	"dependencies": {
		"upromised": {
			"version": "*",
			"path": "../"
		}
	}
}
+/

import std.exception : enforce;
import std.stdio : stderr;
import upromised.loop : defaultLoop;
import upromised.stream : Stream;
import upromised.pipe : Pipe;
import upromised.process : Process;
import upromised.promise : Promise, PromiseIterator;

Promise!void forward(PromiseIterator!(const(ubyte)[]) from, Stream to) {
	return from.each((data) => to.write(data.idup)).then((_) => to.shutdown());
}

int main(string[] args) {
	import std.algorithm : countUntil, map;
	import std.array : array;
	import std.conv : to;
	import std.random : uniform;
	import std.string : replace, string;

	auto sep = args.countUntil("--");
	enforce(sep >= 0, "Expected -- paramater separating command from the proxy");
	ushort port = cast(ushort)uniform(0x400, 0x10000);
	string[] proxyArgs = args[1..sep];
	string[] commandArgs = args[sep+1..$].map!(x => x.replace("%h", "127.0.0.1").replace("%p", port.to!string)).array;

	auto loop = defaultLoop();
	loop.resolve("127.0.0.1", port)
	.then((addr) => loop.listenTcp(addr).each((conn) {
		Pipe cin = new Pipe(loop);
		Pipe cout = new Pipe(loop);
		
		Process proxy = new Process(loop, proxyArgs, cin, cout, Process.STDERR);
		auto paral = forward(conn.read(), cin);

		forward(cout.read(), conn)
		.then(() => paral)
		.finall(() => cin.close())
		.finall(() => cout.close())
		.finall(() => conn.close())
		.except((Exception e) {
			stderr.writeln(e);
		}).nothrow_();
	})).nothrow_();

	Process command = new Process(loop, commandArgs, Process.STDIN, Process.STDOUT, Process.STDERR);
	int r;
	command.wait()
	.then((rArg) {
		r = cast(int)rArg;
	}).nothrow_();

	loop.run();
	return r;
}
