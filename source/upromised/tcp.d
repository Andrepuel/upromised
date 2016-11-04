module upromised.tcp;
import upromised.promise : PromiseIterator, Promise;
import std.exception : enforce;
import std.format : format;
import deimos.libuv.uv;
import deimos.libuv._d;

void fatal(Throwable e = null, string file = __FILE__, ulong line = __LINE__) {
    import core.stdc.stdlib : abort;
    import std.stdio : stderr;
    stderr.writeln("%s(%s): Fatal error".format(file, line));
    if (e) {
        stderr.writeln(e);
    }
    abort();
}

class UvError : Exception {
	this(int code) {
		super("UV error code %s".format(-code));
	}
}

void uvCheck(int r) {
	if (r < 0) throw new UvError(r);
}

extern (C) void alloc_buffer(uv_handle_t*, size_t size, uv_buf_t* buf) {
	import core.stdc.stdlib : malloc;
	buf.base = cast(char *)malloc(size);
	buf.len = size;
}

void gcretain(T)(T a) {
	import core.memory : GC;
	GC.addRoot(cast(void*)a);
	GC.setAttr(cast(void*)a, GC.BlkAttr.NO_MOVE);
}

void gcrelease(T)(T a) {
	import core.memory : GC;
	GC.removeRoot(cast(void*)a);
    GC.clrAttr(cast(void*)a, GC.BlkAttr.NO_MOVE);
}

T getSelf(T,Y)(Y* a) {
	return cast(T)((cast(void*)a) - T.self.offsetof);
}
class TcpSocket {
private:
	uv_loop_t* ctx;
	uv_tcp_t self;
	Promise!void closePromise;
	PromiseIterator!TcpSocket listenPromise;
	PromiseIterator!(const(ubyte)[]) readPromise;

public:
	this(uv_loop_t* ctx) {
		this.ctx = ctx;
		uv_tcp_init(ctx, &self).uvCheck();
		gcretain(this);
	}

	Promise!void close() {
		assert(closePromise is null);
		closePromise = new Promise!void;
		scope(failure) closePromise = null;
		uv_close(cast(uv_handle_t*)&self, (selfSelf) {
			auto self = getSelf!TcpSocket(selfSelf);
			self.closePromise.resolve();
			gcrelease(self);
		});
		return closePromise;
	}

	void bind(const(char)[] addrStr, ushort port) {
		import std.string : toStringz;

		sockaddr_in addr;
		uv_ip4_addr(addrStr.toStringz, port, &addr).uvCheck();
		uv_tcp_bind(&self, cast(sockaddr*)&addr, 0).uvCheck();
	}

	PromiseIterator!TcpSocket listen(int backlog) {
		assert(listenPromise is null);
		listenPromise = new PromiseIterator!TcpSocket;
		uv_listen(cast(uv_stream_t*)&self, backlog, (selfSelf, status) {
			enforce(status == 0);
			auto self = getSelf!TcpSocket(selfSelf);
			auto conn = new TcpSocket(self.ctx);
			uv_accept(cast(uv_stream_t*)&self.self, cast(uv_stream_t*)&conn.self).uvCheck();
			self.listenPromise.resolve(conn);
		}).uvCheck();
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
        uv_read_stop(cast(uv_stream_t*)&self.self);
        self.readPromise.resolve(cast(ubyte[])buf.base[0..nread]).then((cont) {
            if (cont) {
                uv_read_start(cast(uv_stream_t*)&self.self, &readAlloc, &readCb).uvCheck();
            } else {
                scope(failure) fatal();
                self.readPromise = null;
            }
        }).except((Throwable e) { self.readPromise.reject(e); });
    }
	PromiseIterator!(const(ubyte)[]) read() {
		assert(readPromise is null);
		readPromise = new PromiseIterator!(const(ubyte)[]);
		uv_read_start(cast(uv_stream_t*)&self, &readAlloc, &readCb).uvCheck();
		return readPromise;
	}

	Promise!void write(immutable(ubyte)[] data) {
		WritePromise r = new WritePromise;
		gcretain(r);
		scope(failure) gcrelease(r);
		r.data.base = cast(char*)data.ptr;
		r.data.len = data.length;
		uv_write(&r.self, cast(uv_stream_t*)&self, &r.data, 1, (rSelf, status) {
			auto r = getSelf!WritePromise(rSelf);
			gcrelease(r);
			enforce(status == 0);
			r.resolve();
		}).uvCheck();
		return r;
	}
	class WritePromise : Promise!void {
		uv_write_t self;
		uv_buf_t data;
	}

	Promise!void shutdown() {
		ShutdownPromise r = new ShutdownPromise;
		gcretain(r);
		scope(failure) gcrelease(r);
		uv_shutdown(&r.self, cast(uv_stream_t*)&self, (rSelf, status) {
			auto r = getSelf!ShutdownPromise(rSelf);
			gcrelease(r);
			enforce(status == 0);
			r.resolve();
		}).uvCheck();
		return r;
	}
	class ShutdownPromise : Promise!void {
		uv_shutdown_t self;
	}

	Promise!void connect(string addrStr, ushort port) {
		import std.string : toStringz;

		sockaddr_in addr;
		uv_ip4_addr(addrStr.toStringz, port, &addr).uvCheck();

		ConnectPromise r = new ConnectPromise;
		gcretain(r);
		scope(failure) gcrelease(r);
		uv_tcp_connect(&r.self, &self, cast(sockaddr*)&addr, (rSelf, status) {
			auto r = getSelf!ConnectPromise(rSelf);
			gcrelease(r);
			enforce(status == 0);
			r.resolve();
		});
		return r;
	}
	class ConnectPromise : Promise!void {
		uv_connect_t self;
	}
}