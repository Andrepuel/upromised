#!/usr/bin/env dub
/+ dub.json:
{
	"name": "socks5_server",
	"dependencies": {
		"upromised": {
			"version": "*",
			"path": "../"
		}
	}
}
+/

import std.exception : enforce;
import std.format : format;
import upromised.loop : defaultLoop, Loop;
import upromised.pipe : Pipe;
import upromised.process : Process;
import upromised.promise : Promise, PromiseIterator;
import upromised.stream : Stream;
import upromised.tcp : TcpSocket;
import upromised.tokenizer : Tokenizer;

Promise!void forward(PromiseIterator!(const(ubyte)[]) from, Stream to) {
	return from.each((data) => to.write(data.idup)).then((_) => to.shutdown());
}

enum ubyte[3] socks5_client_hello = [5, 1, 0];

struct socks5_server_hello {
align (1):
	ubyte ver;
	ubyte auth;
}
static assert(socks5_server_hello.sizeof == 2);

struct socks5_client_connect {
align (1):
	ubyte ver;
	ubyte command;
	ubyte reserver;
	ubyte addr_type;
}
static assert(socks5_client_connect.sizeof == 4);


struct socks5_server_connect {
align (1):
	ubyte ver;
	ubyte status;
	ubyte reserved;
	ubyte addr_type;
}
static assert(socks5_server_connect.sizeof == 4);

const(ubyte)[] serial(T)(T a) {
	return (cast(const(ubyte)[])((&a)[0..1])).dup;
}

Promise!T readStruct(T)(Tokenizer!(const(ubyte)) input) {
	input.limit(T.sizeof);
	T value;
	return input.read().each((bytes) {
		value = (cast(const(T)[])bytes)[0];
		return false;
	}).then((bool) => value);
}

Promise!(const(ubyte)[]) readOne(PromiseIterator!(const(ubyte)[]) input) {
	ubyte[] r;
	return input.each((bytes) {
		r = bytes.dup;
		return false;
	}).then((_) => cast(const(ubyte)[])r);
}

void handleConn(Loop loop, Stream conn, string[] subproc) {
	import std.algorithm : filter, map;
	import std.array : array;
	import std.bitmanip : bigEndianToNative;
	import std.conv : to;
	import std.exception : assumeUnique;
	import std.string : replace;

	ubyte[] addressRepeat;
	auto read = new Tokenizer!(const(ubyte))(conn.read());
	read.readStruct!ubyte().then((ver) {
		enforce(ver == 5);
	}).then(() => read.readStruct!ubyte())
	.then((amount) {
		enforce(amount > 0);
		read.limit(amount);
	}).then(() => readOne(read.read()))
	.then((methods) {
		if (methods.filter!(x => x == 0).empty) {
			return conn.write([0x05, 0xff])
			.then(() {
				enforce(false, "Only accepts plaintext");
			});
		} else {
			return conn.write([0x05, 0x00]);
		}
	}).then(() => read.readStruct!socks5_client_connect)
	.then((connect) {
		enforce(connect.ver == 5);
		enforce(connect.command = 1);
		enforce(connect.reserver == 0);
		if (connect.addr_type == 1) {
			read.limit(4);
			return readOne(read.read())
			.then((ipv4) {
				addressRepeat = [cast(ubyte)1] ~ ipv4;
				return "%d.%d.%d.%d".format(ipv4[0], ipv4[1], ipv4[2], ipv4[3]);
			});
		} else if (connect.addr_type == 3) {
			return read.readStruct!ubyte()
			.then((len) {
				read.limit(len);
				return readOne(read.read())
				.then((data) {
					addressRepeat = [cast(ubyte)3, cast(ubyte)data.length] ~ data;
					return (cast(const(char)[])data).idup;
				});
			});
		} else {
			enforce(false, "Unsupported address type");
			assert(false);
		}
	}).then((addr) {
		read.limit(ushort.sizeof);
		return readOne(read.read())
		.then((portData) {
			addressRepeat ~= portData;
			return bigEndianToNative!ushort(portData[0..ushort.sizeof]);
		}).then((portNum) {
			Pipe cin = new Pipe(loop);
			Pipe cout = new Pipe(loop);

			return conn.write([0x05, 0x00, 0x00])
			.then(() => conn.write(addressRepeat.assumeUnique))
			.then(() {
				string port = portNum.to!string;
				subproc = subproc.map!(x => x.replace("%h", addr).replace("%p", port)).array;
			}).then(() {
				Process process = new Process(loop, subproc, cin, cout, Process.STDERR);
				read.limit();
				read.partialReceive(true);

				auto paral = forward(read.read(), cin);

				return forward(cout.read(), conn)
				.then(() => paral)
				.finall(() => process.kill())
				.then(() => process.wait());
			}).finall(() => cin.close())
			.finall(() => cout.close());
		});
	}).then(() => conn.shutdown())
	.finall(() => conn.close())
	.except((Exception e) {
		import std.stdio : stderr;
		stderr.writeln(e);
	});
}

int main(string[] args) {
	import std.conv : to;
	import std.stdio : stdin, stdout;
	
	auto loop = defaultLoop();
	const string listen_host = args[1];
	const ushort listen_port = args[2].to!ushort;
	string[] subproc = args[3..$];
	enforce(subproc.length > 0);

	loop.resolve(listen_host, listen_port)
	.then((addr) => loop.listenTcp(addr).each((conn) {
		handleConn(loop, conn, subproc);
	})).nothrow_();

	return loop.run();
}