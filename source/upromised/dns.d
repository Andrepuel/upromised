module upromised.dns;
import deimos.libuv.uv : uv_getaddrinfo, uv_getaddrinfo_t, uv_freeaddrinfo, uv_loop_t;
import deimos.libuv._d : addrinfo;
import upromised.promise : Promise;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.uv : uvCheck;

class Addrinfo {
    addrinfo* res;

    this(addrinfo* res) nothrow {
        this.res = res;
    }

    ~this() {
        uv_freeaddrinfo(res);
    }

    addrinfo*[] get() nothrow {
        addrinfo*[] r;
        auto each = res;
        while(each !is null) {
            r ~= each;
            each = each.ai_next;
        }
        return r;
    }
}

Promise!Addrinfo getAddrinfo(uv_loop_t* ctx, const(char)[] node, ushort port) nothrow {
    import std.conv : to;
    return getAddrinfo(ctx, node, port.to!string);
}
Promise!Addrinfo getAddrinfo(uv_loop_t* ctx, const(char)[] node, const(char)[] service) nothrow {
    import std.string : toStringz;
    auto r = new GetAddrinfoPromise;
    gcretain(r);
    int err = uv_getaddrinfo(ctx, &r.self, (rSelf, status, res) nothrow {
        auto r = getSelf!GetAddrinfoPromise(rSelf);
        if (status.uvCheck(r)) return;
        r.resolve(new Addrinfo(res));
    }, node.toStringz, service.toStringz, null);
    err.uvCheck(r);
    r.finall(() => gcrelease(r));
    return r;
}
private class GetAddrinfoPromise : Promise!Addrinfo {
    uv_getaddrinfo_t self;
}