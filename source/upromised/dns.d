module upromised.dns;
import deimos.libuv.uv : uv_getaddrinfo, uv_getaddrinfo_t, uv_freeaddrinfo, uv_loop_t;
import deimos.libuv._d : addrinfo;
import std.socket : Address;
import upromised.promise : Promise;
import upromised.memory : getSelf, gcretain, gcrelease;
import upromised.uv : uvCheck;
version(Posix) {
	import core.sys.posix.netdb : sockaddr, sockaddr_in, sockaddr_in6;
} else version(Windows) {
	import core.sys.windows.winsock2 : sockaddr, sockaddr_in, sockaddr_in6;
}

Address[] toAddress(const(addrinfo)* each) nothrow {
	Address[] r;
	while (each !is null) {
		r ~= each.ai_addr.toAddress(each.ai_addrlen);
		each = each.ai_next;
	}
	return r;
}

Address toAddress(const(sockaddr)* each, size_t len = 16) nothrow {
	import std.socket : AddressFamily, InternetAddress, Internet6Address, UnknownAddressReference;

	if (each.sa_family == AddressFamily.INET) {
		return new InternetAddress(*cast(sockaddr_in*)each);
	} else if (each.sa_family == AddressFamily.INET6) {
		return new Internet6Address(*cast(sockaddr_in6*)each);
	} else {
		ubyte[] copy = new ubyte[len];
		copy[] = (cast(const(ubyte)*)(each))[0..len];
		return new UnknownAddressReference(cast(sockaddr*)copy.ptr, cast(int)copy.length);
	}
}

Promise!(Address[]) getAddrinfo(uv_loop_t* ctx, const(char)[] node, ushort port) nothrow {
    import std.conv : to;
    return getAddrinfo(ctx, node, port.to!string);
}
Promise!(Address[]) getAddrinfo(uv_loop_t* ctx, const(char)[] node, const(char)[] service) nothrow {
	import std.string : toStringz;
	auto r = new GetAddrinfoPromise;
	
	if (node !is null) {
		r.node = node.toStringz;
	}

	if (service !is null) {
		r.service = service.toStringz;
	}

	gcretain(r);
	int err = uv_getaddrinfo(ctx, &r.self, (rSelf, status, res) nothrow {
		auto r = getSelf!GetAddrinfoPromise(rSelf);
		if (status.uvCheck(r)) return;
		r.resolve(res.toAddress);
		uv_freeaddrinfo(res);
	}, r.node, r.service, null);
	err.uvCheck(r);
	r.finall(() => gcrelease(r));
	return r;
}
private class GetAddrinfoPromise : Promise!(Address[]) {
	const(char)* node;
	const(char)* service;
	uv_getaddrinfo_t self;
}