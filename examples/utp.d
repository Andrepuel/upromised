#!/usr/bin/env dub
/+ dub.json:
{
	"name": "utp",
	"dependencies": {
		"upromised": {
			"version": "*",
			"path": "../"
		}
	}
}
+/

import std.stdio;
import upromised.utp : UtpContext;
import upromised.fiber : async, await;
import upromised.loop : defaultLoop;

int main(string[]) {
	async(() {
		auto addr = defaultLoop().resolve("127.0.0.1", 9999).await[0];
		auto udp = defaultLoop().udp(addr).await;
		auto ctx = new UtpContext(defaultLoop, udp);
		scope(exit) ctx.close().await;
		async(() {
			auto listen = ctx.accept();
			writeln("Listening!");
			while (true) {
				auto eachV = listen.next.await;
				if (eachV.eof) break;
				auto each = eachV.value;
				scope(exit) each.close().await;

				writeln("Connect!");
				size_t total;
				each.read().each((data) {
					import std.datetime : msecs;
					total += data.length;
					writeln("Rx ", total);
					return defaultLoop.sleep(1000.msecs).then(() => true);
				}).await;
				writeln("End!");
			}
			writeln("End listen!");
		}).nothrow_;
		auto conn = ctx.connect(addr).await;
		scope(exit) conn.close.await;
		writeln("Connected client side!");
		int w;
		while (w < 10*1024) {
			conn.write(cast(immutable(ubyte)[])"Oi!").await;
			writeln("Tx ", (++w)*3);
		}
	}).nothrow_();

	return defaultLoop().run;
}