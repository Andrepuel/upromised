module upromised.http;
import std.format : format;
import upromised.manual_stream : ManualStream;
import upromised.operations : readAllChunks;
import upromised.promise : Promise, PromiseIterator;
import upromised.stream : Stream;
import std.format : format;

struct Header {
	string key;
	string value;
}

enum Method {
	GET, POST, PUT, DELETE
}

private inout(Y)[] as(Y, T)(inout(T) input) {
	return cast(inout(Y)[])input;
}

PromiseIterator!(const(ubyte)[]) decodeChunked(PromiseIterator!(const(ubyte)[]) chunked) {
	import std.conv : to;
	import upromised.tokenizer : Tokenizer;

	auto r = new PromiseIterator!(const(ubyte)[]);
	auto tokenizer = new Tokenizer!(const(ubyte))(chunked);
	tokenizer.separator("\r\n");

	size_t chunkSize;
	bool step;
	tokenizer.read().each((chunk) {
		step = !step;
		if (step) {
			tokenizer.separator();
			chunkSize = chunk.as!char[0..$-2].to!size_t(16);
			tokenizer.limit(chunkSize + 2);
			return Promise!bool.resolved(true);
		} else {
			tokenizer.separator("\r\n");
			tokenizer.limit();
			return r.resolve(chunk[0..$-2]).then(a => a && chunkSize > 0);
		}
	}).then(_ => r.resolve()).except((Exception e) {
		r.reject(e);
	}).nothrow_();
	
	return r;
}
unittest {
	import upromised.operations : toAsyncChunks;

	const(ubyte)[] response;

	(cast(const(ubyte)[])"4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n TRAILING IGNORE")
		.toAsyncChunks(3)
		.decodeChunked
		.readAllChunks
		.then(a => response = a)
		.nothrow_();

	assert(response == "Wikipedia in\r\n\r\nchunks.", "%s unexpected".format([response.as!char]));
}
unittest {
	auto err = new Exception("err");
	bool called = false;

	auto rejected = new PromiseIterator!(const(ubyte)[]);
	rejected.reject(err);
	rejected
		.decodeChunked
		.each((_) {
			assert(false);
		}).then((_) {
			assert(false);
		}).except((Exception e) {
			assert(e is err);
			called = true;
		}).nothrow_();

	assert(called);
}

class Client {
private:
	PromiseIterator!(immutable(ubyte)[]) output;
	size_t contentLength;

public:
	this() {
		output = new PromiseIterator!(immutable(ubyte)[]);
	}
	
	this(Stream stream) {
		this();
		this.stream = stream;
	}

	Promise!void stream(Stream stream) {
		return output.each((data) => stream.write(data)).then((_) {});
	}

	Promise!void sendRequest(Method method, string uri) {
		return output.resolve("%s %s HTTP/1.1\r\n".format(method, uri).as!ubyte).then((_) {});
	}

	Promise!void sendHeaders(Header[] headers) {
		import upromised.operations : toAsync;

		return sendHeaders(headers.toAsync);
	}

	Promise!void sendHeaders(PromiseIterator!Header headers) {
		import std.conv : to;

		return headers.each((header) {
			if (header.key == "Content-Length") {
				contentLength = header.value.to!size_t;
			}

			return output.resolve("%s: %s\r\n".format(header.key, header.value).as!ubyte);
		}).then((_) {});
	}

	Promise!void sendBody() {
		return output.resolve("\r\n".as!ubyte).then((_) {});
	}

	Promise!void sendBody(immutable(ubyte)[] data) {
		import upromised.operations : toAsyncChunks;

		return sendBody(data.toAsyncChunks);
	}

