module upromised.udp;
import deimos.libuv.uv : uv_buf_t, uv_loop_t, uv_udp_t;
import std.socket : Address;
import upromised.memory : gcrelease, gcretain, getSelf;
import upromised.promise : Promise, PromiseIterator;
import upromised.stream : Datagram, DatagramStream, Interrupted;
import upromised.uv : uvCheck, UvError;

class UdpSocket : DatagramStream {
private:
	Promise!void closePromise;
	PromiseIterator!Datagram readPromise;

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

	private class SendPromise : Promise!void {
		import deimos.libuv.uv : uv_udp_send_t;

		Address dest;
		uv_udp_send_t self;
		uv_buf_t data;
	}

	override PromiseIterator!Datagram recvFrom() nothrow {
		import std.algorithm : swap;

		if (readPromise is null) {
			readPromise = new PromiseIterator!Datagram;
			int err = readOne();
			if (err.uvCheck(readPromise)) {
				PromiseIterator!Datagram empty;
				swap(empty, readPromise);
				return empty;
			}
		}
		return readPromise;
	}
	private int readOne() nothrow {
		import deimos.libuv.uv : uv_udp_recv_stop, uv_udp_recv_start;
		import std.algorithm : swap;
		import upromised.dns : toAddress;
		import upromised.uv_stream : readAlloc, shrinkBuf;

		return uv_udp_recv_start(&self, &readAlloc, (selfArg, nread, buf, addr, flags) nothrow {
			auto self = selfArg.getSelf!UdpSocket;

			if (buf.base !is null) gcrelease(buf.base);

			if (addr == null) {
				return;
			}

			if (nread < 0) {
				typeof(self.readPromise) gone;
				swap(gone, self.readPromise);
				gone.reject(new UvError(cast(int)nread));
				return;
			}


			auto base = shrinkBuf(buf, nread);
			uv_udp_recv_stop(&self.self);
			self.readPromise.resolve(Datagram(addr.toAddress, cast(ubyte[])base)).then((cont) {
				if (cont) {
					self.readOne().uvCheck();
				}
			}).except((Exception e) { 
				if (self.readPromise) {
					self.readPromise.reject(e);
				}
			}).nothrow_();
		});
	}

	override Promise!void close() nothrow {
		import deimos.libuv.uv : uv_close;
		import upromised.uv : handle;

		if (closePromise) return closePromise;
		if (readPromise) {
			readPromise.reject(new Interrupted);
		}

		closePromise = new Promise!void;
		uv_close(self.handle, (selfArg) nothrow {
			auto self = selfArg.getSelf!UdpSocket;
			self.closePromise.resolve();
			gcrelease(self);
		});
		return closePromise;
	}
}