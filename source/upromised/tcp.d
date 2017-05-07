module upromised.tcp;
import upromised.stream : Stream;
import upromised.promise : DelegatePromise, DelegatePromiseIterator, PromiseIterator, Promise;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.uv : uvCheck, UvError;
import upromised.uv_stream : UvStream;
import upromised : fatal;
import std.exception : enforce;
import std.format : format;
import std.socket : Address;
import deimos.libuv.uv;
import deimos.libuv._d;

extern (C) void alloc_buffer(uv_handle_t*, size_t size, uv_buf_t* buf) {
	import core.stdc.stdlib : malloc;
	buf.base = cast(char *)malloc(size);
	buf.len = size;
}

private sockaddr* upcast(ref sockaddr_in self) nothrow {
    return cast(sockaddr*)&self;
}

class TcpSocket : UvStream!uv_tcp_t {
private:
	DelegatePromiseIterator!TcpSocket listenPromise;

public:
	this(uv_loop_t* ctx) {
		super(ctx);
		uv_tcp_init(ctx, &self).uvCheck();
	}

	void bind(Address[] addr) {
		import std.string : toStringz;

		enforce(addr.length > 0);
		uv_tcp_bind(&self, addr[0].name(), 0).uvCheck();
	}

	PromiseIterator!TcpSocket listen(int backlog) nothrow {
		import std.algorithm : swap;
		import upromised.uv : stream;

		assert(listenPromise is null);
		listenPromise = new DelegatePromiseIterator!TcpSocket;
		auto err = uv_listen(self.stream, backlog, (selfSelf, status) nothrow {
			Promise!void.resolved().then(() {
				auto self = getSelf!TcpSocket(selfSelf);
				enforce(status == 0);
				auto conn = new TcpSocket(self.ctx);
				uv_accept(self.self.stream, conn.self.stream).uvCheck();
				self.listenPromise.resolve(conn);
			}).except((Exception e) {
				auto self = getSelf!TcpSocket(selfSelf);
				DelegatePromiseIterator!TcpSocket failed;
				swap(failed, self.listenPromise);
				failed.reject(e);
			}).nothrow_();
		});
        if (err.uvCheck(listenPromise)) {
            DelegatePromiseIterator!TcpSocket r;
            swap(r, listenPromise);
            return r;
        }
		return listenPromise;
	}

	Promise!void connect(Address[] addr) nothrow {
		import std.string : toStringz;

		if (addr.length == 0) {
			return Promise!void.rejected(new Exception("Empty address info"));
		}

		ConnectPromise r = new ConnectPromise;
		r.addr = addr[0];
		gcretain(r);
		scope(failure) gcrelease(r);
		int err = uv_tcp_connect(&r.self, &self, r.addr.name(), (rSelf, status) nothrow {
			auto r = getSelf!ConnectPromise(rSelf);
			if (status == 0) {
				r.resolve();
			} else {
				r.reject(new UvError(status));
			}
		});
		err.uvCheck(r);
		r.finall(() => gcrelease(r));
		return r;
	}
	private class ConnectPromise : DelegatePromise!void {
		Address addr;
		uv_connect_t self;
	}
}