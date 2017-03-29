module upromised.operations;
import std.array : empty, front, popFront;
import std.range : isInputRange;
import upromised.promise : Promise, PromiseIterator;

PromiseIterator!(typeof(T.init.front)) toAsync(T)(T input)
if (isInputRange!T)
{
	auto r = new PromiseIterator!(typeof(T.init.front));
	void delegate(bool) next;
	next = (bool) {
		if (input.empty) {
			r.resolve();
		} else {
			const auto value = input.front;
			input.popFront;
			r.resolve(value).then(next);
		}
	};

	next(false);
	
	return r;
}
unittest {
	auto b = [1, 2, 3].toAsync;
	int calls = 0;

	b.each((num) {
		assert(num == 1);
		assert(calls++ == 0);
		return false;
	}).then((eof) {
		assert(!eof);
		assert(calls++ == 1);	
	}).nothrow_().then(() {
		return b.each((num) {
			assert(num == calls++);
		});
	}).then((eof) {
		assert(eof);
		assert(calls++ == 4);
	}).nothrow_();

	assert(calls == 5);
}
unittest {
	auto b = (new class Object {
		int front;
		void popFront() {
			front++;
		}
		bool empty() {
			return false;
		}
	}).toAsync;

	int calls;
	b.each((num) {
		assert(calls++ == num);
		return num < 3;
	}).then((eof) {
		assert(!eof);
		assert(calls++ == 4);
	}).nothrow_();

	assert(calls == 5);
}
PromiseIterator!(T[]) toAsyncChunks(T)(T[] input, size_t chunkLength = 1024) {
	import std.algorithm : min;

	auto r = new PromiseIterator!(T[]);

	void delegate(bool) next;
	next = (bool) {
		if (input.length == 0) {
			r.resolve();
		} else {
			auto length = input.length.min(chunkLength);
			const auto value = input[0..length];
			input = input[length..$];
			r.resolve(value).then(next);
		}
	};
	next(true);

	return r;
}
unittest {
	import std.array : join;

	auto expected = ["abc", "def", "gh"];
	int calls = 0;

	expected.join.toAsyncChunks(3).each((chunk) {
		assert(chunk == expected[calls]);
		calls++;
	}).then((eof) {
		assert(eof);
		assert(calls++ == 3);
	}).nothrow_();

	assert(calls == 4);
}

Promise!(T[]) readAll(T)(PromiseIterator!T input) {
	T[] r;
	return input.each((value) {
		r ~= value;
	}).then((_) => r);
}
unittest {
	int[] all;
	[1, 2, 3].toAsync.readAll.then((allArg) {
		all = allArg;
	}).nothrow_();

	assert(all == [1, 2, 3]);
}

Promise!(T[]) readAllChunks(T)(PromiseIterator!(T[]) input) {
	T[] r;
	return input.each((value) {
		r ~= value;
	}).then((_) => r);
}
unittest {
	const(char)[] all;
	["Hello ", "World"].toAsync.readAllChunks.then((allArg) {
		all = allArg;
	}).nothrow_();

	assert(all == "Hello World");
}