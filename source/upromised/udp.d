module upromised.udp;
import deimos.libuv.uv : uv_buf_t, uv_loop_t, uv_udp_t;
import std.exception : enforce;
import std.socket : Address;
import upromised.memory : gcrelease, gcretain, getSelf;
import upromised.promise : DelegatePromise, Promise, PromiseIterator;
import upromised.stream : Datagram, DatagramStream, Interrupted;
import upromised.uv : uvCheck, UvError;

class UdpSocket : DatagramStream {
private:
	DelegatePromise!void closePromise;
	DelegatePromise!Datagram readPromise;

public:
	uv_udp_t self;

	this(uv_loop_t* loop) {
		import deimos.libuv.uv : uv_udp_init;

		uv_udp_init(loop, &self).uvCheck();
		gcretain(this);
	}

	void bind(Address addr) {
		import deimos.libuv.uv : uv_udp_bind;

		uv_udp_bind(&self, addr.name, 0).uvCheck();
	}

	override Promise!void sendTo(Address dest, immutable(ubyte)[] message) nothrow {
		import deimos.libuv.uv : uv_udp_send;

		SendPromise r = new SendPromise;
		gcretain(r);
		r.finall(() => gcrelease(r));
		r.dest = dest;
		r.data.base = cast(char*)message.ptr;
		r.data.len = message.length;

		int rc = uv_udp_send(&r.self, &self, &r.data, 1, r.dest.name(), (selfArg, int status) nothrow {
			SendPromise self = selfArg.getSelf!SendPromise;
			if (status == 0) {
				self.resolve();
			} else {
				self.reject(new UvError(status));
			}
		});
		rc.uvCheck(r);

		return r;
	}

	private class SendPromise : DelegatePromise!void {
		import deimos.libuv.uv : uv_udp_send_t;

		Address dest;
		uv_udp_send_t self;
		uv_buf_t data;
	}

	override PromiseIterator!Datagram recvFrom() nothrow {
		import std.algorithm : swap;
		import deimos.libuv.uv : uv_udp_recv_stop, uv_udp_recv_start;
		import upromised.dns : toAddress;
		import upromised.uv_stream : readAlloc, shrinkBuf;

		return new class PromiseIterator!Datagram {
			override Promise!ItValue next(Promise!bool) {
				if (closePromise !is null) {
					return Promise!ItValue.resolved(ItValue(true));
				}


				enforce(readPromise is null, "Already reading");
				readPromise = new DelegatePromise!Datagram;
				uv_udp_recv_start(&self, &readAlloc, (selfArg, nread, buf, addr, flags) nothrow {
					auto self = selfArg.getSelf!UdpSocket;

					if (nread == 0 && addr is null) {
						return;
					}

					uv_udp_recv_stop(&self.self);

					if (buf.base !is null) gcrelease(buf.base);

					if (self.readPromise is null) {
						return;
					}

					if (nread < 0) {
						self.readPromise.reject(new UvError(cast(int)nread));
						return;
					}

					auto base = shrinkBuf(buf, nread);
					self.readPromise.resolve(Datagram(addr.toAddress, cast(const(ubyte)[])base));
				}).uvCheck(readPromise);
				
				return readPromise.finall(() {
					readPromise = null;
				}).then((datagram) => datagram.addr is null ? ItValue(true) : ItValue(false, datagram));
			}
		};
	}

	override Promise!void close() nothrow {
		import deimos.libuv.uv : uv_close;
		import upromised.uv : handle;

		if (closePromise) return closePromise;
		if (readPromise) {
			readPromise.reject(new Interrupted);
		}

		closePromise = new DelegatePromise!void;
		uv_close(self.handle, (selfArg) nothrow {
			auto self = selfArg.getSelf!UdpSocket;
			self.closePromise.resolve();
			gcrelease(self);
		});
		return closePromise;
	}
}