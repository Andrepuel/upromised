module upromised.manual_stream;
import upromised.stream : Stream;
import upromised.promise : Promise, PromiseIterator;

class ManualStream : Stream {
private:
    PromiseIterator!(const(ubyte)[]) read_;
    PromiseIterator!(const(ubyte)[]) write_;

public:
    this() {
        write_ = new PromiseIterator!(const(ubyte)[]);
    }

    override Promise!void close() nothrow {
        return Promise!void.resolved();
    }

    override Promise!void shutdown() nothrow {
        return Promise!void.resolved();
    }

    override PromiseIterator!(const(ubyte)[]) read() nothrow {
        assert(read_ is null);
        read_ = new PromiseIterator!(const(ubyte)[]);
        return read_;
    }

    Promise!bool writeToRead(const(ubyte)[] data) nothrow {
        return Promise!void.resolved().then(() {
            assert(read_ !is null);
            auto late = new Promise!bool;
            auto r = late.then((cont) {
                if (!cont) {
                    read_ = null;
                }
                return cont;
            });
            read_.resolve(data, late);
            return r;
        });
    }
    
    void writeToRead() nothrow {
        assert(read_ !is null);
        read_.resolve();
    }

    void writeToRead(Throwable e) nothrow {
        assert(read_ !is null);
        read_.reject(e);
    }

    override Promise!void write(immutable(ubyte)[] r) nothrow {
        return write_.resolve(r).then((_) {});
    }

    PromiseIterator!(const(ubyte)[]) readFromWrite() nothrow {
        return write_;
    }
}
unittest {
    auto a = new ManualStream;
    bool called = false;
    a.read().each((data) {
        assert((cast(const(ubyte)[])data) == "Hello world");
        called = true;
    });
    assert(!called);
    a.writeToRead(cast(immutable(ubyte)[])"Hello world");
    assert(called);
}
unittest {
    auto a = new ManualStream;
    auto delayed = new Promise!bool;
    bool called1, called2;
    
    a.write(cast(immutable(ubyte)[])"Hello world").then(() {
        called1 = true;
    });
    assert(!called1);
    a.readFromWrite.each((data) {
        assert(!called2);
        called2 = true;
        assert(cast(const(ubyte)[])data == "Hello world");
        return delayed;
    });
    assert(!called1);
    assert(called2);
    delayed.resolve(true);
    assert(called1);
}
unittest {
    auto a = new ManualStream;
    foreach(i; 0..2) {
        bool called = false;
        a.read().each((_) {
            assert(!called);
            called = true;
            return false;
        }).nothrow_();
        assert(!called);
        a.writeToRead(cast(const(ubyte)[])"sup");
        assert(called);
    }
}
unittest {
    auto a = new ManualStream;
    bool called = false;
    a.read().each((_) {
        assert(false);
    }).then((eof) {
        assert(eof);
        called = true;
    }).nothrow_();
    assert(!called);
    a.writeToRead();
    assert(called);
}