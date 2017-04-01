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

private struct ExData(alias name, T) {
    private shared static const(int) index;
    shared static this() {
        index = SSL_get_ex_new_index(0, null, null, null, null);
    }

    static set(SSL* ctx, T* data) {
        int rc = SSL_set_ex_data(ctx, index, cast(void*)data);
        assert(rc == 1);
    }

    static T* get(SSL* ctx) {
        return cast(T*)SSL_get_ex_data(ctx, index);
    }
}
alias HostnameExData = ExData!("hostname", const(char));

private const(char)* ccopy(const(char)[] arg) nothrow {
    import core.stdc.stdlib : malloc;

    char[] r = (cast(char*)malloc(arg.length + 1))[0..arg.length + 1];
    r[0..$-1] = arg;
    r[$-1] = 0;
    return r.ptr;
}

private string[] alternativeNames(X509* x509) {
    import deimos.openssl.objects : NID_subject_alt_name;
    import deimos.openssl.x509v3 : GENERAL_NAME, GENERAL_NAMES, GENERAL_NAMES_free;
    import std.algorithm : filter, map;
    import std.array : array;
    import std.range : iota;
    
    auto names = cast(GENERAL_NAMES*)X509_get_ext_d2i(x509, NID_subject_alt_name, null, null);
    scope(exit) GENERAL_NAMES_free(names);
    return 0.iota(sk_GENERAL_NAME_num(names))
        .map!(i => sk_GENERAL_NAME_value(names, i))
        .filter!(gen => gen.type == GENERAL_NAME.GEN_DNS)
        .map!(gen => (cast(const(char)*)gen.d.dNSName.data)[0..gen.d.dNSName.length].idup)
        .array;
}

private string[] commonNames(X509* x509) {
    import std.algorithm : map;
    import std.array : array;

    auto name = X509_get_subject_name(x509);

    struct Indexes {
        int front = -1;
        void popFront() {
            front = X509_NAME_get_index_by_NID(name, NID_commonName, front);
        }
        bool empty() {
            return front < 0;
        }
    }

    Indexes index;
    index.popFront();
    
    return index
        .map!(i => X509_NAME_get_entry(name, i))
        .map!(entry => X509_NAME_ENTRY_get_data(entry))
        .map!(common_name => (cast(const(char)*)common_name.data)[0..common_name.length].idup)
        .array;
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

    void load_verify_locations(string cafile) {
        import std.string : toStringz;

        int rc = SSL_CTX_load_verify_locations(ctx, cafile.toStringz, null);
        if (rc <= 0) {
            throw new OpensslError(rc, 0);
        }
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

    Promise!void connect(string hostname = null) nothrow {
        import core.stdc.stdlib : free;
        import std.algorithm : any, map;
        import std.string : fromStringz;

        extern(C) int function(int, X509_STORE_CTX*) verify;

        if (hostname !is null) {
            HostnameExData.set(this.ssl, hostname.ccopy);
            verify = (preverified, ctx) {
                if (preverified == 0) {
                    return 0;
                }

                if (X509_STORE_CTX_get_error_depth(ctx) != 0) {
                    return 1;
                }
                
                auto ssl = cast(SSL*) X509_STORE_CTX_get_ex_data(ctx, SSL_get_ex_data_X509_STORE_CTX_idx());
                const(char)[] hostname = HostnameExData.get(ssl).fromStringz;
                auto x509 = X509_STORE_CTX_get_current_cert(ctx);

                if (x509.alternativeNames.map!((an) => an == hostname).any) {
                    return 1;
                }

                string[] commonNames = x509.commonNames;
                if (commonNames.length > 0 && commonNames[$-1] == hostname) {
                    return 1;
                }

                return 0;
            };
        }

        SSL_set_verify(this.ssl, SSL_VERIFY_PEER, verify);
        return operate!(SSL_connect).then((_) {}).finall(() {
            auto hostnameCopy = HostnameExData.get(this.ssl);
            if (hostnameCopy !is null) {
                free(cast(void*)hostnameCopy);
                HostnameExData.set(this.ssl, null);
            }
        });
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

