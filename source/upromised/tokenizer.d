module upromised.tokenizer;
import upromised.stream : ReadoneStream, Stream;
import upromised.promise : Promise, PromiseIterator;
import upromised : fatal;
version (unittest) {
    import upromised.manual_stream : ManualStream;
}

private ptrdiff_t countUntilPartial(const(ubyte)[] input, const(ubyte)[] search) nothrow {
    import std.algorithm : startsWith, min;

    foreach(pos; 0..input.length) {
        if (search.startsWith(input[pos..$.min(pos + search.length)])) return pos;
    }
    return -1;
}

class Tokenizer : ReadoneStream {
private:
    Stream underlying;
    bool underlyingEof;
    immutable(ubyte)[] separator_;
    ubyte[] buffer;
    size_t limit_;
    bool partialReceive_;

public:
    this(Stream underlying) {
        this.underlying = underlying;
    }

    void separator(immutable(void)[] separator = null) nothrow {
        separator_ = cast(immutable(ubyte)[])separator;
    }
    void limit(size_t limit = 0) nothrow {
        limit_ = limit;
    }
    void partialReceive(bool partialReceive = false) {
        partialReceive_ = partialReceive;
    }

    override Promise!void close() nothrow {
        return underlying.close();
    }

    override Promise!void shutdown() nothrow {
        return underlying.shutdown();
    }

    override Promise!void write(immutable(ubyte)[] data) nothrow {
        return underlying.write(data);
    }

protected:
    override void readOne() nothrow {
        ptrdiff_t posClosed = -1;
        if (separator_.length > 0) {
            posClosed = buffer.countUntilPartial(separator_);
        }

        if (posClosed >= 0) {
            auto posOpen = posClosed + separator_.length;
            // Found separator
            if (posOpen <= buffer.length) {
                auto output = buffer[0..posOpen];
                buffer = buffer[posOpen..$];
                readOneData(output);
                return;
            }
            // Found part of the separator on end of buffer
            if (posOpen > buffer.length && partialReceive_ && posClosed > 0) {
                auto output = buffer[0..posClosed];
                buffer = buffer[posClosed..$];
                readOneData(output);
                return;
            }
        } else if (limit_ > 0 && buffer.length >= limit_) {
            auto output = buffer[0..limit_];
            buffer = buffer[limit_..$];
            readOneData(output);
            return;
        } else if (partialReceive_ && buffer.length > 0) {
            auto output = buffer;
            buffer = null;
            readOneData(output);
            return;
        }

        if (underlyingEof) {
            auto output = buffer;
            buffer = null;
            readOneData(output);
            return;
        }

        underlying.read().each((data) {
            buffer ~= data;
            return false;
        }).then((eof) {
            underlyingEof = eof;
        }).then(() {
            readOne();
        }).except((Exception e) {
            rejectOneData(e);
        }).nothrow_();
    }
}
unittest {
    auto a = new ManualStream;
    auto b = new Tokenizer(a);
    bool called = false;
    bool eof = false;
    b.read().each((data) {
        assert(!called);
        assert(data == "Hello world");
        called = true;
    }).then((_) {
        assert(called);
        assert(!eof);
        eof = true;
    }).nothrow_();
    a.writeToRead(cast(const(ubyte)[])"Hello world");
    a.writeToRead();
    assert(eof);
}
unittest {
    auto a = new ManualStream;
    auto b = new Tokenizer(a);
    b.separator("\r\n");
    b.limit();
    int call = 0;
    b.read().each((data) {
        switch(call++) {
        case 0:
            assert(data == "\r\n");
            break;
        case 1:
            assert(data == "Hello\r\n");
            break;
        case 2:
            assert(data == "World");
            break;
        default: assert(false);
        }
    }).then((_) {
        assert(call++ == 3);
    }).nothrow_();
    a.writeToRead(cast(const(ubyte)[])"\r\nHello\r\nWorld");
    assert(call == 2);
    a.writeToRead();
    assert(call == 4);
}
unittest {
    auto a = new ManualStream;
    auto b = new Tokenizer(a);
    b.separator();
    b.limit(3);
    int call = 0;
    b.read().each((data) {
        switch(call++) {
        case 0:
            assert(data == "abc");
            break;
        case 1:
            assert(data == "def");
            break;
        case 2:
            assert(data == "gh");
            break;
        default: assert(false);
        }
    }).then((_) {
        assert(call++ == 3);
    }).nothrow_();
    a.writeToRead(cast(const(ubyte)[])"ab");
    assert(call == 0);
    a.writeToRead(cast(const(ubyte)[])"cdef");
    assert(call == 2);
    a.writeToRead(cast(const(ubyte)[])"gh");
    assert(call == 2);
    a.writeToRead();
    assert(call == 4);
}
unittest {
    auto a = new ManualStream;
    auto b = new Tokenizer(a);
    b.separator();
    b.limit(3);
    auto err = new Exception("yada");
    int call = 0;
    b.read().each((data) {
        switch(call++) {
        case 0:
            assert(data == "abc");
            break;
        case 1:
            assert(data == "def");
            break;
        default: assert(false);
        }
    }).then((_) {
        assert(false);
    }).except((Exception e) {
        assert(e is err);
        call++;
    }).nothrow_();
    a.writeToRead(cast(const(ubyte)[])"abcdefgh");
    assert(call == 2);
    a.writeToRead(err);
    assert(call == 3);
}
unittest {
    auto a = new ManualStream;
    auto b = new Tokenizer(a);
    b.separator("ABCD");
    b.limit();
    b.partialReceive(true);
    int call = 0;
    b.read().each((data) { 
        switch(call++) {
        case 0:
            assert(data == "abc");
            break;
        case 1:
            assert(data == "abcABCD");
            break;
        case 2:
            assert(data == "abc");
            break;
        case 3:
            assert(data == "abc");
            break;
        case 4:
            assert(data == "def");
            break;
        case 5:
            assert(data == "ab");
            break;
        case 6:
            debug import std.stdio;
            debug writeln(cast(const(char)[])data);
            assert(data == "ABab");
            break;
        case 7:
            assert(data == "ABCD");
            break;
        case 8:
            assert(data == "ab");
            break;
        case 9:
            assert(data == "AB");
            break;
        default: assert(false);
        }
    }).then((eof) {
        assert(eof);
        assert(call++ == 10);
    }).nothrow_();
    a.writeToRead(cast(const(ubyte)[])"abc").nothrow_();
    assert(call == 1);
    a.writeToRead(cast(const(ubyte)[])"abcABCDabc").nothrow_();
    assert(call == 3);
    b.separator();
    b.limit(3);
    a.writeToRead(cast(const(ubyte)[])"abcdef").nothrow_();
    assert(call == 5);
    b.separator("ABCD");
    b.limit();
    a.writeToRead(cast(const(ubyte)[])"abAB");
    assert(call == 6);
    a.writeToRead(cast(const(ubyte)[])"abAB");
    assert(call == 7);
    a.writeToRead(cast(const(ubyte)[])"CDabAB");
    assert(call == 9);
    a.writeToRead();
    assert(call == 11);
}