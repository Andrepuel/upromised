module upromised.loop;
import std.socket : Address;
import upromised.stream : Stream;
import upromised.promise : Promise, PromiseIterator;

struct TlsContext {
	private Object self;
}

interface Loop {
	Promise!(Address[]) resolve(const(char)[] hostname, ushort port) nothrow;
	Promise!Stream connectTcp(Address[] dns) nothrow;
	PromiseIterator!Stream listenTcp(Address[] dns) nothrow;
	string defaultCertificatesPath() nothrow;
	Promise!TlsContext context(string certificatesPath = null) nothrow;
	Promise!Stream tlsHandshake(Stream stream, TlsContext context, string hostname = null) nothrow;
	void* inner() nothrow;
	int run();
}

Loop defaultLoop() {
	import deimos.libuv.uv : uv_default_loop, uv_loop_t;
	uv_loop_t* loop = uv_default_loop();
	return new class Loop {
		override void* inner() nothrow {
			return loop;
		}

		override int run() {
			import deimos.libuv.uv : uv_run, uv_run_mode;

			return uv_run(loop, uv_run_mode.UV_RUN_DEFAULT);
		}

		override Promise!(Address[]) resolve(const(char)[] hostname, ushort port) nothrow {
			import upromised.dns : getAddrinfo;

			return getAddrinfo(loop, hostname, port);
		}

		override Promise!Stream connectTcp(Address[] dns) nothrow {
			import upromised.tcp : TcpSocket;

			return Promise!void.resolved()
				.then(() => new TcpSocket(loop))
				.then((socket) {
					return socket
						.connect(dns)
						.except((Exception e) {
							return socket.close().then(() {
								throw e;
							});
						})
						.then!Stream(() => socket);
				});
		}

		override PromiseIterator!Stream listenTcp(Address[] dns) nothrow {
			import upromised.tcp : TcpSocket;

			PromiseIterator!Stream r = new PromiseIterator!Stream;
			Promise!void.resolved()
				.then(() => new TcpSocket(loop))
				.then((socket) {
					return Promise!void.resolved().then(() => socket.bind(dns))
						.then(() => socket.listen(128).each((conn) {
							return r.resolve(conn);
						}))
						.finall(() => socket.close())
						.except((Exception e) {
							r.reject(e);
						});
				});

			return r;
		}

		override string defaultCertificatesPath() nothrow {
			version(hasOpenssl) {
					import std.algorithm : filter;
					import std.file : exists;

					auto tries = [
						"/etc/ssl/ca-bundle.pem",
						"/etc/ssl/certs/ca-certificates.crt",
						"/etc/pki/tls/certs/ca-bundle.crt",
						"/usr/local/etc/openssl/cert.pem",
					].filter!(x => x.exists);

					if (tries.empty) {
						return null;
					}

					return tries.front;
			} else {
				return null;
			}
		}

		override Promise!TlsContext context(string certificatesPath = null) nothrow {
			version(hasOpenssl) {
				import upromised.tls : OpensslTlsContext =  TlsContext;

				return Promise!void.resolved()
					.then(() => new OpensslTlsContext)
					.then((r) {
						if (certificatesPath) {
							r.load_verify_locations(certificatesPath);
						}

						return TlsContext(r);
					});
			} else version(hasSecurity) {
				return Promise!TlsContext.resolved(TlsContext.init);
			} else {
				auto r = new Promise!TlsContext;
				r.reject(new Exception("TLS not supported"));
				return r;
			}
		}

		override Promise!Stream tlsHandshake(Stream stream, TlsContext contextUntyped, string hostname) nothrow {
			version(hasOpenssl) {
				import upromised.tls : OpensslTlsContext =  TlsContext, TlsStream;

				OpensslTlsContext context = cast(OpensslTlsContext)(contextUntyped.self);
				return Promise!void.resolved()
					.then(() => new TlsStream(stream, context))
					.then((r) {
						return r
							.connect(hostname)
							.then!Stream(() => r);
					});
			} else version(hasSecurity) {
				import upromised.security : TlsStream;
				return Promise!void.resolved()
					.then(() => new TlsStream(stream))
					.then((r) {
						return r
							.connect(hostname)
							.then!Stream(() => r);
					});
			} else {
				auto r = new Promise!Stream;
				r.reject(new Exception("TLS not supported"));
				return r;
			}
		}
	};
}