#!/usr/bin/env dub
/+ dub.json:
{
	"name": "work",
	"dependencies": {
		"upromised": {
			"version": "*",
			"path": "../"
		}
	},
	"subConfigurations": {
		"upromised": "without_tls"
	}
}
+/

import upromised.loop : defaultLoop;
import std.stdio;

auto randomPrime() {
	import std.random : uniform;

	auto candidate = uint.min.uniform(uint.max);
	if (candidate % 2 == 0) {
		candidate++;
	}
	outer: while (true) {
		foreach(i; 2..(candidate/2)) {
			if (candidate % i == 0) {
				candidate++;
				continue outer;
			}
		}
		return candidate;
	}

	assert(false);
}

int main(string[]) {
	auto loop = defaultLoop();

	foreach(i; 0..32) {
		loop.work(() => randomPrime())
		.then((prime) {
			writeln(prime);
		}).nothrow_;
	}

	return loop.run();
}