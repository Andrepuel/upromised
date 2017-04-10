module upromised.uv_stream;
import deimos.libuv.uv;
import deimos.libuv._d;
import std.exception : enforce;
import upromised.memory : gcrelease, gcretain, getSelf;
import upromised.promise : Promise, PromiseIterator;
import upromised.stream : Interrupted, Stream;
import upromised.uv : uvCheck, UvError;

class UvStream(SELF) : Stream {
private:
	Promise!void closePromise;
	PromiseIterator!(const(ubyte)[]) readPromise;

protected:
	uv_loop_t* ctx;

public:
	SELF self;

	this(uv_loop_t* ctx) {
		this.ctx = ctx;
		gcretain(this);
	}

	private extern (C) static void readAlloc(uv_handle_t* handle, size_t size, uv_buf_t* buf) nothrow {
		buf.base = cast(char*)(new ubyte[size]).ptr;
		gcretain(buf.base);
		buf.len = size;
	}
	
	private extern (C) static void readCb(uv_stream_t* selfSelf, long nread, inout(uv_buf_t)* buf) nothrow {
		import std.algorithm : swap;
		import upromised.uv : stream;

		auto self = getSelf!UvStream(selfSelf);
		if (nread == uv_errno_t.UV_EOF) {
			typeof(self.readPromise) gone;
			swap(gone, self.readPromise);
			gone.resolve();
			return;
		}

		if (buf.base !is null) gcrelease(buf.base);

		if (nread <= 0) {
			typeof(self.readPromise) gone;
			swap(gone, self.readPromise);
			gone.reject(new UvError(cast(int)nread));
			return;
		}
		
		uv_read_stop(self.self.stream);
		assert(self.readPromise !is null);
		self.readPromise.resolve(cast(ubyte[])buf.base[0..nread]).then((_) {
			uv_read_start(self.self.stream, &readAlloc, &readCb).uvCheck();
		}).except((Exception e) { 
			if (self.readPromise) {
				self.readPromise.reject(e);
			}
		}).nothrow_();
	}

	override PromiseIterator!(const(ubyte)[]) read() nothrow {
		import std.algorithm : swap;
		import upromised.uv : stream;

		if (readPromise is null) {
			readPromise = new PromiseIterator!(const(ubyte)[]);
			int err = uv_read_start(self.stream, &readAlloc, &readCb);
			if (err.uvCheck(readPromise)) {
				PromiseIterator!(const(ubyte)[]) r;
				swap(r, readPromise);
				return r;
			}
		}
		return readPromise;
	}

	override Promise!void write(immutable(ubyte)[] data) nothrow {
		import upromised.uv : stream;

		WritePromise r = new WritePromise;
		gcretain(r);
		r.data.base = cast(char*)data.ptr;
		r.data.len = data.length;
		int err = uv_write(&r.self, self.stream, &r.data, 1, (rSelf, status) nothrow {
			auto r = getSelf!WritePromise(rSelf);
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
	private class WritePromise : Promise!void {
		uv_write_t self;
		uv_buf_t data;
	}

	override Promise!void shutdown() nothrow {
		import upromised.uv : stream;

		ShutdownPromise r = new ShutdownPromise;
		gcretain(r);
		int err = uv_shutdown(&r.self, self.stream, (rSelf, status) nothrow {
			auto r = getSelf!ShutdownPromise(rSelf);
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
	private class ShutdownPromise : Promise!void {
		uv_shutdown_t self;
	}

	override Promise!void close() nothrow {
		import std.algorithm : swap;
		import upromised.uv : handle;

		if (closePromise) return closePromise;
		if (readPromise) {
			typeof(readPromise) gone;
			swap(gone, readPromise);
			gone.reject(new Interrupted);
		}

		closePromise = new Promise!void;
		uv_close(self.handle, (selfSelf) nothrow {
			auto self = getSelf!UvStream(selfSelf);
			self.closePromise.resolve();
			gcrelease(self);
		});
		return closePromise;
	}
}