module upromised.loop;
import std.socket : Address;
import upromised.stream : DatagramStream, Stream;
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
	Promise!DatagramStream udp(Address addr = null) nothrow;
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

			Promise!TcpSocket socket = Promise!void.resolved()
			.then(() => new TcpSocket(loop))
			.then((socket) {
				socket.bind(dns);
				return socket;
			});
			Promise!(PromiseIterator!TcpSocket) listen = socket.then((s) => s.listen(128));

			auto r = new class PromiseIterator!Stream {
				override Promise!ItValue next(Promise!bool done) {
					done.then((cont) {
						if (!cont) {
							return socket.then((s) => s.close());
						}
						return Promise!void.resolved();
					}).nothrow_();

					return listen
					.then((self) => self.next(done))
					.then((eofConn) => ItValue(eofConn.eof, eofConn.value));
				}
			};
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

		override Promise!DatagramStream udp(Address addr) nothrow {
			import upromised.udp : UdpSocket;

			return Promise!void.resolved()
			.then(() => new UdpSocket(loop))
			.then((udp) {
				return Promise!void.resolved()
				.then(() {
					if (addr !is null) {
						udp.bind(addr);
					}
				}).except((Exception e) {
					return udp.close().then(() {
						throw e;
					});
				})
				.then(() => cast(DatagramStream)udp);
			});
		}
	};
}