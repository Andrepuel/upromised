module upromised;
import std.format : format;

void fatal(Throwable e = null, string file = __FILE__, ulong line = __LINE__) {
    import core.stdc.stdlib : abort;
    import std.stdio : stderr;
    stderr.writeln("%s(%s): Fatal error".format(file, line));
    if (e) {
        stderr.writeln(e);
    }
    abort();
}