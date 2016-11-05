module upromised.memory;

/// Remarks: We need to retain the memory while an object is in the C world
void gcretain(T)(T a) {
	import core.memory : GC;
	GC.addRoot(cast(void*)a);
	GC.setAttr(cast(void*)a, GC.BlkAttr.NO_MOVE);
}

/// Remarks: We need to retain the memory while an object is in the C world
void gcrelease(T)(T a) {
	import core.memory : GC;
	GC.removeRoot(cast(void*)a);
    GC.clrAttr(cast(void*)a, GC.BlkAttr.NO_MOVE);
}

/// Gets the object of type T which has an attribute of type Y using
/// the attribute pointer
T getSelf(T,Y)(Y* a) {
	return cast(T)((cast(void*)a) - T.self.offsetof);
}