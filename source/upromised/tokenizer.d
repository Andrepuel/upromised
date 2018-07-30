module upromised.tokenizer;
import std.exception : enforce;
import upromised.promise : DelegatePromiseIterator, Promise, PromiseIterator;
import upromised.stream : Stream;
import upromised : fatal;

private ptrdiff_t countUntilPartial(const(ubyte)[] input, const(ubyte)[] search) nothrow {
    import std.algorithm : startsWith, min;

    foreach(pos; 0..input.length) {
        if (search.startsWith(input[pos..$.min(pos + search.length)])) return pos;
    }
    return -1;
}

class Tokenizer(T) {
private:
    alias Underlying = PromiseIterator!(T[]);
    Underlying underlying;
    Underlying read_;
    bool underlyingEof;
    T[] separator_;
    T[] buffer;
    size_t limit_;
    bool partialReceive_;

public:
    this(Underlying underlying) nothrow {
        this.underlying = underlying;
    }

    void separator(immutable(void)[] separator = null) nothrow {
        separator_ = cast(immutable(T)[])separator;
    }
    void limit(size_t limit = 0) nothrow {
        limit_ = limit;
    }
    void partialReceive(bool partialReceive = false) nothrow {
        partialReceive_ = partialReceive;
    }

    PromiseIterator!(T[]) read() nothrow {
        if (read_ is null) {
            read_ = new class PromiseIterator!(T[]) {
                override Promise!ItValue next(Promise!bool) {
                    return readOne()
                    .then((chunk) => chunk ? ItValue(false, chunk) : ItValue(true));
                }
            };
        }
        return read_;
    }

protected:
    Promise!(T[]) readOne() nothrow {
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
                return Promise!(T[]).resolved(output);
            }
            // Found part of the separator on end of buffer
            if (posOpen > buffer.length && partialReceive_ && posClosed > 0) {
                auto output = buffer[0..posClosed];
                buffer = buffer[posClosed..$];
                return Promise!(T[]).resolved(output);
            }
        } else if (limit_ > 0 && buffer.length >= limit_) {
            auto output = buffer[0..limit_];
            buffer = buffer[limit_..$];
            return Promise!(T[]).resolved(output);
        } else if (partialReceive_ && buffer.length > 0) {
            auto output = buffer;
            buffer = null;
            return Promise!(T[]).resolved(output);
        }

        if (underlyingEof) {
            return Promise!void.resolved()
            .then(() {
                enforce((!limit_ && !separator_) || partialReceive_, "EOF unexpected");
                auto output = buffer;
                buffer = null;
                return Promise!(T[]).resolved(output);
            });
        }

        return underlying.each((data) {
            buffer ~= data;
            return false;
        }).then((eof) {
            underlyingEof = eof;
        }).then(() => readOne());
    }
}
unittest {
    auto a = new DelegatePromiseIterator!(const(ubyte)[]);
    auto b = new Tokenizer!(const(ubyte))(a);
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
    a.resolve(cast(const(ubyte)[])"Hello world").nothrow_();
    a.resolve();
    assert(eof);
}
unittest {
    auto a = new DelegatePromiseIterator!(const(ubyte)[]);
    auto b = new Tokenizer!(const(ubyte))(a);
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
        default: assert(false);
        }
    }).except((Exception e) {
        assert(call++ == 2);
        assert(e.msg == "EOF unexpected");
    }).then(() {
        assert(call++ == 3);
    }).nothrow_();
    a.resolve(cast(const(ubyte)[])"\r\nHello\r\nWorld").nothrow_();
    assert(call == 2);
    a.resolve();
    assert(call == 4);
}
unittest {
    auto a = new DelegatePromiseIterator!(const(ubyte)[]);
    auto b = new Tokenizer!(const(ubyte))(a);
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
        default: assert(false);
        }
    }).except((Exception e) {
        assert(call++ == 2);
        assert(e.msg == "EOF unexpected");
    }).then(() {
        assert(call++ == 3);
    }).nothrow_();
    a.resolve(cast(const(ubyte)[])"ab").nothrow_();
    assert(call == 0);
    a.resolve(cast(const(ubyte)[])"cdef").nothrow_();
    assert(call == 2);
    a.resolve(cast(const(ubyte)[])"gh").nothrow_();
    assert(call == 2);
    a.resolve();
    assert(call == 4);
}
unittest {
    auto a = new DelegatePromiseIterator!(const(ubyte)[]);
    auto b = new Tokenizer!(const(ubyte))(a);
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
    a.resolve(cast(const(ubyte)[])"abcdefgh").nothrow_();
    assert(call == 2);
    a.reject(err).nothrow_();
    assert(call == 3);
}
unittest {
    auto a = new DelegatePromiseIterator!(const(ubyte)[]);
    auto b = new Tokenizer!(const(ubyte))(a);
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
    a.resolve(cast(const(ubyte)[])"abc").nothrow_();
    assert(call == 1);
    a.resolve(cast(const(ubyte)[])"abcABCDabc").nothrow_();
    assert(call == 3);
    b.separator();
    b.limit(3);
    a.resolve(cast(const(ubyte)[])"abcdef").nothrow_();
    assert(call == 5);
    b.separator("ABCD");
    b.limit();
    a.resolve(cast(const(ubyte)[])"abAB").nothrow_();
    assert(call == 6);
    a.resolve(cast(const(ubyte)[])"abAB").nothrow_();
    assert(call == 7);
    a.resolve(cast(const(ubyte)[])"CDabAB").nothrow_();
    assert(call == 9);
    a.resolve();
    assert(call == 11);
}