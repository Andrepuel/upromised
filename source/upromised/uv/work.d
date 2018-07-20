module upromised.uv.work;
import deimos.libuv.uv;
import deimos.libuv._d;
import std.exception : enforce;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.promise : DelegatePromise, Promisify, Promise;
import upromised.uv : uvCheck;

private {
    extern(C) void thread_attachThis() nothrow;
}

class Work {
private:
    uv_loop_t* ctx;
    void delegate() work;
    DelegatePromise!void result;
    Promise!void.Value value;

public:
    uv_work_t self;

    this(uv_loop_t* ctx) nothrow {
        this.ctx = ctx;
    }

    Promise!void run(void delegate() work) nothrow {
        import upromised.promise : promisifyCall;
        
        return Promise!void.resolved().then(() {
            enforce(result is null, "Work already in progress");

            result = new DelegatePromise!void;
            scope(failure) result = null;
            this.work = work;

            auto err = uv_queue_work(ctx, &self, (self) nothrow {
                thread_attachThis();

                promisifyCall(self.getSelf!Work().work)
                .then_((value) nothrow {
                    self.getSelf!Work().value = value;
                });
            }, (selfSelf, status) nothrow {
                auto self = selfSelf.getSelf!Work;
                auto result = self.result;
                self.result = null;
                result.resolve(self.value);
            });
            err.uvCheck();
            
            gcretain(this);
            result.finall(() {
                gcrelease(this);
            });

            return result;
        });
    }

    Promise!T run(T)(T delegate() cb) nothrow
    if (is(Promisify!T == Promise!T) && !is(T == void))
    {

        T r;
        return run(() {
            r = cb();
        }).then(() => r);
    }
}