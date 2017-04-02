module upromised.loop;
import upromised.stream : Stream;
import upromised.promise : Promise;

struct Address {
	private Object self;
}

struct TlsContext {
	private Object self;
}

interface Loop {
	Promise!Address resolve(const(char)[] hostname, ushort port) nothrow;
	Promise!Stream connectTcp(Address dns) nothrow;
	Promise!TlsContext context(string certificatesPath = null) nothrow;
	Promise!Stream tlsHandshake(Stream stream, TlsContext context, string hostname = null) nothrow;
	int run();
}

Loop defaultLoop() {
	import deimos.libuv.uv : uv_default_loop, uv_loop_t;
	uv_loop_t* loop = uv_default_loop();
	return new class Loop {
		int run() {
			import deimos.libuv.uv : uv_run, uv_run_mode;

			return uv_run(loop, uv_run_mode.UV_RUN_DEFAULT);
		}

		override Promise!Address resolve(const(char)[] hostname, ushort port) nothrow {
			import upromised.dns : getAddrinfo;

			return getAddrinfo(loop, hostname, port).then((addr) => Address(addr));
		}

		override Promise!Stream connectTcp(Address dns) nothrow {
			import upromised.dns : Addrinfo;
			import upromised.tcp : TcpSocket;

			return Promise!void.resolved()
				.then(() => new TcpSocket(loop))
				.then((socket) {
					return socket
						.connect(cast(Addrinfo)dns.self)
						.except((Exception e) {
							return socket.close().then(() {
								throw e;
							});
						})
						.then!Stream(() => socket);
				});
		}

		override Promise!TlsContext context(string certificatesPath = null) nothrow {
			import upromised.tls : OpensslTlsContext =  TlsContext;

			return Promise!void.resolved()
				.then(() => new OpensslTlsContext)
				.then((r) {
					if (certificatesPath) {
						r.load_verify_locations(certificatesPath);
					}

					return TlsContext(r);
				});
		}

		override Promise!Stream tlsHandshake(Stream stream, TlsContext contextUntyped, string hostname) nothrow {
			import upromised.tls : OpensslTlsContext =  TlsContext, TlsStream;

			OpensslTlsContext context = cast(OpensslTlsContext)(contextUntyped.self);
			return Promise!void.resolved()
				.then(() => new TlsStream(stream, context))
				.then((r) {
					return r
						.connect(hostname)
						.then!Stream(() => r);
				});
		}
	};
}