module upromised.timer;
import deimos.libuv.uv : uv_timer_t, uv_handle_t, uv_loop_t, uv_timer_init, uv_timer_start, uv_timer_stop, uv_close, uv_timer_get_repeat;
import upromised.loop : Loop;
import upromised.promise : DelegatePromise, DelegatePromiseIterator, Promise, PromiseIterator;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.uv : uvCheck;
import std.datetime : Duration;
import upromised : fatal;

uv_handle_t* handle(ref uv_timer_t self) nothrow {
    return cast(uv_handle_t*)&self;
}

class Timer {
public:
    uv_timer_t self;
    DelegatePromise!void closePromise;
    DelegatePromiseIterator!int startPromise;

    this(Loop loop) {
        this(cast(uv_loop_t*)loop.inner());
    }

    this(uv_loop_t* ctx) {
        uv_timer_init(ctx, &self).uvCheck();
        gcretain(this);
    }

    Promise!void close() nothrow {
        if (closePromise !is null) return closePromise;
        closePromise = new DelegatePromise!void;
        uv_close(self.handle, (selfSelf) nothrow {
            auto self = getSelf!Timer(selfSelf);
            gcrelease(self);
            self.closePromise.resolve();
        });
        return closePromise;
    }

    DelegatePromiseIterator!int start(Duration start, Duration repeat = Duration.init) nothrow {
        import std.algorithm : swap;

        assert(startPromise is null);
        startPromise = new DelegatePromiseIterator!int;
        auto r = startPromise;
        int err = uv_timer_start(&self, (selfSelf) nothrow {
            auto self = getSelf!Timer(selfSelf);
            self.startPromise.resolve(0).then((cont) {
                if (uv_timer_get_repeat(&self.self) == 0) {
                    self.startPromise.resolve();
                    self.startPromise = null;
                } else if (!cont) {
                    uv_timer_stop(&self.self);
                    self.startPromise = null;
                }
            }).nothrow_();
        }, start.total!"msecs", repeat.total!"msecs");
        if (err.uvCheck(startPromise)) {
            startPromise = null;
        }
        return r;
    }

    static Promise!void once(uv_loop_t* ctx, Duration start = Duration.init) nothrow {
        return Promise!void.resolved().then(() => new Timer(ctx)).then((timer) { 
            return timer.start(start).each((a){}).finall(() => timer.close()).then((){});
        });
    }
}