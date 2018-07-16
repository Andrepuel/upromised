module upromised.uv.work;
import deimos.libuv.uv;
import deimos.libuv._d;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.promise : DelegatePromise, Promisify, Promise;
import upromised.uv : uvCheck;

class Work {
private:
    uv_loop_t* ctx;
    void delegate() nothrow work;
    void delegate() nothrow end;
    
public:
    uv_work_t self;

    this(uv_loop_t* ctx) nothrow {
        this.ctx = ctx;
    }

    Promise!T run(T)(T delegate() cb) nothrow
    if (is(Promisify!T == Promise!T))
    {
        import upromised.promise : promisifyCall;

        Promise!T.Value value;
        DelegatePromise!T result = new DelegatePromise!T;
        work = () nothrow {
            promisifyCall(cb).then_((valueArg) {
                value = valueArg;
            });
        };
        end = () nothrow {
            result.resolve(value);
        };
        auto err = uv_queue_work(ctx, &self, (self) nothrow {
            self.getSelf!Work().work();
        }, (self, status) nothrow {
            self.getSelf!Work().end();
        });

        err.uvCheck(result);
        gcretain(this);
        result.finall(() {
            gcrelease(this);
        });

        return result;
    }
}