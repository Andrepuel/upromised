module upromised.stream;
import upromised.promise : Promise, PromiseIterator;
import upromised : fatal;

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
        assert(read_ is null);
        read_ = new PromiseIterator!(const(ubyte)[]);
        auto r = read_;
        readOne();
        return r;
    }

    abstract override Promise!void close() nothrow;
    abstract override Promise!void shutdown() nothrow;
    abstract override Promise!void write(immutable(ubyte)[]) nothrow;

protected:
    abstract void readOne() nothrow;
    void readOneData(const(ubyte)[] data) nothrow {
        import std.algorithm : swap;

        if (data.length == 0) {
            PromiseIterator!(const(ubyte)[]) oldRead;
            swap(read_, oldRead);
            oldRead.resolve();
        } else {
            auto late = new Promise!bool;
            late.then((cont) {
                if (cont) {
                    readOne();
                } else {
                    read_ = null;
                }
            }).nothrow_();
            read_.resolve(data, late);
        }
    }
    void rejectOneData(Throwable e) nothrow {
        import std.algorithm : swap;

        PromiseIterator!(const(ubyte)[]) oldRead;
        swap(read_, oldRead);
        oldRead.reject(e);
    }
}