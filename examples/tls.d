import std.stdio : writeln;
import upromised.loop : defaultLoop;

inout(U)[] as(U, T)(inout(T)[] a1) {
	return cast(inout(U)[])a1;
}

string ca_list_location() {
	import std.algorithm : filter;
	import std.file : exists;

	return [
		"/usr/local/etc/openssl/cert.pem", 
		"/etc/ssl/certs/ca-certificates.crt",
		"/etc/pki/tls/certs/ca-bundle.crt",
		"/etc/ssl/ca-bundle.pem"
	].filter!(x => x.exists).front;
}

int main(string[] args) {
	import std.conv : to;

	string hostname = args[1];
	ushort port = args[2].to!ushort;

	auto loop = defaultLoop();
	loop.context(ca_list_location).then((tlsctx) {
		return loop.resolve(hostname, port).then((addr) {
			return loop.connectTcp(addr).then((socket) {
				return loop.tlsHandshake(socket, tlsctx, hostname)
					.then((tls) {
						return tls.write(("GET / HTTP/1.1\r\nHost: " ~ hostname ~ "\r\n\r\n").as!ubyte)
							.then(() => tls.read().each((chunk) {
								writeln([chunk.as!char]);
							}))
							.then((_) => tls.shutdown())
							.finall(() => tls.close());
					})
					.then(() => socket.shutdown())
					.finall(() => socket.close());
			});
		});
	}).nothrow_();
	return loop.run();
}