#!/usr/bin/env dub
/+ dub.json:
{
	"name": "tls_server",
	"dependencies": {
		"upromised": {
			"version": "*",
			"path": "../"
		}
	}
}
+/

import std.stdio;
import upromised.loop : defaultLoop;
import upromised.tls : TlsContext, TlsStream;
import upromised.promise : Promise;

int main(string[] args) {
	string certPath = args[1];
	string keyPath = args[2];

	writeln(certPath);
	writeln(keyPath);
	auto ctx = new TlsContext(certPath, keyPath);

	defaultLoop().resolve("127.0.0.1", 8888)
	.then((addr) => defaultLoop().listenTcp(addr)
		.each((conn) {
			writeln("Received connection");
			Promise!void.resolved()
			.then(() => new TlsStream(conn, ctx))
			.then((stream) => stream.accept()
			.then(() => stream.write(cast(immutable(ubyte)[])"Hello There\n"))
			.then(() => stream.read().each((data) {
				writeln([cast(const(char)[])data]);
			}))
			.finall(() => stream.close()))
			.except((Exception e) {
				writeln(e);
			})
			.nothrow_();
		}))
	.nothrow_();

	return defaultLoop().run();
}