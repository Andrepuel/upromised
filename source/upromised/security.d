module upromised.security;
version(hasSecurity):
import std.exception : enforce;
import std.format : format;
import upromised.promise : Promise, PromiseIterator;
import upromised.stream : Stream;

extern (C) {
	enum OSStatus {
		noErr = 0,
		errSSLWouldBlock = -9803
	}

	enum SSLProtocolSide {
		kSSLServerSide,
		kSSLClientSide
	}
	
	enum SSLConnectionType {
		kSSLStreamType,
		kSSLDatagramType
	}

	alias SSLConnectionRef = TlsStream;

	alias SSLReadFunc = OSStatus function(SSLConnectionRef connection, void *data, size_t* dataLength);
	alias SSLWriteFunc = OSStatus function(SSLConnectionRef connection, const(void)* data, size_t* dataLength);

	struct SSLContext;
	SSLContext* SSLCreateContext(void* allocator, SSLProtocolSide protocolSide, SSLConnectionType connectionType) nothrow;
	void CFRelease(SSLContext*) nothrow;
	OSStatus SSLSetIOFuncs(SSLContext* context, SSLReadFunc readFunc, SSLWriteFunc writeFunc) nothrow;
	OSStatus SSLSetConnection(SSLContext* context, SSLConnectionRef connection) nothrow;
	OSStatus SSLSetPeerDomainName(SSLContext* context, const(char) *peerName, size_t peerNameLen) nothrow;
	OSStatus SSLHandshake(SSLContext* context) nothrow;
	OSStatus SSLClose(SSLContext* context) nothrow;
	OSStatus SSLWrite(SSLContext* context, const(void)* data, size_t dataLength, size_t *processed) nothrow;
	OSStatus SSLRead(SSLContext* context, const(void)* data, size_t dataLength, size_t *processed) nothrow;
}

class OSStatusError : Exception {
	this(OSStatus status, string file = __FILE__, size_t line = __LINE__) {
		this.status = status;
		super("OSStatus(%s)".format(status), file, line);
	}

	OSStatus status;
}

private Promise!T readOne(T)(PromiseIterator!T read) nothrow {
	T r;
	return read.each((chunk) {
		r = chunk;
		return false;
	}).then((_) => r);
}

class TlsStream : Stream {
private:
	Stream underlying;
	SSLContext* context;
	ubyte[] readBuffer;
	Promise!void pendingWrite;

	OSStatus tryRead(void* dataArg, size_t* dataLength) nothrow {
		ubyte[] data = (cast(ubyte*)dataArg)[0..*dataLength];
		
		if (readBuffer.length >= *dataLength) {
			size_t n = *dataLength;
			data[] = readBuffer[0..n];
			readBuffer = readBuffer[n..$];

			return OSStatus.noErr;
		}
		
		*dataLength = 0;
		return OSStatus.errSSLWouldBlock;
	}

	OSStatus tryWrite(const(void)* dataArg, size_t* dataLength) nothrow {
		if (pendingWrite !is null) {
			*dataLength = 0;
			return OSStatus.errSSLWouldBlock;
		}

		const(ubyte)[] data = (cast(const(ubyte)*)dataArg)[0..*dataLength];
		pendingWrite = underlying.write(data.idup);
		return OSStatus.noErr;
	}

	Promise!OSStatus tryOperate(alias f, Args...)(size_t* operated, Args args) nothrow {
		OSStatus r = f(args);
		if (r == OSStatus.noErr || (operated !is null && *operated > 0)) {
			return (pendingWrite is null ? Promise!void.resolved() : pendingWrite).then(() {
				pendingWrite = null;
				return r;
			});
		}
		
		if (r == OSStatus.errSSLWouldBlock) {
			if (pendingWrite !is null) {
				return pendingWrite.then(() {
					pendingWrite = null;
					return r;
				});
			}

			return underlying.read().readOne().then((chunk) {
				readBuffer ~= chunk;
				return r;
			});
		}

		return Promise!OSStatus.resolved(r);
	}

	Promise!OSStatus operate(alias f, Args...)(Args args) {
		return tryOperate!f(null, args).then((r) {
			if (r == OSStatus.errSSLWouldBlock) {
				return operate!f(args);
			}
			
			return Promise!OSStatus.resolved(r);
		});
	}
public:
	this(Stream underlying) {
		this.underlying = underlying;
		context = SSLCreateContext(null, SSLProtocolSide.kSSLClientSide, SSLConnectionType.kSSLStreamType);
		enforce(context !is null);
		SSLSetIOFuncs(context, (self, a1, a2) => self.tryRead(a1, a2), (self, a1, a2) => self.tryWrite(a1, a2));
		SSLSetConnection(context, this);
	}

	~this() {
		if (context !is null) {
			CFRelease(context);
		}
	}

	Promise!void connect(string hostname = null) nothrow {
		return Promise!void.resolved().then(() {
			auto status = SSLSetPeerDomainName(context, hostname.ptr, hostname.length);
			if (status != OSStatus.noErr) {
				throw new OSStatusError(status);
			}
			return;
		}).then(() => operate!SSLHandshake(context)).then((status) {
			if (status != OSStatus.noErr) {
				throw new OSStatusError(status);
			}
		});
	}

	override Promise!void close() nothrow {
		return underlying.close();
	}
	override Promise!void shutdown() nothrow {
		return operate!SSLClose(context).then((status) {
			if (status != OSStatus.noErr) {
				throw new OSStatusError(status);
			}
		});
	}
	override Promise!void write(immutable(ubyte)[] data) nothrow {
		if (data.length == 0) {
			return Promise!void.resolved();
		}
		
		size_t processed;
		return tryOperate!SSLWrite(&processed, context, data.ptr, data.length, &processed).then((status) {
			if (status != OSStatus.noErr && status != OSStatus.errSSLWouldBlock) {
				throw new OSStatusError(status);
			}

			return write(data[processed..$]);
		});
	}

	override PromiseIterator!(const(ubyte)[]) read() nothrow {
		return new class PromiseIterator!(const(ubyte)[]) {
			override Promise!ItValue next(Promise!bool) {
				return readOne().then((chunk) => chunk ? ItValue(false, chunk) : ItValue(true));
			}
		};
	}
protected:
	Promise!(const(ubyte)[]) readOne() nothrow {
		const(ubyte)[] r;
		return readOne(new ubyte[1024])
		.then((chunk) nothrow {
			r = chunk;
		}).except((OSStatusError e) {
			if (e.status == -9805) {
			} else {
				throw e;
			}
		}).then(() => r);
	}

	Promise!(const(ubyte)[]) readOne(ubyte[] data) nothrow {
		size_t processed;
		return tryOperate!SSLRead(&processed, context, data.ptr, data.length, &processed).then((status) {
			if (status != OSStatus.noErr && status != OSStatus.errSSLWouldBlock) {
				throw new OSStatusError(status);
			}

			if (processed > 0) {
				return Promise!(const(ubyte)[]).resolved(data[0..processed]);
			}

			return readOne(data);
		});
	}
}