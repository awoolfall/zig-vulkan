pub const c = @cImport({
    @cInclude("slang_c.h");
});

pub fn check(ptr: anytype) !@TypeOf(ptr) {
    if (ptr != null) { return ptr; }
    else { return error.IsNull; }
}
