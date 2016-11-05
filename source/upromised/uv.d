module upromised.uv;
import upromised.promise : Promise, PromiseIterator;
import std.format : format;

class UvError : Exception {
	this(int code) {
		super("UV error code %s".format(-code));
	}
}

void uvCheck(int r) {
	if (r < 0) throw new UvError(r);
}

bool uvCheck(T)(int r, Promise!T t) {
    if (r < 0) {
        t.reject(new UvError(r));
        return true;
    }
    return false;
}

bool uvCheck(T)(int r, PromiseIterator!T t) {
    if (r < 0) {
        t.reject(new UvError(r));
        return true;
    }
    return false;
}