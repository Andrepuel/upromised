module upromised.backtrace;
import core.runtime : Runtime, TraceHandler;

struct BaseStack {
	Throwable.TraceInfo base;
	size_t delegate() skip;
}

struct PromiseTraceHandler {
	TraceHandler original;
	BaseStack base;
}

Throwable.TraceInfo dgTraceInfo(void delegate(void delegate(const(char[]) value, int* stop)) impl) nothrow {
	return new class Throwable.TraceInfo {
		override int opApply(scope int delegate(ref const(char[])) dg) const {
			return opApply((ref size_t, ref const(char[]) buf) {
				return dg(buf);
			});
		}

		override int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const {
			ulong count;
			impl((value, stop) {
				*stop = dg(count, value);
				++count;
			});
			return 0;
		}

		override string toString() const {
			string bt;
			this.opApply((ref size_t a, ref const(char[]) b) {
				bt ~= b;
				bt ~= "\n";
				return 0;
			});
			return bt;
		}
	};
}
Throwable.TraceInfo traceinfo(string[] list) nothrow {
	return dgTraceInfo((cb) {
		int r;
		auto listIt = list;
		while (r == 0) {
			if (listIt.length == 0) return;
			cb(listIt[0], &r);
			listIt = listIt[1..$];
		}
	});
}
Throwable.TraceInfo concat(Throwable.TraceInfo a, Throwable.TraceInfo b) nothrow {
	import core.stdc.stdlib : abort;
	if (!(a !is null)) abort();
	if (!(b !is null)) abort();
	return dgTraceInfo((cb) {
		int r;
		a.opApply((ref const(char[]) v) {
			cb(v, &r);
			return r;
		});
		if (r == 0) b.opApply((ref const(char[]) v) {
			cb(v, &r);
			return r;
		});
	});
}
ulong length(Throwable.TraceInfo info) {
	size_t total;
	foreach(_; info) {
		total++;
	}
	return total;
}

Throwable.TraceInfo trimTrail(Throwable.TraceInfo info, ulong amount) nothrow {
	return trimTrailDg(info, () => amount);
}
Throwable.TraceInfo trimTrailDg(Throwable.TraceInfo info, ulong delegate() amountDg) nothrow {
	return dgTraceInfo((cb) {
		size_t total = info.length;
		size_t amount = amountDg();
		size_t limit = total >= amount ? total - amount : 0;
		int r;
		info.opApply((ref const(char[]) v) {
			if (limit-- == 0) return 1;
			cb(v, &r);
			return r;
		});
	});
}
Throwable.TraceInfo skipMagic(Throwable.TraceInfo a, string magic) nothrow {
	import std.algorithm : countUntil;

	magic = magic[1..$];
	return dgTraceInfo((cb) {
		bool skipping = true;
		int r;
		a.opApply((ref const(char[]) v) {
			if (skipping) {
				if (v.countUntil(magic) >= 0) {
					skipping = false;
				}
				return 0;
			} else {
				cb(v, &r);
				return r;
			}
		});
	});
}

private __gshared PromiseTraceHandler handler;
enum handlerFuncMagic = "___98371_realBacktraceMagic_31810";
pragma(mangle, handlerFuncMagic) Throwable.TraceInfo handlerFunc(void* pos) {
	import core.runtime : defaultTraceHandler;

	return realBacktrace(pos, handlerFuncMagic).trimTrailDg(handler.base.skip).concat(handler.base.base);
}

static this() {
	import core.runtime : defaultTraceHandler;

	handler.base.base = [].traceinfo;
	handler.original = &defaultTraceHandler;
	Runtime.traceHandler(&handlerFunc);
}

enum realBacktraceMagic = "___38912_realBacktrace_32191";
pragma(mangle, realBacktraceMagic) pragma(inline, false) Throwable.TraceInfo realBacktrace(void* pos, string skipMagicString = realBacktraceMagic) nothrow {
	return wa1(pos).skipMagic(skipMagicString);
}
// Dlang skip a few frames to remove internal function from stack traces. But sometimes this does not work.
// Using a magic name to remove the internal function always works.
pragma(inline, false) Throwable.TraceInfo wa1(void* pos) nothrow {
	return wa2(pos);
}
pragma(inline, false) Throwable.TraceInfo wa2(void* pos) nothrow {
	return wa3(pos);
}
pragma(inline, false) Throwable.TraceInfo wa3(void* pos) nothrow {
	return wa4(pos);
}
pragma(inline, false) Throwable.TraceInfo wa4(void* pos) nothrow {
	try {
		return handler.original(pos);
	} catch(Exception e) {
		assert(false);
	}
}

BaseStack setBasestack(Throwable.TraceInfo backBt) nothrow {
	import std.array : array;

	auto prev = handler.base;
	handler.base.base = backBt;
	auto skip = realBacktrace(null);
	try {
		handler.base.skip = () => skip.length - 1;
	} catch(Exception) {
		assert(false);
	}
	return prev;
}

void recoverBasestack(BaseStack a) nothrow {
	handler.base = a;
}

enum backtrace_magic = "892179_backtrace_381243";
pragma(mangle, backtrace_magic) Throwable.TraceInfo backtrace(void* pos = null, string skipMagicValue = backtrace_magic) nothrow {
	try {
		return Runtime.traceHandler()(pos).skipMagic(skipMagicValue);
	} catch(Exception) {
		assert(false);
	}
}