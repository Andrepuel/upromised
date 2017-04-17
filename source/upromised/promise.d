module upromised.promise;

import std.format : format;

struct DebugInfo {
    string file;
    size_t line;
    Promise_ parent;

    // Remarks: Printing a Promise per line ensures that
    // something will get printed even in case of memory corruption
    void printAll() nothrow {
        import std.stdio : stderr;

        try { stderr.writeln(file, ":", line); } catch(Exception){}
        if (parent !is null) parent.info.printAll();
    }
}

void fatal(Exception e = null, string file = __FILE__, ulong line = __LINE__) nothrow {
    import core.stdc.stdlib : abort;
    import std.stdio : stderr;
    try {
        stderr.writeln("%s(%s): Fatal error".format(file, line));
        if (e) {
            stderr.writeln(e);
        }
    } catch(Exception) {
        abort();
    }
    abort();
}

template Promisify(T) {
    static if (is(T : Promise_)) {
        alias Promisify = T;
    } else {
        alias Promisify = Promise!T;
    }
}
static assert(is(Promisify!int == Promise!int));
static assert(is(Promisify!(Promise!int) == Promise!int));
static assert(is(Promisify!void == Promise!void));

private void chainPromise(alias b, R, Args...)(Promise!R t, Args args) nothrow {
    scope(failure) {
        import std.stdio : stderr;
        
        try { stderr.writeln("Fatal error"); } catch(Exception){}
        t.info.printAll();
    }

    try {
        static if(is(typeof(b(args)) : Promise_)) {
            auto intermediary = b(args);
            static if (is(R == void)) {
                intermediary.then(() => t.resolve());
            } else {
                intermediary.then((a) => t.resolve(a));
            }
            intermediary.except((Exception e) => t.reject(e));
        } else {
            static if (is(R == void)) {
                b(args);
                t.resolve();
            } else {
                t.resolve(b(args));
            }
        }
    } catch(Exception e) {
        t.reject(e);
    }
}

class Promise_ {
public:
    DebugInfo info;

protected:
    Exception rejected_;

    void resolveExceptOne(R,E)(Promise!void r, R delegate(E) cb) nothrow
    if (is(Promisify!R == Promise!void))
    {
        if (rejected_ is null) {
            r.resolve();
        } else {
            E err = cast(E) rejected_;
            if (err) {
                chainPromise!cb(r, err);
            } else {
                r.reject(rejected_);
            }
        }
    }
}
class PromiseBase(T...) : Promise_ {
private:
    import std.typecons : Tuple;
    alias Types_ = T;
    Tuple!T resolved_;
    bool isResolved_;
    void delegate() nothrow[] then_;

    void resolveOne(R,J,U...)(Promise!R r, J delegate(U) cb) nothrow
    if(is(Promisify!J == Promise!R) && is(U == Types_))
    {
        if (rejected_ !is null) {
            r.reject(rejected_);
            return;
        }

        chainPromise!cb(r, resolved_.expand);
    }

    void resolveFinallyOne(R,J)(Promise!R r, J delegate() cb) nothrow
    if(is(Promisify!J == Promise!R))
    {
        import std.typecons : Tuple;
        static if (is(R == void)) {
            alias Rs = Tuple!().Types;
        } else {
            alias Rs = Tuple!R.Types;
        }

        auto r2 = new Promise!R;
        chainPromise!cb(r2);
        r2.then((Rs args) {
            if (rejected_ !is null) {
                r.reject(rejected_);
            } else {
                r.resolve(args);
            }
        });
        r2.except((Exception e) => r.reject(e));
    }

    void resolveAll() nothrow {
        while (then_.length > 0) {
            auto next = then_[0];
            then_ = then_[1..$];
            next();
        }
    }

    void thenPush(void delegate() nothrow cb) nothrow {
        if (isResolved_) {
            cb();
        } else {
            then_ ~= cb;
        }
    }

protected:
    Promisify!R thenBase(R,U...)(R delegate(U) cb, string file = __FILE__, size_t line = __LINE__) nothrow
    if(is(U == Types_))
    {
        auto r = new Promisify!R();
        r.info = DebugInfo(file, line, this);
        thenPush(() => resolveOne(r, cb));
        return r;
    }

    void resolveBase(Types_ value) nothrow
    {
        import std.typecons : tuple;

        resolved_ = tuple(value);
        isResolved_ = true;
        resolveAll();
    }

public:
    Promise!void except(R,E)(R delegate(E) cb, string file = __FILE__, size_t line = __LINE__) nothrow
    if (is(Promisify!R == Promise!void) && is(E : Exception))
    {
        auto r = new Promise!void;
        r.info = DebugInfo(file, line, this);
        thenPush(() => resolveExceptOne(r, cb));
        return r;
    }

