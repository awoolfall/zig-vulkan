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

pub const SessionCreateInfo = struct {
    compile_target: c.CompileTargets,
    profile: []const u8,
    preprocessor_macros: []const c.PreprocessorMacro = &.{},
    compile_options: []const c.CompilerOption = &.{},
    search_paths: []const [:0]const u8 = &.{},
    
    pub fn to_slang(self: *const @This()) c.SessionCreateInfo {
        return .{
            .compile_target = self.compile_target,
            .profile = @ptrCast(self.profile.ptr),
            .p_preprocessor_macros = if (self.preprocessor_macros.len > 0) @ptrCast(self.preprocessor_macros.ptr) else null,
            .preprocessor_macros_count = @intCast(self.preprocessor_macros.len),
            .p_compile_options = if (self.compile_options.len > 0) @ptrCast(self.compile_options.ptr) else null,
            .compile_options_count = @intCast(self.compile_options.len),
            .p_search_paths = if (self.search_paths.len > 0) @ptrCast(self.search_paths.ptr) else null,
            .search_paths_count = @intCast(self.search_paths.len),
        };
    }
};

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
