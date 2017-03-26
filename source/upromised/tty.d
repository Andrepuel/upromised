module upromised.tty;
import deimos.libuv.uv;
import deimos.libuv._d;
import std.stdio : File;
import upromised.promise : Promise;
import upromised.uv : uvCheck;
import upromised.uv_stream : UvStream;

class TtyStream : UvStream!uv_tty_t {
public:
	this(uv_loop_t* ctx, File tty) {
		import std.stdio : stdin;

		super(ctx);
		uv_tty_init(ctx, &self, tty.fileno, tty == stdin).uvCheck();
	}

	override Promise!void shutdown() nothrow {
		return Promise!void.resolved();
	}
}
