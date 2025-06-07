const std = @import("std");
pub const c = @cImport({
    @cInclude("slang_c.h");
});

pub fn check(ptr: anytype) !@TypeOf(ptr) {
    if (ptr != null) { return ptr.?; }
    else { return error.IsNull; }
}

pub fn blob_str(blob: ?*c.Blob) []const u8 {
    return std.mem.trim(u8, blob_slice(blob), "\r\n");
}

pub fn blob_slice(blob: ?*c.Blob) []const u8 {
    if (blob == null) { return &.{}; }
    
    const blob_ptr = c.blob_get_buffer_ptr(blob);
    if (blob_ptr == null) { return &.{}; }

    const blob_bytes_ptr: [*]const u8 = @ptrCast(c.blob_get_buffer_ptr(blob));
    return blob_bytes_ptr[0..c.blob_get_buffer_size(blob)];
}

pub const ComposedProgramCreateInfo = struct {
    modules: []const ?*c.Module = &.{},
    entry_points: []const ?*c.EntryPoint = &.{},
    composed_programs: []const ?*c.ComposedProgram = &.{},
    diagnostics_blob: ?*c.Blob = null,

    pub fn to_slang(self: *const @This()) c.ComposedProgramCreateInfo {
        return c.ComposedProgramCreateInfo {
            .p_modules = if (self.modules.len > 0) @ptrCast(self.modules.ptr) else null,
            .modules_count = @intCast(self.modules.len),
            .p_entry_points = if (self.entry_points.len > 0) @ptrCast(self.entry_points.ptr) else null,
            .entry_points_count = @intCast(self.entry_points.len),
            .p_composed_programs = if (self.composed_programs.len > 0) @ptrCast(self.composed_programs.ptr) else null,
            .composed_programs_count = @intCast(self.composed_programs.len),
            .diagnostics_blob = self.diagnostics_blob,
        };
    }
};
