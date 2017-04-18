module upromised.pipe;
import deimos.libuv.uv : uv_loop_t, uv_pipe_t;
import upromised.loop : Loop;
import upromised.memory : gcrelease, gcretain, getSelf;
import upromised.promise : Promise;
import upromised.uv_stream : UvStream;
import upromised.uv : uvCheck, UvError;

class Pipe : UvStream!uv_pipe_t {
public:
	this(Loop loop) {
		this(cast(uv_loop_t*)loop.inner());
	}

	this(uv_loop_t* ctx) {
		import deimos.libuv.uv : uv_pipe_init, uv_pipe_open;
		
		uv_pipe_init(ctx, &self, 0).uvCheck();
		super(ctx);
	}
}