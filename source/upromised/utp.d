module upromised.utp;

import std.format : format;
import std.socket : Address;
import upromised.c.utp;
import upromised.loop : Loop;
import upromised.memory : gcrelease, gcretain;
import upromised.promise : DelegatePromise, DelegatePromiseIterator, Promise, PromiseIterator;
import upromised.stream : DatagramStream, Interrupted, Stream;

private auto noth(alias f, Args...)(Args args) {
	try {
		return f(args);
	} catch(Exception) {
		import core.stdc.stdlib : abort;
		abort();
		assert(false);
	}
}

class CumulativeBuffer: PromiseIterator!(const(ubyte)[]) {
protected:
	ubyte[] pending;
	bool eof;
	DelegatePromise!ItValue pendingReq;

	void onDrain() {
	}

public:
	size_t pendingLength() const {
		return pending.length;
	}

	override Promise!ItValue next(Promise!bool _) {
		if (pending.length > 0) {
			auto done = pending;
			pending = pending[$..$];
			return Promise!ItValue.resolved(ItValue(false, done));
		}

		if (eof) {
			return Promise!ItValue.resolved(ItValue(true));
		}

		assert(pendingReq is null);
		pendingReq = new DelegatePromise!ItValue;
		return pendingReq;
	}

	void append(const(ubyte)[] data) {
		if (pendingReq !is null) {
			assert(pending.length == 0);
			auto done = pendingReq;
			pendingReq = null;
			done.resolve(ItValue(false, data));
			return;
		}

		pending ~= data;
	}

	void resolve() {
		this.eof = true;

		if (pendingReq !is null) {
			assert(pending.length == 0);
			auto done = pendingReq;
			pendingReq = null;
			done.resolve(ItValue(true));
		}
	}
}

class UtpContext {
private:
	int count;

	utp_context* context;
	DatagramStream underlying;
	DelegatePromiseIterator!(utp_socket*) sockets;

public:
	this(Loop loop, DatagramStream underlying) {
		import std.datetime : msecs;
		import upromised.dns : toAddress;
		import upromised.promise : break_, continue_, do_while;

		context = utp_init(2);
		assert(context !is null);
		count++;
		utp_context_set_userdata(context, cast(void*)cast(Object)this);
		this.underlying = underlying;

		utp_set_callback(context, UTP_SENDTO, (args) {
			auto self = cast(UtpContext)cast(Object)utp_context_get_userdata(args.context);
			auto addr = args.address.toAddress(args.address_len);
			auto data = (cast(const(ubyte)*)args.buf)[0..args.len].idup;
			self.underlying.sendTo(addr, data)
			.except((Exception e) {
				import std.stdio : stderr;
				debug stderr.writeln(e);
			}).nothrow_;
			return 0;
		});

		utp_set_callback(context, UTP_ON_FIREWALL, (args) {
			auto self = cast(UtpContext)cast(Object)utp_context_get_userdata(args.context);
			return self.sockets is null;
		});

		utp_set_callback(context, UTP_ON_ERROR, (args) {
			auto socket = cast(UtpStream)cast(Object)utp_get_userdata(args.socket);
			assert(socket !is null);
			socket.on_error(args.error_code);
			return 0;
		});

		utp_set_callback(context, UTP_ON_READ, (args) {
			auto socket = cast(UtpStream)cast(Object)utp_get_userdata(args.socket);
			assert(socket !is null);
			socket.on_read((cast(ubyte*)args.buf)[0..args.len]);
			return 0;
		});

		utp_set_callback(context, UTP_GET_READ_BUFFER_SIZE, (args) {
			auto socket = cast(UtpStream)cast(Object)utp_get_userdata(args.socket);
			if (socket is null) {
				return 4096;
			}

			assert(socket !is null);
			return socket.recv_buffer();
		});

		utp_set_callback(context, UTP_ON_STATE_CHANGE, (args) {
			auto socket = cast(UtpStream)cast(Object)utp_get_userdata(args.socket);
			if (socket is null) {
				return 0;
			}
			socket.on_state(args.state);
			return 0;
		});

		utp_set_callback(context, UTP_ON_ACCEPT, (args) {
			auto self = cast(UtpContext)cast(Object)utp_context_get_userdata(args.context);
			assert(self !is null);
			assert(self.sockets !is null);
			self.sockets.resolve(args.socket);
			return 0;
		});

		loop.interval(500.msecs).each((_) nothrow {
			if (this.context is null) return false;
			utp_check_timeouts(this.context);
			return true;
		}).nothrow_;

		auto recv = underlying.recvFrom();
		do_while(() {
			bool raced;
			loop.sleep(30.msecs)
			.then(() {
				if (raced || this.context is null) return;
				utp_issue_deferred_acks(this.context);
			});

			return recv.next()
			.then((eofValue) {
				raced = true;
				if (eofValue.eof) return break_;
				auto dgram = eofValue.value;
				utp_process_udp(context, cast(const(byte)*)dgram.message.ptr, dgram.message.length, dgram.addr.name(), dgram.addr.nameLen());
				return continue_;
			});
		}).except((Interrupted _) {
		}).except((Exception e) {
			import std.stdio;
			debug stderr.writeln(sockets);
			if (sockets !is null) {
				sockets.reject(e);
			}
		}).nothrow_();

		gcretain(this);
	}

