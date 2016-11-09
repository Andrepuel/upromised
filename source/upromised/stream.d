module upromised.stream;
import upromised.promise : Promise, PromiseIterator;

interface Stream {
    Promise!void close() nothrow;
    Promise!void shutdown() nothrow;
    PromiseIterator!(const(ubyte)[]) read() nothrow;
    Promise!void write(immutable(ubyte)[]) nothrow;
}