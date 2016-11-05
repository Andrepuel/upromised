module upromised.uv;
import upromised.promise : Promise, PromiseIterator;
import std.format : format;
import upromised : fatal;

class UvError : Exception {
	this(int code) nothrow {
        try {
            super("UV error code %s".format(-code));
        } catch(Throwable e) {
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