    Promisify!R finall(R)(R delegate() cb, string file = __FILE__, size_t line = __LINE__) nothrow {
        auto r = new Promisify!R;
        r.info = DebugInfo(file, line, this);
        thenPush(() => resolveFinallyOne(r, cb));
        return r;
    }

    void reject(Exception err) nothrow {
        isResolved_ = true;
        rejected_ = err;
        resolveAll();
    }

    static auto resolved(Types_ t, string file = __FILE__, size_t line = __LINE__) nothrow {
        static if (Types_.length == 0) {
            auto r = new Promise!void;
        } else {
            auto r = new Promise!Types_;
        }
        r.resolve(t);
        r.info = DebugInfo(file, line, null);
        return r;
    }

    static auto rejected(Exception e, string file = __FILE__, size_t line = __LINE__) nothrow {
        static if (Types_.length == 0) {
            auto r = new Promise!void;
        } else {
            auto r = new Promise!Types_;
        }
        r.reject(e);
        r.info = DebugInfo(file, line, null);
        return r;
    }

    Promise!void nothrow_(string file = __FILE__, ulong line = __LINE__)  nothrow {
        return except((Exception e) => fatal(e, file, line), file, line);
    }
}
class Promise(T) : PromiseBase!T
if (!is(T == void))
{
private:
    alias T_ = T;

public:
    void resolve(T v) nothrow {
        resolveBase(v);
    }

    Promisify!R then(R)(R delegate(T) cb, string file = __FILE__, size_t line = __LINE__) nothrow {
        return thenBase(cb, file, line);
    }
}
class Promise(T) : PromiseBase!()
if (is(T == void))
{
private:
    alias T_ = void;

public:
    void resolve() nothrow {
        resolveBase();
    }
    Promisify!R then(R)(R delegate() cb, string file = __FILE__, size_t line = __LINE__) nothrow {
        return thenBase!R(cb, file, line);
    }
}
unittest { // Multiple then
    auto a = new Promise!int;
    int sum = 0;
    a.then((int a) { sum += a; });
    a.then((a) { sum += a; });
    a.resolve(2);
    assert(sum == 4);
    a.then((a) { sum += a; });
    assert(sum == 6);
}
unittest { // Void promise
    auto a = new Promise!void;
    bool called = false;
    a.then(() {
        called = true;
    }).nothrow_();
    assert(!called);
    a.resolve();
    assert(called);
}

unittest { // Void Chaining
    auto a = new Promise!int;
    int sum = 0;
    a.then((a) {
        sum += a;
    }).then(() {
        sum += 3;
    }).nothrow_();
    assert(sum == 0);
    a.resolve(3);
    assert(sum == 6);
}
unittest { // Chaining
    auto a = new Promise!int;
    int delayValue;
    Promise!string delayed;
    string finalValue;
    
    a.then((a) {
        return a * 2;
    }).then((a) {
        delayed = new Promise!string;
        delayValue = a;
        return delayed;
    }).then((a) {
        finalValue = a;
    }).nothrow_();
    a.resolve(1);
    assert(delayValue == 2);
    assert(finalValue == "");
    delayed.resolve("2");
    assert(finalValue == "2");
}
unittest { //Exceptions
    auto a = new Promise!int;

    auto err = new Exception("yada");
    bool caught = false;
    a.except((Exception e) {
        assert(err is e);
        caught = true;
    }).nothrow_();
    assert(!caught);
    a.reject(err);
    assert(caught);
}
unittest { //Exception chaining
    auto a = new Promise!int;
    class X : Exception {
        this() {
            super("X");
        }
    }

    bool caught = false;
    auto err = new Exception("yada");
    a.except((X _) {
        assert(false);
    }).except((Exception e) {
        assert(e is err);
        caught = true;
    }).nothrow_();
    assert(!caught);
    a.reject(err);
    assert(caught);
}
unittest {
    auto a = new Promise!int;
    auto err = new Exception("yada");
    bool caught = false;
    a.then((a) {
        throw err;
    }).then(() {
        assert(false);
    }).except((Exception e) {
        assert(e == err);
        caught = true;
    }).nothrow_();
    assert(!caught);
    a.resolve(2);
    assert(caught);
}

class PromiseIterator(T) {
private:
    import std.typecons : Tuple;

