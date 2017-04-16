module upromised.stream;
import upromised.promise : Promise, PromiseIterator;
import upromised : fatal;

class Interrupted : Exception {
public:
	this() nothrow {
		super("Operation interrupted");
	}
}

interface Stream {
    Promise!void close() nothrow;
    Promise!void shutdown() nothrow;
    PromiseIterator!(const(ubyte)[]) read() nothrow;
    Promise!void write(immutable(ubyte)[]) nothrow;
}

abstract class ReadoneStream : Stream {
private:
    PromiseIterator!(const(ubyte)[]) read_;

public:
    PromiseIterator!(const(ubyte)[]) read() nothrow {
        if (read_ is null) {
            read_ = new PromiseIterator!(const(ubyte)[]);
            readOne();
        }
        return read_;
    }

    abstract override Promise!void close() nothrow;
    abstract override Promise!void shutdown() nothrow;
    abstract override Promise!void write(immutable(ubyte)[]) nothrow;

protected:
    abstract void readOne() nothrow;
    void readOneData(const(ubyte)[] data) nothrow {
        if (data.length == 0) {
            read_.resolve();
        } else {
            read_.resolve(data).then((_) {
                readOne();
            }).nothrow_();
        }
    }
    void rejectOneData(Exception e) nothrow {
        read_.reject(e);
    }
}