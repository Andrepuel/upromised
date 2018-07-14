module upromised.fiber;
import upromised.promise : DelegatePromise, Promise;
import core.thread : Fiber;

class FiberPromise(T) : DelegatePromise!T {
private:
	bool running;
	T delegate() task;

public:
	this(T delegate() task) {
		this.task = task;
	}

	override protected void then_(void delegate(Value) nothrow cb) nothrow {
		if (!running) {
			try {
				(new Fiber(() nothrow {
					execute();
				})).call();
			} catch(Exception) {
				import core.stdc.stdlib : abort;
				abort();
			}
		}

		super.then_(cb);
	}

	void execute() nothrow {
		import upromised.promise : promisifyCall;
		
		if (running) {
			return;
		}

		running = true;
		promisifyCall(task).then_((v) => resolve(v));
	}
}

Promise!T async(T)(T delegate() cb) {
	return new FiberPromise!T(cb);
}
T await(T)(Promise!T a) {
	auto otherFiber = cast(FiberPromise!T)a;
	if (otherFiber !is null) {
		otherFiber.execute();
	}

	auto self = Fiber.getThis();
	assert(self !is null);
	
	bool already;
	Promise!T.Value r;

	a.then_((rArg) nothrow {
		r = rArg;
		try {
			if (Fiber.getThis() is self) {
				already = true;
			} else {
				self.call();
			}
		} catch(Exception) {
			assert(false);
		}
	});

	if (!already) {
		Fiber.yield();
	}

	if (r.e) {
		throw r.e;
	}

	static if (!is(T == void)) {
		return r.value[0];
	}
}
//Async turns the fiber into a promise
unittest {
	int value;
	async(() {
		return 3;
	}).then((valueArg) {
		value = valueArg;
	}).nothrow_();
	assert(value == 3);
}
//Await blocks the fiber until the promise is resolved
unittest {
	int value;
	auto dg = new DelegatePromise!int;
	async(() {
		return await(dg);
	}).then((valueArg) {
		value = valueArg;
	}).nothrow_();
	assert(value == 0);
	dg.resolve(4);
	assert(value == 4);
}
//Async propagates exceptions
unittest {
	bool called;
	auto err = new Exception("msg");
	async(() {
		throw err;
	}).except((Exception e) {
		assert(e is err);
		called = true;
	}).nothrow_();
	assert(called);
}
//Await propagates exceptions
unittest {
	auto err = new Exception("msg");
	DelegatePromise!void dg = new DelegatePromise!void;
	bool called;
	async(() {
		try {
			await(dg);
			assert(false);
		} catch(Exception e) {
			assert(err is e);
			called = true;
		}
	}).nothrow_();

	assert(!called);
	dg.reject(err);
	assert(called);
}
//Await works on already fulfiled Promise
unittest {
	int value;
	async(() {
		return await(Promise!int.resolved(3));
	}).then((valueArg) {
		value = valueArg;
	}).nothrow_();

	assert(value == 3);
}
//Call then twice on an async will yield the same result
unittest {
	auto res = async(() {
		return new int;
	});

	int* v1;
	int* v2;
	res.then((v) {
		v1 = v;
	}).nothrow_();
	res.then((v) {
		v2 = v;
	}).nothrow_();

	assert(v1 !is null);
	assert(v1 is v2);
}
//Async inside async
unittest {
	int v;
	DelegatePromise!int dg = new DelegatePromise!int;
	async(() {
		return await(async(() {
			return await(dg);
		}));
	}).then((arg) {
		v = arg;
	}).nothrow_();
	assert(v == 0);
	dg.resolve(3);
	assert(v == 3);
}
//Await already fulfilled async
unittest {
	int v;
	async(() {
		auto other = async(() {
			return 3;
		});
		other.then((arg) {
			assert(v == 0);
			v = arg;
		}).nothrow_();
		assert(v == 3);
		v = 0;
		int v2 = await(other);
		assert(v == 0);
		return v2;
	}).then((arg) {
		v = arg;
	}).nothrow_;
	assert(v == 3);
}
//Async within async reuses the same fiber
unittest {
	int called;
	async(() {
		auto outter = Fiber.getThis();
		await(async(() {
			assert(Fiber.getThis() is outter);
			called++;
		}));
		assert(called == 1);

		auto paralel = async(() {
			assert(Fiber.getThis() !is outter);
			called++;
		}).nothrow_;
		assert(called == 2);
		called++;
	}).nothrow_();
	assert(called == 3);
}