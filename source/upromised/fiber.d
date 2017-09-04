module upromised.fiber;
import upromised.promise : DelegatePromise, Promise;
import core.thread : Fiber;

Promise!T async(T)(T delegate() cb) {
	import upromised.promise : promisifyCall;

	auto r = new DelegatePromise!T;
	(new Fiber(() nothrow {
		promisifyCall(cb).thenWithTrace((v) => r.resolve(v));
	})).call();
	return r;
}
T await(T)(Promise!T a) {
	auto self = Fiber.getThis();
	assert(self !is null);
	
	bool already;
	Promise!T.Value r;

	a.thenWithTrace((rArg) nothrow {
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