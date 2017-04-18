module upromised.uv;
import deimos.libuv.uv;
import upromised.promise : Promise, PromiseIterator;
import std.format : format;
import upromised : fatal;

class UvError : Exception {
	import std.string : fromStringz;

	this(int code) nothrow {
		try {
			super("UV error (%s) %s".format(uv_strerror(code).fromStringz, code));
		} catch(Exception e) {
			fatal(e);
		}
	}
}

void uvCheck(int r) {
	if (r < 0) throw new UvError(r);
}

bool uvCheck(T)(int r, Promise!T t) nothrow {
    if (r < 0) {
        t.reject(new UvError(r));
        return true;
    }
    return false;
}

bool uvCheck(T)(int r, PromiseIterator!T t) nothrow {
    if (r < 0) {
        t.reject(new UvError(r));
        return true;
    }
    return false;
}

public uv_stream_t* stream(ref uv_tcp_t self) nothrow {
	return cast(uv_stream_t*)&self;
}
public uv_handle_t* handle(ref uv_tcp_t self) nothrow {
	return cast(uv_handle_t*)&self;
}

public uv_stream_t* stream(ref uv_tty_t self) nothrow {
	return cast(uv_stream_t*)&self;
}
public uv_handle_t* handle(ref uv_tty_t self) nothrow {
	return cast(uv_handle_t*)&self;
}

public uv_stream_t* stream(ref uv_pipe_t self) nothrow {
	return cast(uv_stream_t*)&self;
}
public uv_handle_t* handle(ref uv_pipe_t self) nothrow {
	return cast(uv_handle_t*)&self;
}

public uv_handle_t* handle(ref uv_process_t self) nothrow {
	return cast(uv_handle_t*)&self;
}