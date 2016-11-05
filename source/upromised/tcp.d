module upromised.tcp;
import upromised.promise : PromiseIterator, Promise;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.uv : uvCheck;
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

private uv_stream_t* stream(ref uv_tcp_t self) {
    return cast(uv_stream_t*)&self;
}
private uv_handle_t* handle(ref uv_tcp_t self) {
    return cast(uv_handle_t*)&self;
}
private sockaddr* upcast(ref sockaddr_in self) {
    return cast(sockaddr*)&self;
}

class TcpSocket {
private:
	uv_loop_t* ctx;
	Promise!void closePromise;
	PromiseIterator!TcpSocket listenPromise;
	PromiseIterator!(const(ubyte)[]) readPromise;

public:
	uv_tcp_t self;

	this(uv_loop_t* ctx) {
		this.ctx = ctx;
		uv_tcp_init(ctx, &self).uvCheck();
		gcretain(this);
	}

	Promise!void close() {
		assert(closePromise is null);
		closePromise = new Promise!void;
		scope(failure) closePromise = null;
		uv_close(self.handle, (selfSelf) {
			auto self = getSelf!TcpSocket(selfSelf);
			self.closePromise.resolve();
			gcrelease(self);
		});
		return closePromise;
	}

	void bind(Addrinfo addrinfo) {
		import std.string : toStringz;

		auto addr = addrinfo.get();
		enforce(addr.length > 0);
		uv_tcp_bind(&self, addr[0].ai_addr, 0).uvCheck();
	}

	PromiseIterator!TcpSocket listen(int backlog) {
        import std.algorithm : swap;

		assert(listenPromise is null);
		listenPromise = new PromiseIterator!TcpSocket;
		auto err = uv_listen(self.stream, backlog, (selfSelf, status) {
			enforce(status == 0);
			auto self = getSelf!TcpSocket(selfSelf);
			auto conn = new TcpSocket(self.ctx);
			uv_accept(self.self.stream, conn.self.stream).uvCheck();
			self.listenPromise.resolve(conn);
		});
        if (err.uvCheck(listenPromise)) {
            PromiseIterator!TcpSocket r;
            swap(r, listenPromise);
            return r;
        }
		return listenPromise;
	}

    private extern (C) static void readAlloc(uv_handle_t* handle, size_t size, uv_buf_t* buf) {
        buf.base = cast(char*)(new ubyte[size]).ptr;
        gcretain(buf.base);
        buf.len = size;
    }
    private extern (C) static void readCb(uv_stream_t* selfSelf, long nread, inout(uv_buf_t)* buf) {
        auto self = getSelf!TcpSocket(selfSelf);
        if (nread == uv_errno_t.UV_EOF) {
            self.readPromise.resolve();
            return;
        }
        if (buf.base !is null) gcrelease(buf.base);
        enforce(nread >= 0);
        uv_read_stop(self.self.stream);
        self.readPromise.resolve(cast(ubyte[])buf.base[0..nread]).then((cont) {
            if (cont) {
                uv_read_start(self.self.stream, &readAlloc, &readCb).uvCheck();
            } else {
                scope(failure) fatal();
                self.readPromise = null;
            }
        }).except((Throwable e) { self.readPromise.reject(e); });
    }
	PromiseIterator!(const(ubyte)[]) read() {
		import std.algorithm : swap;

		assert(readPromise is null);
		readPromise = new PromiseIterator!(const(ubyte)[]);
		int err = uv_read_start(self.stream, &readAlloc, &readCb);
		if (err.uvCheck(readPromise)) {
			PromiseIterator!(const(ubyte)[]) r;
			swap(r, readPromise);
			return r;
		}
		return readPromise;
	}

	Promise!void write(immutable(ubyte)[] data) {
		WritePromise r = new WritePromise;
		gcretain(r);
		r.data.base = cast(char*)data.ptr;
		r.data.len = data.length;
		int err = uv_write(&r.self, self.stream, &r.data, 1, (rSelf, status) {
			auto r = getSelf!WritePromise(rSelf);
			enforce(status == 0);
			r.resolve();
		});
		err.uvCheck(r);
		r.finall(() => gcrelease(r));
		return r;
	}
	class WritePromise : Promise!void {
		uv_write_t self;
		uv_buf_t data;
	}

	Promise!void shutdown() {
		ShutdownPromise r = new ShutdownPromise;
		gcretain(r);
		int err = uv_shutdown(&r.self, self.stream, (rSelf, status) {
			auto r = getSelf!ShutdownPromise(rSelf);
			enforce(status == 0);
			r.resolve();
		});
		err.uvCheck(r);
		r.finall(() => gcrelease(r));
		return r;
	}
	class ShutdownPromise : Promise!void {
		uv_shutdown_t self;
	}

	Promise!void connect(Addrinfo addrinfo) {
		import std.string : toStringz;

		auto addr = addrinfo.get();
		if (addr.length == 0) {
			return Promise!void.rejected(new Exception("Empty address info"));
		}

		ConnectPromise r = new ConnectPromise;
		gcretain(r);
		scope(failure) gcrelease(r);
		int err = uv_tcp_connect(&r.self, &self, addr[0].ai_addr, (rSelf, status) {
			auto r = getSelf!ConnectPromise(rSelf);
			enforce(status == 0);
			r.resolve();
		});
		err.uvCheck(r);
		r.finall(() => gcrelease(r));
		return r;
	}
	class ConnectPromise : Promise!void {
		uv_connect_t self;
	}
}