import deimos.libuv.uv : uv_default_loop, uv_loop_t, uv_run, uv_run_mode;
import std.exception : enforce;
import std.format : format;
import upromised.dns : getAddrinfo;
import upromised.promise : Promise, PromiseIterator;
import upromised.stream : Stream;
import upromised.tcp : TcpSocket;
import upromised.tokenizer : Tokenizer;
import upromised.tty : TtyStream;

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
	ubyte ver = 5;
	ubyte command = 1;
	ubyte reserver = 0;
	ubyte addr_type = 3;
}
static assert(socks5_client_connect.sizeof == 4);

immutable(ubyte)[] socks5_client_connect_addr(const(char)[] addr, ushort port) {
	import std.bitmanip : nativeToBigEndian;
	import std.exception : assumeUnique;

	assert(addr.length <= 0xFF);

	ubyte[] r;
	r ~= cast(ubyte)addr.length;
	r ~= addr;
	r ~= port.nativeToBigEndian;
	return r.assumeUnique;
}

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

int main(string[] args) {
	import std.conv : to;
	import std.stdio : stdin, stdout;
	
	uv_loop_t* loop = uv_default_loop();
	
	const string socks5_host = args[1];
	const ushort socks5_port = args[2].to!ushort;
	const string dest_addr = args[3];
	const ushort dest_port = args[4].to!ushort;

	auto astdin = new TtyStream(loop, stdin);
	auto astdout = new TtyStream(loop, stdout);
	getAddrinfo(loop, socks5_host, socks5_port).then((remoteAddr) {
		auto a = new TcpSocket(loop);
		Tokenizer!(const(ubyte)) b;

		return a.connect(remoteAddr)
			.then(() {
				b = new Tokenizer!(const(ubyte))(a.read());
				return a.write(socks5_client_hello);
			}).then(() {
				return b.readStruct!socks5_server_hello;
			}).then((socks5_server_hello hello) {
				enforce(hello.ver == 5);
				enforce(hello.auth == 0);
				return a.write(serial(socks5_client_connect.init));
			}).then(() {
				return a.write(socks5_client_connect_addr(dest_addr, dest_port));
			}).then(() {
				return b.readStruct!socks5_server_connect;
			}).then((socks5_server_connect connect) {
				enforce(connect.ver == 5);
				enforce(connect.status == 0);
				if (connect.addr_type == 1) {
					b.limit(4);
				} else if (connect.addr_type == 4) {
					b.limit(16);
				} else {
					enforce(false, "unexpect addr type");
					assert(false);
				}
				return b.read().each((addr) {
					return false;
				}).then((bool) {});
			}).then(() {
				return b.readStruct!ushort;
			}).then((port) {
			}).then(() {
				b.limit();
				b.partialReceive(true);

				auto paralel = b.read().forward(astdout);
				return astdin.read().forward(a).then(() => paralel);
			}).finall(() => a.close());
	}).finall(() => astdin.close())
	.finall(() => astdout.close())
	.nothrow_();

	return uv_run(loop, uv_run_mode.UV_RUN_DEFAULT);
}