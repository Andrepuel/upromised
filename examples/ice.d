import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.exception : enforce;
import std.format : format;
import std.stdio;
import upromised.loop : defaultLoop;

enum Method {
    Binding=0x01,
    SharedSecret=0x02
}

enum Class {
    Request=0x0,
    Indication=0x1,
    Response=0x2,
    Error=0x3
};

struct ZeroZeroMessageType {
    ubyte[2] value;

    uint zeroZero() const pure {
        return value[0] << 6;
    }

    void zeroZero(uint newValue) pure {
        assert((newValue & ~0x3) == 0);
        value[0] &= ~0xc0;
        value[0] |= newValue >> 6;
    }


    Class class_() const pure {
        int classInt = ((value[0] & 0x1) >> 1) | ((value[1] << 4) & 0x1);
        return cast(Class) classInt;
    }

    void class_(Class newClass) pure {
        int classInt = cast(int) newClass;
        assert((classInt & ~0x3) == 0);
        value[0] &= ~0x01;
        value[0] |= (classInt << 1);
        value[1] |= ~0x10;
        value[1] |= (classInt & 0x1) >> 4;
    }

    Method method() const pure {
        int methodInt = (value[1] & 0xf) | (((value[1] >> 5) & 0x7) >> 4) | (((value[0] << 1) & 0x1f) >> 8);
        return cast(Method) methodInt;
    }

    void method(Method newMethod) pure {
        int methodInt = cast(int) newMethod;
        assert((methodInt & ~0xfff) == 0);
        value[1] &= ~0x0f;
        value[1] |= methodInt & 0xf;
        value[1] &= ~0xe0;
        value[1] |= (methodInt << 4) & 0x7;
        value[0] &= ~0x3e;
        value[0] |= ((methodInt << 7) & 0x1f) > 1;
    }

    string toString() const pure {
        return "ZeroZeroMessageType(%s, %s, %s)".format(this.zeroZero, this.method, this.class_);
    }
};

enum ubyte[] magicCookieDefaultValue = [0x21, 0x12, 0xa4, 0x42];
enum uint magicCookieInt = 0x2112a442;

struct StunHeader {
    ZeroZeroMessageType messageType;
    ubyte[2] messageLength_be;
    ubyte[4] magicCookie;
    uint[3] transactionId;

    ushort messageLength() const pure {
        return bigEndianToNative!ushort(messageLength_be);
    }

    void messageLength(ushort newLen) pure {
        messageLength_be = nativeToBigEndian(newLen);
    }

    inout(StunAttribute)*[] attributes() inout pure {
        inout(StunAttribute)*[] result;
        inout(ubyte)* it = cast(inout(ubyte)*) &this;
        it += StunHeader.sizeof;

        ushort remaining = messageLength;
        while (remaining > 0) {
            inout(StunAttribute)* each = cast(inout(StunAttribute)*) it;
            size_t skip = each.length + StunAttribute.sizeof;
            assert(remaining >= skip);
            result ~= each;
            remaining -= skip;
            it += skip;
        }

        return result;
    }

    string toString() const pure {
        import std.algorithm;
        return "StunHeader(%s, %s, %s, %s, %s)".format(messageType, messageLength, magicCookie, transactionId, attributes.map!(x => x.toString));
    }
};

enum AttributeType : ushort {
    //Remarks: only works on little endian

    reserved0 = 0x0000,
    MAPPED_ADDRESS = 0x0100,
    RESPONSE_ADDRESS = 0x0200,
    CHANGE_ADDRESS = 0x0300,
    SOURCE_ADDRESS = 0x0400,
    CHANGED_ADDRESS = 0x0500,
    USERNAME = 0x0600,
    PASSWORD = 0x0700,
    MESSAGE_INTEGRITY = 0x0800,
    ERROR_CODE = 0x0900,
    UNKNOWN_ATTRIBUTES = 0x0A00,
    REFLECTED_FROM = 0x0B00,
    REALM = 0x1400,
    NONCE = 0x1500,
    XOR_MAPPED_ADDRESS = 0x2000
};

struct StunAttribute {
    AttributeType type;
    ubyte[2] length_be;

    ushort length() const pure {
        return bigEndianToNative!ushort(length_be);
    }

    ubyte[] value() const pure {
        return (cast(ubyte*)&this)[4..4+length];
    }

    string toString() const pure {
        return "StunAttribute(%s, %s, %s)".format(type, length, valueToString);
    }

    string valueToString() const pure {
        import std.conv;
        if (type == AttributeType.XOR_MAPPED_ADDRESS) {
            return (cast(XorMappedAddress*) value.ptr).toString;
        } else {
            return value.to!string;
        }
    }
};

enum Family : ubyte {
    Ipv4 = 0x01,
    Ipv6 = 0x02
};

struct XorMappedAddress {
    ubyte unused;
    Family family;
    ubyte[2] port_be;
    ubyte[4] address_be;

    ushort port() const pure {
        return bigEndianToNative!ushort(port_be) ^ (magicCookieInt >> 16);
    }

    void port(ushort newPort) pure {
        port_be = nativeToBigEndian!ushort(newPort ^ (magicCookieInt >> 16));
    }

    uint address() const pure {
        assert(family == Family.Ipv4);
        return bigEndianToNative!uint(address_be) ^ magicCookieInt;
    }

    void address(uint ipv4) pure {
        address_be = nativeToBigEndian(ipv4 ^ magicCookieInt);
    }

    string toString() const pure {
        return "XorMappedAddress(%s, %s, %s)".format(family, port, nativeToBigEndian(address));
    }
};

void main() {
	auto loop = defaultLoop();

	StunHeader header;
	header.messageType.zeroZero(0);
	header.messageType.class_ = Class.Request;
	header.messageType.method = Method.Binding;
	header.messageLength = 0;
	header.magicCookie = magicCookieDefaultValue;
	header.transactionId = [1, 2, 3];
	
	loop.resolve("stun.l.google.com", 19302).then((addr) {
		enforce(addr.length > 0);
		writeln(addr);
		return loop.udp().then((socket) {
			return socket.sendTo(addr[0], (cast(const(ubyte)[])((&header)[0..1])).idup)
			.then(() {
				return socket.recvFrom().each((datagram) {
					auto response = cast(StunHeader*)datagram.message.ptr;
					writeln(response.toString);
					return false;
				}).then((_) {});
			}).finall(() => socket.close());
		});
	}).nothrow_();

	loop.run();
}