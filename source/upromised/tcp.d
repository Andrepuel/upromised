module upromised.tcp;
import upromised.stream : Stream;
import upromised.promise : PromiseIterator, Promise;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.uv : uvCheck, UvError;
import upromised.uv_stream : UvStream;
import upromised : fatal;
import upromised.dns : Addrinfo;
import std.exception : enforce;
import std.format : format;
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
	PromiseIterator!TcpSocket listenPromise;

public:
	this(uv_loop_t* ctx) {
		super(ctx);
		uv_tcp_init(ctx, &self).uvCheck();
	}

	void bind(Addrinfo addrinfo) {
		import std.string : toStringz;

		auto addr = addrinfo.get();
		enforce(addr.length > 0);
		uv_tcp_bind(&self, addr[0].ai_addr, 0).uvCheck();
	}

	PromiseIterator!TcpSocket listen(int backlog) nothrow {
        import std.algorithm : swap;
		import upromised.uv : stream;

		assert(listenPromise is null);
		listenPromise = new PromiseIterator!TcpSocket;
		auto err = uv_listen(self.stream, backlog, (selfSelf, status) nothrow {
			Promise!void.resolved().then(() {
				auto self = getSelf!TcpSocket(selfSelf);
				enforce(status == 0);
				auto conn = new TcpSocket(self.ctx);
				uv_accept(self.self.stream, conn.self.stream).uvCheck();
				self.listenPromise.resolve(conn);
			}).except((Exception e) {
				auto self = getSelf!TcpSocket(selfSelf);
				PromiseIterator!TcpSocket failed;
				swap(failed, self.listenPromise);
				failed.reject(e);
			}).nothrow_();
		});
        if (err.uvCheck(listenPromise)) {
            PromiseIterator!TcpSocket r;
            swap(r, listenPromise);
            return r;
        }
		return listenPromise;
	}

	Promise!void connect(Addrinfo addrinfo) nothrow {
		import std.string : toStringz;

		auto addr = addrinfo.get();
		if (addr.length == 0) {
			return Promise!void.rejected(new Exception("Empty address info"));
		}

		ConnectPromise r = new ConnectPromise;
		gcretain(r);
		scope(failure) gcrelease(r);
		int err = uv_tcp_connect(&r.self, &self, addr[0].ai_addr, (rSelf, status) nothrow {
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
	private class ConnectPromise : Promise!void {
		uv_connect_t self;
	}
}