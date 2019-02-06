module upromised.http;
import std.exception : enforce;
import std.format : format;
import upromised.manual_stream : ManualStream;
import upromised.operations : readAllChunks;
import upromised.promise : DelegatePromiseIterator, Promise, PromiseIterator;
import upromised.stream : Stream;
import upromised.tokenizer : Tokenizer;

struct Header {
	string key;
	string value;
}

enum Method {
	GET, POST, PUT, DELETE
}

struct Response {
	int statusCode;
	string statusLine;
}

struct FullResponse {
	Response response;
	Header[] headers;
	PromiseIterator!(const(ubyte)[]) bodyData;
}

private inout(Y)[] as(Y, T)(inout(T) input) {
	return cast(inout(Y)[])input;
}

PromiseIterator!(const(ubyte)[]) decodeChunked(PromiseIterator!(const(ubyte)[]) chunked) nothrow {
	return decodeChunked(new Tokenizer!(const(ubyte))(chunked));
}

PromiseIterator!(const(ubyte)[]) decodeChunked(Tokenizer!(const(ubyte)) tokenizer) nothrow {
	import std.conv : to;

	tokenizer.partialReceive();
	tokenizer.limit();
	tokenizer.separator("\r\n");

	return new class PromiseIterator!(const(ubyte)[]) {
		size_t chunkSize = -1;

		override Promise!ItValue next(Promise!bool) nothrow {
			if (chunkSize == 0) {
				return Promise!ItValue.resolved(ItValue(true));
			}

			bool step;
			const(ubyte)[] chunkR;
			return tokenizer.read().each((chunk) {
				step = !step;
				if (step) {
					tokenizer.separator();
					chunkSize = chunk.as!char[0..$-2].to!size_t(16);
					tokenizer.limit(chunkSize + 2);
					return true;
				} else {
					tokenizer.separator("\r\n");
					tokenizer.limit();
					chunkR = chunk[0..$-2];
					return false;
				}
			}).then((eof) => eof ? ItValue(true) : ItValue(false, chunkR));
		}
	};
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

	auto rejected = new DelegatePromiseIterator!(const(ubyte)[]);
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
	import upromised.tokenizer : Tokenizer;

	size_t contentLength;
	bool chunked;
	Tokenizer!(const(ubyte)) inputTokenizer;

public:
	DelegatePromiseIterator!(immutable(ubyte)[]) output;

	this() nothrow {
		output = new DelegatePromiseIterator!(immutable(ubyte)[]);
	}
	
	this(Stream stream) nothrow {
		this();
		this.stream = stream;
	}

	Promise!void stream(Stream stream) nothrow {
		assert(!inputTokenizer);
		
		inputTokenizer = new Tokenizer!(const(ubyte))(stream.read());

		return output
			.each((data) => stream.write(data))
			.then(() {});
	}

	Promise!FullResponse fullRequest(Method method, string uri, Header[] headers, immutable(ubyte)[] bodyData) nothrow {
		import upromised.operations : toAsync, toAsyncChunks;

		return fullRequest(method, uri, headers.toAsync, bodyData.toAsyncChunks);
	}

	Promise!FullResponse fullRequest(Method method, string uri, PromiseIterator!Header headers, immutable(ubyte)[] bodyData) nothrow {
		import upromised.operations : toAsyncChunks;

		return fullRequest(method, uri, headers, bodyData.toAsyncChunks);
	}

	Promise!FullResponse fullRequest(Method method, string uri, Header[] headers, PromiseIterator!(immutable(ubyte)[]) bodyData = null) nothrow {
		import upromised.operations : toAsync;
		
		return fullRequest(method, uri, headers.toAsync, bodyData);
	}

	Promise!FullResponse fullRequest(Method method, string uri, PromiseIterator!Header headers, PromiseIterator!(immutable(ubyte)[]) bodyData = null) nothrow {
		import upromised.operations : readAll;
		
		FullResponse r;
		return sendRequest(method, uri)
		.then(() => sendHeaders(headers))
		.then(() {
			if (bodyData !is null) {
				return sendBody(bodyData);
			} else {
				return sendBody();
			}
		}).then(() => fetchResponse())
		.then((response) => r.response = response)
		.then((_) => fetchHeaders().readAll)
		.then((headers) => r.headers = headers)
		.then((_) => r.bodyData = fetchBody())
		.then((_) => r);
	}

	Promise!void sendRequest(Method method, string uri) nothrow {
		return Promise!void.resolved()
		.then(() => output.resolve("%s %s HTTP/1.1\r\n".format(method, uri).as!ubyte))
		.then((_) {});
	}

	Promise!void sendHeaders(Header[] headers) nothrow {
		import upromised.operations : toAsync;

		return sendHeaders(headers.toAsync);
	}

	Promise!void sendHeaders(PromiseIterator!Header headers) nothrow {
		import std.conv : to;

		return headers.each((header) {
			if (header.key == "Content-Length") {
				contentLength = header.value.to!size_t;
			}

			return output.resolve("%s: %s\r\n".format(header.key, header.value).as!ubyte);
		}).then((_) {});
	}

	Promise!void sendBody() nothrow {
		return output.resolve("\r\n".as!ubyte).then((_) {});
	}

	Promise!void sendBody(immutable(ubyte)[] data) nothrow {
		import upromised.operations : toAsyncChunks;

		return sendBody(data.toAsyncChunks);
	}

	Promise!void sendBody(PromiseIterator!(immutable(ubyte)[]) dataArg) nothrow {
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

	Promise!Response fetchResponse() nothrow {
		import std.array : join;
		import std.conv : to;
		import std.string : split;

		contentLength = 0;
		chunked = false;

		inputTokenizer.partialReceive();
		inputTokenizer.limit();
		inputTokenizer.separator("\r\n");

		Response r;
		return inputTokenizer.read().each((response) {
			const(char)[][] responseParts = response.as!char[0..$-2].split(" ");
			enforce(responseParts.length > 2, "%s should be two parts. %s".format(responseParts, [response]));
			enforce(responseParts[0] == "HTTP/1.1");
			r.statusCode = responseParts[1].to!int;
			r.statusLine = responseParts[2..$].join(" ").idup;
			return false;
		}).then((_) => r);
	}

	PromiseIterator!Header fetchHeaders() nothrow {
		import std.algorithm : countUntil;
		import std.conv : to;

		inputTokenizer.partialReceive();
		inputTokenizer.limit();
		inputTokenizer.separator("\r\n");
		
		return new class PromiseIterator!Header {
			override Promise!ItValue next(Promise!bool) {
				ItValue result;
				return inputTokenizer.read().each((headerLine) {
					if (headerLine.as!char == "\r\n") {
						result.eof = true;
						return false;
					}

					auto pos = headerLine.as!char.countUntil(": ");
					Header header = Header(headerLine.as!char[0..pos], headerLine.as!char[pos + 2..$-2]);
					result.value = header;

					if (header.key == "Content-Length") {
						contentLength = header.value.to!size_t;
					}

					if (header.key == "Transfer-Encoding" && header.value == "chunked") {
						chunked = true;
					}
					
					return false;
				}).then((_) => result);
			}
		};
	}

	PromiseIterator!(const(ubyte)[]) fetchBody() nothrow {
		if (chunked) {
			return decodeChunked(inputTokenizer);
		}
		
		inputTokenizer.partialReceive(true);
		inputTokenizer.limit(contentLength);
		inputTokenizer.separator();

		return new class PromiseIterator!(const(ubyte)[]) {
			override Promise!ItValue next(Promise!bool) {
				if (contentLength == 0) {
					return Promise!ItValue.resolved(ItValue(true));
				}

				ItValue result;
				return inputTokenizer.read().each((chunk) {
					contentLength -= chunk.length;
					inputTokenizer.limit(contentLength);
					result.value = chunk;
					return false;
				}).then((eof) => eof ? ItValue(true) : result);
			}
		};
	}

	Tokenizer!(const(ubyte)) release() nothrow {
		import std.algorithm : swap;

		Tokenizer!(const(ubyte)) released;
		inputTokenizer.swap(released);
		return released;
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
	auto headers = new DelegatePromiseIterator!Header;
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
		.readAllChunks.then((data) => body_ = data)
		.nothrow_;

	assert(body_ == "supasupa", "%s unexpected".format([cast(const(char)[])request]));
}
unittest {
	import upromised.operations : toAsyncChunks, readAll;

	string responseData = 
	"HTTP/1.1 301 Moved Permanently\r\n" ~
	"Date: Thu, 30 Mar 2017 17:02:29 GMT\r\n" ~
	"Set-Cookie: WMF-Last-Access=30-Mar-2017;Path=/;HttpOnly;secure;Expires=Mon, 01 May 2017 12:00:00 GMT\r\n" ~
	"Set-Cookie: WMF-Last-Access-Global=30-Mar-2017;Path=/;Domain=.wikipedia.org;HttpOnly;secure;Expires=Mon, 01 May 2017 12:00:00 GMT\r\n" ~
	"Location: https://en.wikipedia.org/\r\n" ~
	"Content-Length: 0\r\n\r\n";

	Response response;
	Header[] headers;
	const(ubyte)[] data;

	auto a = new ManualStream;
	auto client = new Client(a);

	client
		.fetchResponse
		.then((responseArg) { response = responseArg; } )
		.then(() => client.fetchHeaders().readAll())
		.then((headersArg) { headers = headersArg; })
		.then(() => client.fetchBody().readAllChunks())
		.then((dataArg) { data = dataArg;})
		.nothrow_();

	responseData
		.as!ubyte
		.toAsyncChunks(13)
		.each((chunk) => a.writeToRead(chunk).then(() {}))
		.then((_) => a.writeToRead())
		.nothrow_();

	assert(response.statusCode == 301);
	assert(response.statusLine == "Moved Permanently");
	assert(headers[0] == Header("Date", "Thu, 30 Mar 2017 17:02:29 GMT"));
	assert(headers[1] == Header("Set-Cookie", "WMF-Last-Access=30-Mar-2017;Path=/;HttpOnly;secure;Expires=Mon, 01 May 2017 12:00:00 GMT"));
	assert(headers[2] == Header("Set-Cookie", "WMF-Last-Access-Global=30-Mar-2017;Path=/;Domain=.wikipedia.org;HttpOnly;secure;Expires=Mon, 01 May 2017 12:00:00 GMT"));
	assert(headers[3] == Header("Location", "https://en.wikipedia.org/"));
	assert(headers[4] == Header("Content-Length", "0"));
	assert(headers.length == 5);
	assert(data.length == 0);
}
unittest {
	import upromised.operations : toAsyncChunks, readAll;

	string responseData = 
	"HTTP/1.1 200 OK\r\n" ~
	"Server: nginx\r\n" ~
	"Date: Thu, 30 Mar 2017 22:32:32 GMT\r\n" ~
	"Content-Type: text/plain; charset=UTF-8\r\n" ~
	"Content-Length: 15\r\n" ~
	"Connection: close\r\n" ~
	"Access-Control-Allow-Origin: *\r\n" ~
	"Access-Control-Allow-Methods: GET\r\n" ~
	"\r\n" ~
	"192.30.253.112\n";

	Response response;
	Header[] headers;
	const(ubyte)[] data;

	auto a = new ManualStream;
	auto client = new Client(a);

	client
		.fetchResponse
		.then((responseArg) { response = responseArg; } )
		.then(() => client.fetchHeaders().readAll())
		.then((headersArg) { headers = headersArg; })
		.then(() => client.fetchBody().readAllChunks())
		.then((dataArg) { data = dataArg;})
		.nothrow_();

	responseData
		.as!ubyte
		.toAsyncChunks(11)
		.each((chunk) => a.writeToRead(chunk).then((){}))
		.nothrow_();

	assert(response.statusCode == 200);
	assert(response.statusLine == "OK");
	assert(headers[0] == Header("Server", "nginx"));
	assert(headers[1] == Header("Date", "Thu, 30 Mar 2017 22:32:32 GMT"));
	assert(headers[2] == Header("Content-Type", "text/plain; charset=UTF-8"));
	assert(headers[3] == Header("Content-Length", "15"));
	assert(headers[4] == Header("Connection", "close"));
	assert(headers[5] == Header("Access-Control-Allow-Origin", "*"));
	assert(headers[6] == Header("Access-Control-Allow-Methods", "GET"));
	assert(headers.length == 7);
	assert(data == "192.30.253.112\n");
}
unittest {
	import upromised.operations : toAsyncChunks, readAll;

	string responseData = 
	"HTTP/1.1 200 OK\r\n" ~
	"Date: Thu, 30 Mar 2017 23:24:14 GMT\r\n" ~
	"Content-Type: text/plain;charset=utf-8\r\n" ~
	"Transfer-Encoding: chunked\r\n" ~
	"Connection: keep-alive\r\n" ~
	"Pragma: no-cache\r\n" ~
	"Vary: Accept-Encoding\r\n" ~
	"Server: cloudflare-nginx\r\n" ~
	"\r\n" ~
	"14\r\n" ~
	"6\n5\n3\n1\n1\n2\n4\n3\n3\n6\n\r\n" ~
	"0\r\n" ~
	"\r\n";

Response response;
	Header[] headers;
	const(ubyte)[] data;

	auto a = new ManualStream;
	auto client = new Client(a);

	client
		.fetchResponse
		.then((responseArg) { response = responseArg; } )
		.then(() => client.fetchHeaders().readAll())
		.then((headersArg) { headers = headersArg; })
		.then(() => client.fetchBody().readAllChunks())
		.then((dataArg) { data = dataArg;})
		.nothrow_();

	responseData
		.as!ubyte
		.toAsyncChunks(11)
		.each((chunk) => a.writeToRead(chunk).then((){}))
		.then((_) => a.writeToRead())
		.nothrow_();

	assert(response.statusCode == 200);
	assert(response.statusLine == "OK");
	assert(headers[0] == Header("Date", "Thu, 30 Mar 2017 23:24:14 GMT"));
	assert(headers[1] == Header("Content-Type", "text/plain;charset=utf-8"));
	assert(headers[2] == Header("Transfer-Encoding", "chunked"));
	assert(headers[3] == Header("Connection", "keep-alive"));
	assert(headers[4] == Header("Pragma", "no-cache"));
	assert(headers[5] == Header("Vary", "Accept-Encoding"));
	assert(headers[6] == Header("Server", "cloudflare-nginx"));
	assert(headers.length == 7);
	assert(data == "6\n5\n3\n1\n1\n2\n4\n3\n3\n6\n");
}