	void inc() nothrow {
		++count;
	}

	Promise!void close() nothrow {
		return Promise!void.resolved()
		.then(() {
			--count;
			if (count == 0) {
				return this.underlying.close()
				.finall(() {
					utp_destroy(this.context);
					this.context = null;
					if (this.sockets !is null) {
						auto done = this.sockets;
						this.sockets = null;
						done.resolve();
					}
					gcrelease(this);
				});
			} else {
				return Promise!void.resolved();
			}
		});
	}

	Promise!UtpStream connect(Address dest) nothrow {
		return Promise!void.resolved()
		.then(() => new UtpStream(utp_create_socket(this.context), this))
		.then((s) {
			return s.connect(dest)
			.failure((Exception _) => s.close())
			.then(() => s);
		});
	}

	PromiseIterator!Stream accept() nothrow {
		assert(sockets is null);
		sockets = new DelegatePromiseIterator!(utp_socket*);

		return new class PromiseIterator!Stream {
			override Promise!ItValue next(Promise!bool done) {
				if (sockets is null) {
					return Promise!ItValue.resolved(ItValue(true));
				}

				return sockets.next(done)
				.then((socketValue) {
					if (socketValue.eof) {
						return ItValue(true);
					}

					return ItValue(false, new UtpStream(socketValue.value, this.outer));
				});
			}
		};
	}
}

class UtpStream: Stream {
private:
	utp_socket* socket;
	UtpContext context;
	const(ubyte)[] pending_write_buffer;
	DelegatePromise!void pending_write_promise;
	CumulativeBuffer read_;
	DelegatePromise!void connecting;
	uint recv_len;

	this(utp_socket* socket, UtpContext context) {
		this.context = context;
		this.socket = socket;
		this.context.inc();
		gcretain(this);
		utp_set_userdata(socket, cast(void*)cast(Object)this);
		recvLen = 4096;
		read_ = new class CumulativeBuffer {
			override void onDrain() {
				utp_read_drained(this.outer.socket);
			}
		};
	}

	void on_state(int state) {
		if (state == UTP_STATE_CONNECT && connecting) {
			auto done = connecting;
			connecting = null;
			done.resolve();
		}

		if (state == UTP_STATE_CONNECT || state == UTP_STATE_WRITABLE) {
			do_write();
		}

		if (state == UTP_STATE_EOF) {
			read_.resolve();
		}
	}

	void on_error(int error_code) {
		if (connecting) {
			auto done = connecting;
			connecting = null;
			done.reject(new Exception("Error %s".noth!format(error_code)));
		}
	}

	Promise!void do_write() nothrow {
		if (pending_write_buffer.length == 0) {
			return Promise!void.resolved();
		}

		auto nwrote = utp_write(this.socket, cast(void*)pending_write_buffer.ptr, pending_write_buffer.length);
		
		if (nwrote < 0) {
			if (pending_write_promise is null) pending_write_promise = new DelegatePromise!void;
			auto done = pending_write_promise;
			pending_write_promise = null;
			done.reject(new Exception("Error %s".noth!format(-nwrote)));
			return done;
		}

		pending_write_buffer = pending_write_buffer[nwrote..$];
		if (pending_write_buffer.length == 0) {
			if (pending_write_promise !is null) {
				auto done = pending_write_promise;
				pending_write_promise = null;
				done.resolve();
			}

			return Promise!void.resolved();
		}
		
		if (pending_write_promise is null) pending_write_promise = new DelegatePromise!void;
		return pending_write_promise;
	}

	Promise!void connect(Address addr) {
		assert(connecting is null);
		connecting = new DelegatePromise!void;
		utp_connect(this.socket, addr.name, addr.nameLen);
		return connecting;
	}

	void on_read(const(ubyte)[] data) {
		read_.append(data);
	}

	int recv_buffer() {
		return cast(int)read_.pendingLength();
	}
public:
	@property void recvLen(int len) {
		utp_setsockopt(this.socket, UTP_RCVBUF, 4096);
	}
	@property int recvLen() {
		return utp_getsockopt(this.socket, UTP_RCVBUF);
	}

	override Promise!void shutdown() nothrow {
		return close();
	}

	override Promise!void close() nothrow {
		return Promise!void.resolved()
		.then(() {
			utp_close(this.socket);
		}).finall(() {
			if (this.context is null) {
				return Promise!void.resolved();
			} else {
				auto done = this.context;
				this.context = null;
				return done.close();
			}
		}).finall(() {
			gcrelease(this);
		});
	}

	override PromiseIterator!(const(ubyte)[]) read() nothrow {
		return read_;
	}
	
	override Promise!void write(immutable(ubyte)[] buf) nothrow {
		assert(pending_write_promise is null, "Paralell writes");

		pending_write_buffer = buf;

		return do_write();
	}
}