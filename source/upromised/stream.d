module upromised.stream;
import std.socket : Address;
import upromised.promise : Promise, PromiseIterator;
import upromised : fatal;

class Interrupted : Exception {
public:
	this() nothrow {
		super("Operation interrupted");
	}
}

interface Stream {
    Promise!void close() nothrow;
    Promise!void shutdown() nothrow;
    PromiseIterator!(const(ubyte)[]) read() nothrow;
    Promise!void write(immutable(ubyte)[]) nothrow;
}

struct Datagram {
	Address addr;
	const(ubyte)[] message;
}

interface DatagramStream {
	Promise!void sendTo(Address dest, immutable(ubyte)[] message) nothrow;
	PromiseIterator!Datagram recvFrom() nothrow;
	Promise!void close() nothrow;
}