    Tuple!(T, Exception, Promise!bool)[] resolved_;
    bool end_;
    Promise!bool delegate(T) nothrow each_;
    Promise!bool eachThen_;  

    static Promise!bool eachInvoke(R)(R delegate(T) cb, T t) nothrow
    if (is(Promisify!R == Promise!bool) || is(Promisify!R == Promise!void))
    {
        auto r = new Promisify!R;
        chainPromise!cb(r, t);

        static if (is(Promisify!R.T_ == void)) {
            return r.then(() => true);
        } else {
            return r;
        }
    }

    Promise!bool stop() nothrow {
        import std.algorithm : swap;

        Promise!bool then;
        swap(then, eachThen_);
        each_ = null;
        return then;
    }

    void popResolved(bool cont) nothrow {
        resolved_[0][2].resolve(cont);
        resolved_ = resolved_[1..$];
    }

    void resolveOne() nothrow {
        auto next = resolved_[0];
        if (next[1] !is null) {
            stop().reject(next[1]);
            popResolved(false);
            return;
        }

        each_(resolved_[0][0]).then((cont) {
            popResolved(cont);
            if (!cont) {
                stop().resolve(false);
                return;
            }

            if (resolved_.length > 0) {
                resolveOne();
                return;
            }

            if (end_) {
                eachThen_.resolve(true);
                return;
            }
        }).except((Exception e) {
            popResolved(false);
            stop().reject(e);
        });
    }

public:
    void resolve(T a, Promise!bool r) nothrow {
        import std.typecons : tuple;

        assert(!end_);
        resolved_ ~= tuple(a, Exception.init, r);
        if (each_ && resolved_.length == 1) {
            resolveOne();
        }
    }
    Promise!bool resolve(T a, string file = __FILE__, size_t line = __LINE__) nothrow {
        Promise!bool r = new Promise!bool;
        r.info = DebugInfo(file, line, null);
        resolve(a, r);
        return r;
    }

    Promise!bool reject(Exception a, string file = __FILE__, size_t line = __LINE__) nothrow {
        import std.typecons : tuple;

        assert(!end_);
        Promise!bool r = new Promise!bool;
        r.info = DebugInfo(file, line, null);
        resolved_ ~= tuple(T.init, a, r);
        if (each_ && resolved_.length == 1) {
            resolveOne();
        }

        return r;
    }

    void resolve() nothrow {
        assert(!end_);
        end_ = true;
        if (eachThen_ && resolved_.length == 0) {
            eachThen_.resolve(true);
        }
    }

    Promise!bool each(R)(R delegate(T) cb, string file = __FILE__, size_t line = __LINE__) nothrow
    if(is(Promisify!R == Promise!bool) || is(Promisify!R == Promise!void))
    {
        assert(each_ is null);
        eachThen_ = new Promise!bool;
        auto r = eachThen_;
        each_ = (T t) => eachInvoke(cb, t);
        if (resolved_.length > 0) {
            resolveOne();
        } else if (end_) {
            eachThen_.resolve(true);
        }
        r.info = DebugInfo(file, line, null);
        return r;
    }
}

