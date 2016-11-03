module upromised.promise;

import std.format : format;

template Promisify(T) {
    static if (is(T : Promise_)) {
        alias Promisify = T;
    } else {
        alias Promisify = Promise!T;
    }
}

class Promise_ {
}

class Promise(T) : Promise_
if (!is(T == void))
{
import std.typecons : Tuple, tuple;
private:
    enum IsPromise = true;
    alias T_ = T;
    T resolved_;
    bool isResolved_;
    void delegate()[] then_;

    void resolveOne(R)(Promise!R r, R delegate(T) cb) {
        static if (is(R == void)) {
            cb(resolved_);
            r.resolve();
        } else {
            r.resolve(cb(resolved_));
        }
    }
    void resolveOne(R)(Promise!R r, Promise!R delegate(T) cb) {
        static if (is(R == void)) {
            cb(resolved_).then(() { r.resolve(); });
        } else {
            cb(resolved_).then((a) { r.resolve(a); });
        }
    }

public:
    Promisify!R then(R)(R delegate(T) cb) {
        auto r = new Promisify!R();
        if (isResolved_) {
            resolveOne(r, cb);
        } else {
            then_ ~= () => resolveOne(r, cb); 
        }
        return r;
    }

    void resolve(T value) {
        resolved_ = value;
        isResolved_ = true;
        while (then_.length > 0) {
            auto next = then_[0];
            then_ = then_[1..$];
            next();
        }
    }

}
class Promise(T) : Promise!(void*)
if (is(T == void))
{
    void resolve() {
        super.resolve(null);
    }
    Promisify!R then(R)(R delegate() cb) {
        return super.then((void*) { return cb();});
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
    });
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
    });
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
    });
    a.resolve(1);
    assert(delayValue == 2);
    assert(finalValue == "");
    delayed.resolve("2");
    assert(finalValue == "2");
}

class PromiseIterator(T) {
private:
    T[] resolved_;
    bool end_;
    Promise!bool delegate(T) each_;
    Promise!bool eachThen_;  

    static Promise!bool eachInvoke(R)(R delegate(T) cb, T t)
    if (!is(Promisify!R == R))
    {
        auto r = new Promise!bool;
        static if (is(R == void)) {
            cb(t);
            r.resolve(true);
        } else {
            r.resolve(cb(t));
        }
        return r;
    }

    static Promise!bool eachInvoke(R)(Promise!R delegate(T) cb, T t) {
        auto r = new Promise!bool;
        static if (is(R == void)) {
            cb(t).then(() => r.resolve(true));
        } else {
            cb(t).then((v) => r.resolve(v));
        }
        return r;
    }

    void resolveOne() {
        each_(resolved_[0]).then((cont) {
            resolved_ = resolved_[1..$];
            if (!cont) {
                auto then = eachThen_;
                eachThen_ = null;
                each_ = null;
                then.resolve(false);
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
        });
    }

public:
    void resolve(T a) {
        assert(!end_);
        resolved_ ~= a;
        if (each_ && resolved_.length == 1) {
            resolveOne();
        }
    }

    void resolve() {
        assert(!end_);
        end_ = true;
        if (eachThen_ && resolved_.length == 0) {
            eachThen_.resolve(true);
        }
    }

    Promise!bool each(R)(R delegate(T) cb)
    if(is(Promisify!R == Promise!bool) || is(Promisify!R == Promise!void))
    {
        assert(each_ is null);
        eachThen_ = new Promise!bool;
        each_ = (T t) => eachInvoke(cb, t);
        if (resolved_.length > 0) {
            resolveOne();
        }
        return eachThen_;
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
    });
    assert(sum == 1);
    a.resolve(2);
    assert(sum == 3);
    a.resolve();
    assert(sum == 0);
}