	Promise!void sendBody(PromiseIterator!(immutable(ubyte)[]) dataArg) {
		import upromised.tokenizer : Tokenizer;

		if (contentLength > 0) {
			auto data = new Tokenizer!(immutable(ubyte))(dataArg);
			data.limit(contentLength);
			data.partialReceive(true);

			return output.resolve("\r\n".as!ubyte).then((_) => data.read().each((chunk) {
				contentLength -= chunk.length;

				data.limit(contentLength);
				return output.resolve(chunk).then((a) => a && contentLength > 0);
			}).then((_) {}));
		} else {
			auto data = dataArg;
			return output.resolve("Transfer-Encoding: chunked\r\n\r\n".as!ubyte).then((_) => data.each((chunk) {
				return output
					.resolve("%x\r\n".format(chunk.length).as!ubyte)
					.then((_) => output.resolve(chunk))
					.then((_) => output.resolve("\r\n".as!ubyte));
			})).then((_) {
				return output.resolve("0\r\n\r\n".as!ubyte);
			}).then((_) {});
		}
	}
}
unittest {
	const(ubyte)[] request;

	auto a = new ManualStream;
	(new Client(a)).sendRequest(Method.GET, "/sup/moite").then(() => a.shutdown()).nothrow_();
	a.readFromWrite().readAllChunks.then((a) => request = a).nothrow_();

	assert(request == "GET /sup/moite HTTP/1.1\r\n", "%s unexpected".format([cast(const(char)[])request]));
}
unittest {
	const(ubyte)[] request;

	auto a = new ManualStream;
	(new Client(a)).sendRequest(Method.POST, "/sup/moite").then(() => a.shutdown()).nothrow_();
	a.readFromWrite().readAllChunks.then((a) => request = a).nothrow_();

	assert(request == "POST /sup/moite HTTP/1.1\r\n", "%s unexpected".format([cast(const(char)[])request]));
}
unittest {
	const(ubyte)[] request;

	auto a = new ManualStream;
	(new Client(a)).sendHeaders([Header("Oi", "Ola"), Header("Oi2", "Ola2")]).then(() => a.shutdown()).nothrow_();
	a.readFromWrite().readAllChunks.then((a) => request = a).nothrow_();

	assert(request == "Oi: Ola\r\nOi2: Ola2\r\n", "%s unexpected".format([cast(const(char)[])request]));
}
unittest {
	bool called;

	Exception err = new Exception("same");
	auto headers = new PromiseIterator!Header;
	headers.reject(err);
	(new Client()).sendHeaders(headers).then(() {
		assert(false);
	}).except((Exception err2) {
		assert(err2 is err);
		called = true;
	}).nothrow_();

	assert(called);
}
unittest {
	const(ubyte)[] request;

	auto a = new ManualStream;
	(new Client(a)).sendBody().then(() => a.shutdown()).nothrow_();
	a.readFromWrite().readAllChunks.then((a) => request = a).nothrow_();

	assert(request == "\r\n", "%s unexpected".format([cast(const(char)[])request]));
}
unittest {
	import upromised.operations : toAsyncChunks;

	const(ubyte)[] request;

	auto a = new ManualStream;
	auto client = new Client(a);

	client
		.sendRequest(Method.POST, "/supas")
		.then(() => client.sendHeaders([Header("Content-Length", "4")]))
		.then(() => client.sendBody("supasupa".as!ubyte.toAsyncChunks(2)))
		.then(() => a.shutdown())
		.nothrow_();

	a.readFromWrite().readAllChunks.then((a) => request = a).nothrow_();

	assert(request == "POST /supas HTTP/1.1\r\nContent-Length: 4\r\n\r\nsupa", "%s unexpected".format([cast(const(char)[])request]));
}
unittest {
	import std.algorithm : startsWith, endsWith;
	import upromised.operations : toAsyncChunks;

	const(ubyte)[] request;

	auto a = new ManualStream;
	auto client = new Client(a);

	client
		.sendRequest(Method.POST, "/supas")
		.then(() => client.sendHeaders([Header("Host", "www.supa.com")]))
		.then(() => client.sendBody("supasupa".as!ubyte.toAsyncChunks(2)))
		.then(() => a.shutdown())
		.nothrow_();

	a.readFromWrite().readAllChunks.then((a) => request = a).nothrow_();

	auto prefix = "POST /supas HTTP/1.1\r\nHost: www.supa.com\r\nTransfer-Encoding: chunked\r\n\r\n";
	assert(request.startsWith(prefix), "%s unexpected".format([cast(const(char)[])request]));
	assert(request.endsWith("0\r\n\r\n"), "%s unexpected".format([cast(const(char)[])request]));
	auto bodyChunked = request[prefix.length..$];
	const(ubyte)[] body_;

	bodyChunked
		.toAsyncChunks
		.decodeChunked
		.readAllChunks.then((data) => body_ = data);

	assert(body_ == "supasupa", "%s unexpected".format([cast(const(char)[])request]));
}