module upromised.process;
import core.stdc.signal : SIGINT;
import deimos.libuv.uv : uv_loop_t, uv_process_t;
import std.stdio : File;
import upromised.loop : Loop;
import upromised.memory : gcrelease, gcretain, getSelf;
import upromised.stream : Stream;
import upromised.pipe : Pipe;
import upromised.promise : DelegatePromise, Promise, PromiseIterator;
import upromised.uv : handle, stream, uvCheck;

shared static this() {
	import core.stdc.signal : signal, SIG_IGN;
	import core.sys.posix.signal : SIGPIPE;
	signal(SIGPIPE, SIG_IGN);
}

class StdPipe {
public:
	File file;

	this(File file) {
		this.file = file;
	}
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
		STDIN = cast(Pipe)cast(void*)(new StdPipe(stdin));
		STDOUT = cast(Pipe)cast(void*)(new StdPipe(stdout));
		STDERR = cast(Pipe)cast(void*)(new StdPipe(stderr));
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

		import core.stdc.stdlib : malloc, free;
		uv_stdio_container_t[] io = (cast(uv_stdio_container_t*)malloc(uv_stdio_container_t.sizeof*3))[0..3];
		scope(exit) free(io.ptr);
		foreach(i, pipe; [stdin, stdout, stderr]) {
			StdPipe stdpipe = cast(StdPipe)cast(Object)cast(void*)pipe;
			if (stdpipe !is null) {
				io[i].flags = uv_stdio_flags.UV_INHERIT_FD;
				io[i].data.fd = stdpipe.file.fileno;
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

	static Stream stream(Loop loop, string[] args, Pipe stderr = Process.STDERR) {
		return new class Stream {
			Pipe stdin;
			Pipe stdout;
			Process process;

			this() {
				stdin = new Pipe(loop);
				stdout = new Pipe(loop);
				process = new Process(loop, args, stdin, stdout, stderr);
			}

			Promise!void shutdown() nothrow {
				return stdin.shutdown();
			}

			Promise!void close() nothrow {
				return Promise!void.resolved().
				then(() => process.kill())
				.finall(() => stdin.close())
				.then(() => process.wait())
				.finall(() => stdout.close())
				.then((_) {});
			}

			PromiseIterator!(const(ubyte)[]) read() nothrow {
				return stdout.read();
			}

			Promise!void write(immutable(ubyte)[] data) nothrow {
				return stdin.write(data);
			}
		};
	}
}
