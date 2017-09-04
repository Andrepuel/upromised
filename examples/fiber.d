#!/usr/bin/env dub
/+ dub.json:
{
	"name": "fiber",
	"dependencies": {
		"upromised": {
			"version": "*",
			"path": "../"
		}
	},
	"subConfigurations": {
		"upromised": "with_openssl"
	}
}
+/

import std.stdio;
import upromised.http : Client, Header, Method;

int main(string[]) {
	import std.algorithm : each;
	import upromised.fiber : async, await;
	import upromised.loop : defaultLoop;
	import upromised.operations : readAllChunks;
	auto loop = defaultLoop();

	async(() {
		auto ctx = await(loop.context(loop.defaultCertificatesPath));
		auto conn = await(loop.connectTcp(await(loop.resolve("ipv4.icanhazip.com", 443))));
		scope(exit) await(conn.close());
		auto tlsStream = await(loop.tlsHandshake(conn, ctx, "ipv4.icanhazip.com"));
		scope(exit) await(tlsStream.close());
		auto http = new Client(tlsStream);
		auto r = await(http.fullRequest(Method.GET, "/", [Header("Host", "ipv4.icanhazip.com")]));
		writeln(r.response);
		r.headers.each!writeln;
		auto data = cast(const(char)[])await(r.bodyData.readAllChunks);
		writeln(data);
		await(tlsStream.shutdown());
	}).nothrow_();

	return loop.run();
}