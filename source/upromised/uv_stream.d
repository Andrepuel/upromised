module upromised.uv_stream;
import deimos.libuv.uv;
import deimos.libuv._d;
import std.exception : enforce;
import upromised.memory : gcrelease, gcretain, getSelf;
import upromised.promise : DelegatePromise, Promise, PromiseIterator;
import upromised.stream : Interrupted, Stream;
import upromised.uv : uvCheck, UvError;

extern (C) static void readAlloc(uv_handle_t* handle, size_t size, uv_buf_t* buf) nothrow {
	import core.memory : GC;

	version(ARM_HardFloat) {
		// Using GC.malloc causes memory leak on LDC2 for ArmHF.
		// The reason is unknown.
		buf.base = (new char[size]).ptr;
	} else {
		buf.base = cast(char*)GC.malloc(size);
	}
	gcretain(buf.base);
	buf.len = size;
}

const(char)[] shrinkBuf(const(uv_buf_t)* buf, size_t len) nothrow {
	import core.memory : GC;
	version(ARM_HardFloat) {
		auto r = new char[len];
		r[0..len] = buf.base[0..len];
	} else {
		auto r = cast(const(char)*)GC.realloc(cast(void*)buf.base, len);
	}
	return r[0..len];
}

class UvStream(SELF) : Stream {
private:
	DelegatePromise!void closePromise;
	DelegatePromise!(const(ubyte)[]) readPromise;

protected:
	uv_loop_t* ctx;

public:
	SELF self;

	this(uv_loop_t* ctx) {
		this.ctx = ctx;
		gcretain(this);
	}
	
	private extern (C) static void readCb(uv_stream_t* selfSelf, long nread, inout(uv_buf_t)* buf) nothrow {
		import std.algorithm : swap;
		import upromised.uv : stream;

		auto self = getSelf!UvStream(selfSelf);
		if (buf.base !is null) gcrelease(buf.base);
		uv_read_stop(self.self.stream);
		
		if (nread == uv_errno_t.UV_EOF) {
			self.readPromise.resolve(null);
			return;
		}

		if (nread <= 0) {
			self.readPromise.reject(new UvError(cast(int)nread));
			return;
		}

		auto base = shrinkBuf(buf, nread);
		self.readPromise.resolve(cast(ubyte[])base);
	}

	override PromiseIterator!(const(ubyte)[]) read() nothrow {
		import std.algorithm : swap;
		import upromised.uv : stream;

		return new class PromiseIterator!(const(ubyte)[]) {
			override Promise!ItValue next(Promise!bool) {
				enforce(readPromise is null, "Already reading");
				readPromise = new DelegatePromise!(const(ubyte)[]);

				uv_read_start(self.stream, &readAlloc, &readCb).uvCheck(readPromise);
				return readPromise.finall(() {
					readPromise = null;
				}).then((chunk) => chunk ? ItValue(false, chunk) : ItValue(true));
			}
		};
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
	private class WritePromise : DelegatePromise!void {
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
	private class ShutdownPromise : DelegatePromise!void {
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

		closePromise = new DelegatePromise!void;
		uv_close(self.handle, (selfSelf) nothrow {
			auto self = getSelf!UvStream(selfSelf);
			self.closePromise.resolve();
			gcrelease(self);
		});
		return closePromise;
	}
}