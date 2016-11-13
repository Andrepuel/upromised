import std.stdio;
import upromised.tcp : TcpSocket;
import upromised.stream : Stream;
import upromised.dns : getAddrinfo;
import deimos.libuv.uv : uv_loop_t, uv_default_loop, uv_run, uv_run_mode;
import upromised : fatal;
import upromised.promise : Promise;

Promise!void forward(Stream from, Stream to) {
	return from.read().each((data) => to.write(data.idup)).then((_) => to.shutdown());
}

Promise!void forwardBoth(Stream a, Stream b) {
	Promise!void second = a.forward(b);
	return b.forward(a).then(() => second);
}

int main() {
	import upromised.tls;
	uv_loop_t* loop = uv_default_loop();
	auto tlsCtx = new TlsContext();

	getAddrinfo(loop, "www.google.com.br", 443).then((remoteAddr) => getAddrinfo(loop, "0.0.0.0", "8443").then((localAddr) {
		auto a = new TcpSocket(loop);
		a.bind(localAddr);
		return a.listen(128).each((clientSide) {
			Promise!void.resolved().then(() {
				auto serverSideUnderlying = new TcpSocket(loop);
				return serverSideUnderlying.connect(remoteAddr).then(() => new TlsStream(serverSideUnderlying, tlsCtx)).then((serverSide) {
					return Promise!void.resolved().then(() => serverSide.connect()).then(() {
						return forwardBoth(clientSide, serverSide);
					}).finall(() => serverSide.close());
				});
			}).finall(() => clientSide.close())
			.except((Exception e) => stderr.writeln(e))
			.nothrow_();
		}).finall(() => a.close());
	}))nothrow_();

	return uv_run(loop, uv_run_mode.UV_RUN_DEFAULT);
}