unittest { //Iterator
    PromiseIterator!int a = new PromiseIterator!int;
    int sum = 0;
    a.resolve(1);
    assert(sum == 0);
    a.each((b) {
        sum += b;
        return true;
    }).then((bool) {
        sum = 0;
        return;
    }).nothrow_();
    assert(sum == 1);
    a.resolve(2);
    assert(sum == 3);
    a.resolve();
    assert(sum == 0);
}
unittest { //Iterator catching
    PromiseIterator!int a = new PromiseIterator!int;
    auto err = new Exception("yada");
    bool caught = false;
    a.each((b) {
        throw err;
    }).except((Exception e) {
        assert(e == err);
        caught = true;
    }).nothrow_();
    assert(!caught);
    a.resolve(2);
    assert(caught);
    caught = false;
    a.resolve(3);
    assert(!caught);
    a.each((b) {
        assert(b == 3);
        caught = true;
    });
    assert(caught);
}
unittest { //Resolve done Promise
    auto a = new PromiseIterator!int;
    bool done = false;
    a.resolve(2).then((a) {
        assert(!a);
        done = true;
    }).nothrow_();
    assert(!done);
    a.each((a) {
        return false;
    });
    assert(done);
    done = false;
    Promise!bool delayed;
    a.each((a) {
        delayed = new Promise!bool;
        return delayed;
    }).nothrow_();
    assert(!done);
    bool done2 = false;
    a.resolve(3).then((a) {
        assert(a);
        done = true;
    }).nothrow_();
    a.resolve(4).then((a) {
        assert(!a);
        done2 = true;
    }).nothrow_();
    assert(!done);
    assert(!done2);
    delayed.resolve(true);
    assert(done);
    assert(!done2);
    delayed.resolve(false);
    assert(done);
    assert(done2);
}
unittest { // Rejecting iterator
    auto a = new PromiseIterator!int;
    bool called = false;
    auto err = new Exception("yada");
    class X : Exception {
        this() {
            super("yada");
        }
    }
    a.each((a) {
        assert(false);
    }).except((X err) {
        assert(false);
    }).except((Exception e) {
        assert(err is e);
        called = true;
    }).nothrow_();
    assert(!called);
    a.reject(err);
    assert(called);
}
unittest { //Resolved and rejected promise constructor
    bool called = false;
    Promise!void.resolved().then(() {
        called = true;
    });
    assert(called);
    called = false;
    Promise!int.resolved(3).then((a) {
        assert(a == 3);
        called = true;
    }).nothrow_();
    assert(called);
    called = false;
    auto err = new Exception("yada");
    Promise!int.rejected(err).except((Exception e) {
        assert(e is err);
        called = true;
    }).nothrow_();
    assert(called);
}
unittest { //Finally
    auto a = new Promise!int;
    auto called = [false,false,false];
    auto err = new Exception("yada");
    a.then((a) {
    }).except((Exception e) {
        assert(false);
    }).finall(() {
        called[0] = true;
    }).then(() {
        throw err;
    }).finall(() {
        called[1] = true;
    }).except((Exception e) {
        assert(called[1]);
        called[2] = true;
        assert(e is err);
    }).nothrow_();
    assert(!called[0]);
    assert(!called[1]);
    assert(!called[2]);
    a.resolve(1);
    assert(called[0]);
    assert(called[1]);
    assert(called[2]);
}
unittest { //Finally might throw Exception
    auto a = new Promise!int;
    auto called = false;
    auto err = new Exception("yada");
    a.finall(() {
        throw err;
    }).then(() {
        assert(false);
    }).except((Exception e) {
        assert(e is err);
        called = true;
    }).nothrow_();
    assert(!called);
    a.resolve(2);
    assert(called);
}
unittest { //Finally return promise
    auto a = new Promise!int;
    auto called = false;
    auto err = new Exception("yada");
    a.finall(() {
        return Promise!void.rejected(err);
    }).then(() {
        assert(false);
    }).except((Exception e) {
        assert(err is e);
        called = true;
    }).nothrow_();
    assert(!called);
    a.resolve(2);
    assert(called);
}
unittest { //Return failed promise
    auto a = new Promise!int;
    auto called = false;
    auto err = new Exception("yada");
    a.then((a) {
        return Promise!void.rejected(err);
    }).then(() {
        assert(false);
    }).except((Exception e) {
        assert(err is e);
        called = true;
    }).nothrow_();
    assert(!called);
    a.resolve(2);
    assert(called);
}
unittest { //Finally returning a value
    auto a = new Promise!int;
    bool called = false;
    a.finall(() {
        return 2;
    }).then((a) {
        assert(a == 2);
        called = true;
    }).nothrow_();
    assert(!called);
    a.resolve(0);
    assert(called);
}
unittest { //Fail right away
    auto a = new PromiseIterator!int;
    auto err = new Exception("yada");
    bool called = false;
    a.reject(err);
    a.each((a) {
        assert(false);
    }).except((Exception e) {
        assert(e is err);
        called = true;
    }).nothrow_();
    assert(called);
}
unittest { //EOF right away
    auto a = new PromiseIterator!int;
    bool called = false;
    a.resolve();
    a.each((a) {
        assert(false);
    }).then((eof) {
        assert(eof);
        called = true;
    }).nothrow_();
    assert(called);
}
unittest { // Ones might re-resolve right away
    auto a = new PromiseIterator!int;
    int calls = 0;
    auto cont_delay = new Promise!bool;
    
    a.resolve(0).then((cont) {
        a.resolve(1);
    }).nothrow_();

    a.each((b) {
        assert(b == calls);
        calls++;

        if (b == 0) {
            return Promise!bool.resolved(true);
        } else {
            return cont_delay;
        }
    }).then((eof) {
        assert(eof);
        assert(calls == 2);   
        calls++;
    }).nothrow_();

    a.resolve();
    assert(calls == 2);
    cont_delay.resolve(true);
}