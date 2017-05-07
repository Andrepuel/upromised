module upromised.promise;

import std.format : format;

interface Promise_ {
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

	DebugInfo info() nothrow;

	final protected void fatal() nothrow {
		import std.stdio : stderr;
		
		try { stderr.writeln("Fatal error"); } catch(Exception){}
		info.printAll();
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
		Promisify!U then(U)(U delegate() cb, string file = __FILE__, size_t line = __LINE__) nothrow {
			return then2!U(cb, file, line);
		}
	} else {
		Promisify!U then(U)(U delegate(T) cb, string file = __FILE__, size_t line = __LINE__) nothrow {
			return then2!U(cb, file, line);
		}

		Promisify!U then(U)(U delegate() cb, string file = __FILE__, size_t line = __LINE__) nothrow {
			return then2!U((_) => cb(), file, line);
		}
	}

	protected Promisify!U then2(U)(Then!U cb, string file = __FILE__, size_t line = __LINE__) nothrow {
		auto r = new DelegatePromise!(Promisify!U.T)(this, file, line);
		then_((value) nothrow {
			if (value.e !is null) {
				r.reject(value.e);
			} else {
				scope(failure) r.fatal();
				promisifyCall(cb, value.value.expand).then_((v) nothrow {
					r.resolve(v);
				});
			}
		});
		return r;
	}

	Promise!void except(E,U)(U delegate(E e) cb, string file = __FILE__, size_t line = __LINE__) nothrow
	if (is(Promisify!U.T == void) && is (E : Exception))
	{
		auto r = new DelegatePromise!void(this, file, line);
		then_((value) nothrow {
			scope(failure) r.fatal();
			if (value.e !is null) {
				E e = cast(E)value.e;
				if (e !is null) {
					promisifyCall(cb, e).then_((value) nothrow {
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

	auto finall(U2)(U2 delegate() cb, string file = __FILE__, size_t line = __LINE__) nothrow {
		static if (is(Promisify!U2.T == void)) {
			alias U = T;
		} else {
			alias U = U2;
		}
		auto r = new DelegatePromise!(Promisify!U.T)(this, file, line);
		then_((value) nothrow {
			scope(failure) r.fatal();
			promisifyCall(cb).then_((value2) nothrow {
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

	static if (is(T == void)) {
		static Promise!T resolved(string file = __FILE__, size_t line = __LINE__) nothrow {
			return resolved_(Value(null), file, line);
		}
	} else {
		static Promise!T resolved(T t, string file = __FILE__, size_t line = __LINE__) nothrow {
			return resolved_(Value(null, t), file, line);
		}
	}
	protected static Promise!T resolved_(Value value, string file = __FILE__, size_t line = __LINE__) {
		return new class Promise!T {
			override void then_(void delegate(Value) nothrow cb) nothrow {
				cb(value);
			}

			override DebugInfo info() nothrow {
				return DebugInfo(file, line);
			}
		};
	}

	static Promise!T rejected(Exception e, string file = __FILE__, size_t line = __LINE__) nothrow {
		return new class Promise!T {
			override void then_(void delegate(Value) nothrow cb) nothrow {
				cb(Value(e));
			}

			override DebugInfo info() nothrow {
				return DebugInfo(file, line);
			}
		};
	}

	final Promise!void nothrow_(string file = __FILE__, size_t line = __LINE__) nothrow {
		return except((Exception e) => .fatal(e, file, line), file, line);
	}

	protected void then_(void delegate(Value) nothrow cb) nothrow;
}

class DelegatePromise(T) : Promise!T {
	DebugInfo info_;

	bool resolved;
	Value result;
	void delegate(Value) nothrow[] pending;

	this(Promise_ parent = null, string file = __FILE__, size_t line = __LINE__) nothrow {
		info_ = DebugInfo(file, line, parent);
	}

	override DebugInfo info() nothrow {
		return info_;
	}

	override void then_(void delegate(Value) nothrow cb) nothrow {
		if (resolved) {
			cb(result);
		} else {
			pending ~= cb;
		}
	}

	void resolve(Value value) nothrow {
        if (resolved) {
            info.printAll();
        }

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

interface PromiseIterator(T) {
	struct ItValue {
		bool eof;
		T value;
	}
	Promise!ItValue next(Promise!bool done);

	final Promise!bool each(U)(U delegate(T) cb) nothrow
	if (is(Promisify!U.T == void) || is(Promisify!U.T == bool))
	{
		Promise!bool repeat() nothrow {
			static if (is(Promisify!U.T == void)) {
				bool delegate() boolify = () => true;
			} else {
				bool delegate(bool) boolify = (bool a) => a;
			}

			auto done = new DelegatePromise!bool;
			return promisifyCall(&next, done).then((a) {
				if (a.eof) {
					done.resolve(false);
					return Promise!bool.resolved(true);
				} else {
					return promisifyCall(cb, a.value).then(boolify).then((cont) {
						done.resolve(cont);
						if (cont) {
							return repeat();
						} else {
							return Promise!bool.resolved(false);
						}
					});
				}
			});
		}

		return repeat();
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
			done.then_(a => next[1].resolve(a));
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