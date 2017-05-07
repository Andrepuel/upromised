module upromised.process;
import core.stdc.signal : SIGINT;
import deimos.libuv.uv : uv_loop_t, uv_process_t;
import upromised.loop : Loop;
import upromised.memory : gcrelease, gcretain, getSelf;
import upromised.pipe : Pipe;
import upromised.promise : DelegatePromise, Promise;
import upromised.uv : handle, stream, uvCheck;

shared static this() {
	import core.stdc.signal : signal, SIG_IGN;
	import core.sys.posix.signal : SIGPIPE;
	signal(SIGPIPE, SIG_IGN);
}

class Process {
private:
	DelegatePromise!long wait_;

public:
	__gshared Pipe STDIN;
	__gshared Pipe STDOUT;
	__gshared Pipe STDERR;
	shared static this() {
		import std.stdio : stderr, stdin, stdout;
		STDIN = cast(Pipe)cast(void*)&stdin;
		STDOUT = cast(Pipe)cast(void*)&stdout;
		STDERR = cast(Pipe)cast(void*)&stderr;
	}

	uv_process_t self;
	this(Loop loop, string[] argsD, Pipe stdin = null, Pipe stdout = null, Pipe stderr = null) {
		this(cast(uv_loop_t*)loop.inner(), argsD, stdin, stdout, stderr);
	}

	this(uv_loop_t* loop, string[] argsD, Pipe stdin = null, Pipe stdout = null, Pipe stderr = null) {
		import deimos.libuv.uv : uv_process_options_t, uv_close, uv_spawn, uv_stdio_container_t, uv_stdio_flags;
		import std.algorithm : map;
		import std.array : array;
		import std.stdio : File;
		import std.string : toStringz;

		wait_ = new DelegatePromise!long;
		uv_process_options_t options;
		options.exit_cb = (self, exit_status, term_signal) nothrow {
			self.getSelf!Process.wait_.resolve(exit_status);
		};

		uv_stdio_container_t[3] io;
		foreach(i, pipe; [stdin, stdout, stderr]) {
			if (pipe is STDIN || pipe is STDOUT || pipe is STDERR) {
				io[i].flags = uv_stdio_flags.UV_INHERIT_FD;
				io[i].data.fd = (cast(File*)cast(void*)pipe).fileno;
			} else if (pipe !is null) {
				io[i].flags = uv_stdio_flags.UV_CREATE_PIPE;
				if (i == 0) {
					io[i].flags |= uv_stdio_flags.UV_WRITABLE_PIPE;
				} else {
					io[i].flags |= uv_stdio_flags.UV_READABLE_PIPE;
				}
				io[i].data.stream = pipe.self.stream;
			} else {
				io[i].flags = uv_stdio_flags.UV_IGNORE;
			}
		}

		auto args = argsD.map!(x => x.toStringz).array;
		args ~= null;
		options.file = args[0];
		options.args = cast(char**)args.ptr;
		options.stdio_count = 3;
		options.stdio = io.ptr;
		uv_spawn(loop, &self, &options).uvCheck();
		gcretain(this);
		wait_.finall(() {
			uv_close(self.handle, (selfSelf) nothrow {
				gcrelease(selfSelf.getSelf!Process);
			});
		});
	}

	Promise!long wait() nothrow {
		return wait_;
	}

	void kill(int signal = SIGINT) {
		import deimos.libuv.uv : uv_process_kill;
		
		uv_process_kill(&self, signal).uvCheck();
	}
}