module upromised.promise;

import std.format : format;

interface Promise_ {
	final protected void fatal() nothrow {
		import std.algorithm : each;
		import std.stdio : stderr;
		import upromised.backtrace : backtrace;

		try {
			stderr.writeln("Fatal error");
			backtrace.each!(x => stderr.writeln(x));
		} catch(Exception) {
		}
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

auto promisify(T)(T a) nothrow {
	static if (is(T : Promise_)) {
		return a;
	} else {
		return Promise!T.resolved(a);
	}
}
auto promisifyCall(T, U...)(T a, U b) nothrow {
	static if (is(typeof(a(b)) == void)) {
		try {
			a(b);
			return Promise!void.resolved();
		} catch(Exception e) {
			return Promise!void.rejected(e);
		}
	} else {
		try {
			return promisify(a(b));
		} catch(Exception e) {
			return typeof(promisify(a(b))).rejected(e);
		}
	}
}

interface Promise(T_) : Promise_ {
	import std.typecons : Tuple;

	alias T = T_;

	static if (is(T == void)) {
		alias Types = Tuple!();
		template Then(U) {
			alias Then = U delegate();
		}
	} else {
		alias Types = Tuple!(T);
		template Then(U) {
			alias Then = U delegate(T);
		}
	}

	struct Value {
		this(Exception e) {
			this.e = e;
		}

		static if (!is(T == void)) {
			this(Exception e, T value) {
				this.e = e;
				this.value[0] = value;
			}
		}

		Exception e;
		Types value;
	}
	
	static if (is(T == void)) {
		Promisify!U then(U)(U delegate() cb) nothrow {
			return then2!U(cb);
		}
	} else {
		Promisify!U then(U)(U delegate(T) cb) nothrow {
			return then2!U(cb);
		}

		Promisify!U then(U)(U delegate() cb) nothrow {
			return then2!U((_) => cb());
		}
	}

	protected Promisify!U then2(U)(Then!U cb) nothrow {
		auto r = new DelegatePromise!(Promisify!U.T);
		thenWithTrace((value) nothrow {
			if (value.e !is null) {
				r.reject(value.e);
			} else {
				scope(failure) r.fatal();
				promisifyCall(cb, value.value.expand).thenWithTrace((v) nothrow {
					r.resolve(v);
				});
			}
		});
		return r;
	}

	Promise!void except(E,U)(U delegate(E e) cb) nothrow
	if (is(Promisify!U.T == void) && is (E : Exception))
	{
		auto r = new DelegatePromise!void;
		thenWithTrace((value) nothrow {
			scope(failure) r.fatal();
			if (value.e !is null) {
				E e = cast(E)value.e;
				if (e !is null) {
					promisifyCall(cb, e).thenWithTrace((value) nothrow {
						r.resolve(value);
					});
				} else {
					r.reject(value.e);
				}
			} else {
				r.resolve();
			}
		});
		return r;
	}

	auto finall(U2)(U2 delegate() cb) nothrow {
		static if (is(Promisify!U2.T == void)) {
			alias U = T;
		} else {
			alias U = U2;
		}
		auto r = new DelegatePromise!(Promisify!U.T);
		thenWithTrace((value) nothrow {
			scope(failure) r.fatal();
			promisifyCall(cb).thenWithTrace((value2) nothrow {
				Promisify!U.Value value3;
				value3.e = value2.e is null ? value.e : value2.e;
				static if (is(Promisify!U2.T == void)) {
					static if (!is(Promisify!U.T == void)) {
						value3.value = value.value;
					}
				} else {
					value3.value = value2.value;
				}

				r.resolve(value3);
			});
		});
		return r;
	}

	Promise!T failure(U)(U delegate(Exception) cb) nothrow
	if (is(Promisify!U.T == void))
	{
		auto r = new DelegatePromise!T;
		thenWithTrace((value) nothrow {
			if (value.e !is null) {
				promisifyCall(cb, value.e).thenWithTrace((value2) nothrow {
					r.resolve(value);
				});
			} else {
				r.resolve(value);
			}
		});
		return r;
	}

	static if (is(T == void)) {
		static Promise!T resolved() nothrow {
			return resolved_(Value(null));
		}
	} else {
		static Promise!T resolved(T t) nothrow {
			return resolved_(Value(null, t));
		}
	}
	protected static Promise!T resolved_(Value value) {
		return new class Promise!T {
			override void then_(void delegate(Value) nothrow cb) nothrow {
				cb(value);
			}
		};
	}

	static Promise!T rejected(Exception e) nothrow {
		import core.runtime : Runtime;
		if (e.info is null) {
			try {
				e.info = Runtime.traceHandler()(null);
			} catch(Exception) {
			}
		}

		return new class Promise!T {
			override void then_(void delegate(Value) nothrow cb) nothrow {
				cb(Value(e));
			}
		};
	}

	final Promise!void nothrow_() nothrow {
		return except((Exception e) => .fatal(e));
	}

	protected void then_(void delegate(Value) nothrow cb) nothrow;

	final protected void thenWithTrace(void delegate(Value) nothrow cb) nothrow {
		import upromised.backtrace : backtrace, traceinfo, concat, setBasestack, recoverBasestack;

		Throwable.TraceInfo backBt = ["*async*"].traceinfo.concat(backtrace());
		then_((value) nothrow {
			auto prev = setBasestack(backBt);
			scope(exit) recoverBasestack(prev);
			cb(value);
		});
	}
}

class DelegatePromise(T) : Promise!T {
	bool resolved;
	Value result;
	void delegate(Value) nothrow[] pending;

	override void then_(void delegate(Value) nothrow cb) nothrow {
		if (resolved) {
			cb(result);
		} else {
			pending ~= cb;
		}
	}

	void resolve(Value value) nothrow {
		scope(failure) fatal();
		assert(!resolved);
		result = value;
		resolved = true;
		foreach(cb; pending) {
			cb(result);
		}
		pending = null;
	}

	static if (is(T == void)) {
		void resolve() nothrow {
			resolve(Value());
		}
	} else {
		void resolve(T value) nothrow {
			resolve(Value(null, value));
		}
	}
	void reject(Exception e) nothrow {
		resolve(Value(e));
	}
}
unittest { // Multiple then
    auto a = new DelegatePromise!int;
    int sum = 0;
    a.then((int a) { sum += a; });
    a.then((a) { sum += a; });
    a.resolve(2);
    assert(sum == 4);
    a.then((a) { sum += a; });
    assert(sum == 6);
}
unittest { // Void promise
    auto a = new DelegatePromise!void;
    bool called = false;
    a.then(() {
        called = true;
    }).nothrow_();
    assert(!called);
    a.resolve();
    assert(called);
}

unittest { // Void Chaining
    auto a = new DelegatePromise!int;
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
    auto a = new DelegatePromise!int;
    int delayValue;
    DelegatePromise!string delayed;
    string finalValue;
    
    a.then((a) {
        return a * 2;
    }).then((a) {
        delayed = new DelegatePromise!string;
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
    auto a = new DelegatePromise!int;

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
    auto a = new DelegatePromise!int;
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
    auto a = new DelegatePromise!int;
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
// Finall propagates the other value
unittest {
	bool called;
	Promise!void.resolved()
	.then(() => 2)
	.finall(() => 3)
	.then((a) {
		assert(a == 3);
		return a;
	}).finall(() {
	}).then((a) {
		assert(a == 3);
		called = true;
	}).nothrow_();
	assert(called);
}
// Failure method is not called on success
unittest {
	bool called;
	Promise!int.resolved(3)
	.failure((Exception _) {
		assert(false);
	}).then((a) {
		assert(a == 3);
		called = true;
	}).nothrow_();
	assert(called);
}
// Failure method is called on error
unittest {
	bool called;
	bool called2;
	auto err = new Exception("err");
	Promise!int.rejected(err)
	.failure((Exception e) {
		assert(e is err);
		called = true;
	}).except((Exception e) {
		assert(e is err);
		called2 = true;
	}).nothrow_();
	assert(called);
	assert(called2);
}
// Failure might be delayed
unittest {
	DelegatePromise!void delay;
	bool called2;
	auto err = new Exception("err");
	Promise!int.rejected(err)
	.failure((Exception e) {
		assert(e is err);
		delay = new DelegatePromise!void;
		return delay;
	}).except((Exception e) {
		assert(e is err);
		called2 = true;
	}).nothrow_();
	assert(delay !is null);
	assert(!called2);
	delay.resolve();
	assert(called2);
}
interface PromiseIterator(T) {
	struct ItValue {
		bool eof;
		T value;
	}
	Promise!ItValue next(Promise!bool done);

	final Promise!bool each(U)(U delegate(T) cb) nothrow
	if (is(Promisify!U.T == void) || is(Promisify!U.T == bool))
	{
		import upromised.backtrace : backtrace, traceinfo, concat, setBasestack, recoverBasestack;

		Throwable.TraceInfo backBt = ["*async*"].traceinfo.concat(backtrace());
		
		static if (is(Promisify!U.T == void)) {
			bool delegate() boolify = () => true;
		} else {
			bool delegate(bool) boolify = (bool a) => a;
		}

		bool eof;
		return do_while(() {
			auto done = new DelegatePromise!bool;
			return promisifyCall(&next, done).then((a) {
				if (a.eof) {
					done.resolve(false);
					eof = true;
					return Promise!bool.resolved(false);
				} else {
					auto prev = setBasestack(backBt);
					scope(exit) recoverBasestack(prev);
					return promisifyCall(cb, a.value).then(boolify).then((cont) {
						done.resolve(cont);
						return cont;
					});
				}
			});
		}).then(() => eof);
	}
}
class DelegatePromiseIterator(T) : PromiseIterator!T {
	import std.typecons : Tuple, tuple;

	alias Value = Promise!ItValue.Value;
	Tuple!(DelegatePromise!ItValue, Promise!bool) pending;
	Tuple!(Promise!ItValue, DelegatePromise!bool)[] buffer;

	override Promise!ItValue next(Promise!bool done) {
		if (buffer.length > 0) {
			auto next = buffer[0];
			buffer = buffer[1..$];
			done.thenWithTrace(a => next[1].resolve(a));
			return next[0];
		} else {
			assert(pending[0] is null);
			pending = tuple(new DelegatePromise!ItValue, done);
			return pending[0];
		}
	}

	Promise!bool resolve(T a) nothrow {
		return resolve(Value(null, ItValue(false, a)));
	}

	Promise!bool resolve() nothrow {
		return resolve(Value(null, ItValue(true)));
	}

	Promise!bool reject(Exception e) nothrow {
		return resolve(Value(e));
	}

	Promise!bool resolve(Value a) nothrow {
		auto cb = getPending;
		if (cb[0]) {
			cb[0].resolve(a);
			return cb[1];
		} else {
			auto r = new DelegatePromise!bool;
			buffer ~= tuple(Promise!ItValue.resolved_(a), r);
			return r;
		}
	}

	Tuple!(DelegatePromise!ItValue, Promise!bool) getPending() nothrow {
		auto r = pending;
		pending[0] = null;
		return r;
	}
}

unittest { //Iterator
    DelegatePromiseIterator!int a = new DelegatePromiseIterator!int;
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
    DelegatePromiseIterator!int a = new DelegatePromiseIterator!int;
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
    auto a = new DelegatePromiseIterator!int;
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
    DelegatePromise!bool delayed;
    a.each((a) {
        delayed = new DelegatePromise!bool;
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
    auto a = new DelegatePromiseIterator!int;
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
    auto a = new DelegatePromise!int;
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
    auto a = new DelegatePromise!int;
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
    auto a = new DelegatePromise!int;
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
    auto a = new DelegatePromise!int;
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
    auto a = new DelegatePromise!int;
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
    auto a = new DelegatePromiseIterator!int;
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
    auto a = new DelegatePromiseIterator!int;
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
    auto a = new DelegatePromiseIterator!int;
    int calls = 0;
    auto cont_delay = new DelegatePromise!bool;
    
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
// next() might throw exception
unittest {
	auto err = new Exception("oi");
	auto x = new class PromiseIterator!int {
		override Promise!ItValue next(Promise!bool) {
			throw err;
		}
	};

	bool called = false;
	x.each((_) {
		assert(false);
	}).then((_) {
		assert(false);
	}).except((Exception e) {
		called = true;
		assert(e is err);
	}).nothrow_();
	assert(called);
}
private void do_while(U)(U delegate() cb, DelegatePromise!void r, Throwable.TraceInfo backBt) nothrow {
	import upromised.backtrace : setBasestack, recoverBasestack;

	promisifyCall(cb).then_((v) nothrow {
		auto prev = setBasestack(backBt);
		scope(exit) recoverBasestack(prev);

		if (v.e) {
			r.resolve(Promise!void.Value(v.e));
			return;
		}

		bool cont;
		static if(is(Promisify!U.T == void)) {
			cont = true;
		} else {
			cont = v.value[0];
		}

		if (cont) {
			do_while(cb, r, backBt);
		} else {
			r.resolve();
		}
	});
}
Promise!void do_while(U)(U delegate() cb) nothrow
if (is(Promisify!U.T == bool) || is(Promisify!U.T == void))
{
	import upromised.backtrace : backtrace, traceinfo, concat;

	auto r = new DelegatePromise!void;
	Throwable.TraceInfo backBt = ["*async*"].traceinfo.concat(backtrace());
	do_while(cb, r, backBt);
	return r;
}
// do_while until return 0
unittest {
	int count = 3;
	do_while(() {
		count--;
		return count > 0;
	}).nothrow_();

	assert(count == 0);
}
// do_while might be delayed
unittest {
	int called = 0;
	DelegatePromise!bool next;
	do_while(() {
		++called;
		next = new DelegatePromise!bool;
		return next;
	}).then(() {
		assert(called == 2);
		called++;
	}).nothrow_();
	assert(called == 1);
	next.resolve(true);
	assert(called == 2);
	next.resolve(false);
	assert(called == 3);
}
// do_while catches all exceptions
unittest {
	auto err = new Exception("");
	bool called;
	do_while(() {
		throw err;
		return true;
	}).except((Exception e) {
		assert(e is err);
		called = true;
	}).nothrow_();
	assert(called);
}
// do_while with void loops indefinitely
unittest {
	int called;
	DelegatePromise!void next;
	do_while(() {
		called++;
		next  = new DelegatePromise!void;
		return next;
	}).nothrow_();
	assert(called == 1);
	next.resolve();
	assert(called == 2);
	next.resolve();
	assert(called == 3);
}