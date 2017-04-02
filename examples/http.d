import std.stdio : writeln;
import upromised.http : Client, Header, Method;
import upromised.loop : defaultLoop;
import upromised.promise : Promise;

int main(string[] args) {
	string hostname = args[1];
	auto loop = defaultLoop();
	loop.context(loop.defaultCertificatesPath()).then((tlsctx) {
		return loop.resolve(hostname, 443)
		.then((addr) => loop.connectTcp(addr))
		.then((socket) {
			return loop.tlsHandshake(socket, tlsctx, hostname).then((tls) {
				return Promise!Client.resolved(new Client(tls))
				.then((http) {
					return http.sendRequest(Method.GET, "/")
						.then(() => http.sendHeaders([Header("Host", hostname)]))
						.then(() => http.sendBody())
						.then(() => http.fetchResponse())
						.then((response) => writeln(response))
						.then(() => http.fetchHeaders().each((x) => writeln(x)))
						.then((_) => http.fetchBody().each((x) => writeln([cast(const(char)[])x])));
				})
				.then((_) => tls.shutdown())
				.finall(() => tls.close());
			})
			.then(() => socket.shutdown())
			.finall(() => socket.close());
		});
	}).nothrow_();

	return loop.run();
}