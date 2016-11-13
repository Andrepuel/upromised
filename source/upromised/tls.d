module upromised.tls;
import deimos.openssl.ssl;
import upromised.stream : Stream, ReadoneStream;
import upromised.promise : Promise, PromiseIterator;
import upromised : fatal;
import std.exception : enforce;
import std.format : format;

shared static this() {
    SSL_library_init();
}

struct BioPair {
    BIO* read_;
    BIO* write_;
    ubyte[] pending;

    @disable this(this);
    this(int)  {
        BIO_new_bio_pair(&read_, 0, &write_, 0);
        enforce(read_ !is null);
        enforce(write_ !is null);
    }

    ~this() nothrow {
        if (!read_) return;
        BIO_free(read_);
        BIO_free(write_);
        read_ = null;
        write_ = null;
    }

    void write(const(ubyte)[] data) {
        scope(success) pending ~= data;
        if (pending.length > 0) {
            writeSome(pending);
            if (pending.length > 0) return;
        }

        writeSome(data);
    }

    private void writeSome(ref inout(ubyte)[] data) {
        int r = BIO_write(write_, data.ptr, cast(int)data.length);
        if (r < 0) throw new OpensslError(r, 0);
        data = data[r..$];
    }

    immutable(const(ubyte)[]) read() {
        import std.exception : assumeUnique;
        ubyte[] data = new ubyte[1024];
        int r = BIO_read(read_, data.ptr, cast(int)data.length);
        if (r < 0) {
            return null;
        }
        data.length = r;
        return assumeUnique(data);
    }
}

class OpensslError : Exception {
    this(int ret, int err) {
        super("OpensslError ret=%s err=%s".format(ret, err));
    }
}

class UnderlyingShutdown : Exception {
    this() {
        super("Underlying connection shutdown when expecting data");
    }
}

class TlsContext {
private:
    SSL_CTX* ctx;

public:
    this() {
        ctx = SSL_CTX_new(SSLv23_client_method());
        enforce(ctx !is null);
    }

    ~this() nothrow {
        SSL_CTX_free(ctx);
    }
}

class TlsStream : ReadoneStream {
private:
    Stream underlying;
    TlsContext ctx;
    SSL* ssl;
    BioPair tlsWrite;
    BioPair tlsRead;
    ubyte[] readBuffer;

    enum Want : int {
        Success = 0,
        Read = -1,
        Write = -2
    }

    Want tryOperate(alias a, Args...)(Args args) {
        int ret = a(ssl, args);
        if (ret < 0) {
            int err = SSL_get_error(ssl, ret);
            if (err == SSL_ERROR_WANT_READ) {
                return Want.Read;
            } else if (err == SSL_ERROR_WANT_WRITE) {
                return Want.Write;
            } else {
                throw new OpensslError(ret, err);
            }
        }
        return cast(Want)ret;
    }

    Promise!int operate(alias a, Args...)(Args args) nothrow {
        auto r = new Promise!int;
        void delegate() nothrow tryOne;
        tryOne = () nothrow {
            Promise!void.resolved().then(() {
                Want want = tryOperate!a(args);

                return Promise!void.resolved().then(() {
                    auto toWrite = tlsWrite.read();
                    if (toWrite.length > 0) {
                        return underlying.write(toWrite);
                    } else {
                        return Promise!void.resolved();
                    }
                }).then(() {
                    if (want >= Want.Success) {
                        r.resolve(want);
                        return Promise!bool.resolved(false);
                    }

                    if (want == Want.Read) {
                        return underlying.read().each((data) {
                            tlsRead.write(data);
                            return false;
                        }).then((a) {
                            if (a) throw new UnderlyingShutdown;
                            return true;
                        });
                    }
                    assert(want == Want.Write);

                    return Promise!bool.resolved(true);
                });
            }).then((repeat) {
                if (repeat) tryOne();
            }).except((Exception e) => r.reject(e))
            .nothrow_();
        };
        tryOne();
        return r;
    }

    
public:
    this(Stream stream, TlsContext ctx) {
        underlying = stream;
        this.ctx = ctx;
        ssl = SSL_new(ctx.ctx);
        enforce(ssl !is null);
        tlsWrite = BioPair(0);
        tlsRead = BioPair(0);
        SSL_set_bio(ssl, tlsRead.read_, tlsWrite.write_);
        readBuffer.length = 1024;
    }

    Promise!void connect() nothrow {
        return operate!(SSL_connect).then((a) {});
    }

    override Promise!void write(immutable(ubyte)[] data) nothrow {
        return operate!(SSL_write)(data.ptr, cast(int)data.length).then((a) { enforce(a == data.length);});
    }

    override Promise!void shutdown() nothrow {
        return operate!(SSL_shutdown,).then((a) => underlying.shutdown);
    }

    override Promise!void close() nothrow {
        return underlying.close();
    }
protected:
    override void readOne() nothrow {
        import std.algorithm : swap;

        operate!(SSL_read)(readBuffer.ptr, cast(int)readBuffer.length).then((int read) {
            readOneData(readBuffer[0..read]);
        }).except((Exception e) {
            if ((cast(UnderlyingShutdown)e) !is null) {
                readOneData(null);
            } else {
                rejectOneData(e);
            }
        }).nothrow_();
    }
}

