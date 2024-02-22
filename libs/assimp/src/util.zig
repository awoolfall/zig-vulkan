pub const c = @cImport({
    @cInclude("assimp/cimport.h");
    @cInclude("assimp/scene.h");
    @cInclude("assimp/material.h");
    @cInclude("assimp/config.h");
});

pub inline fn aiBoolFromBool(b: bool) c.aiBool {
    return @intFromBool(b);
}

pub inline fn stringFromAiString(s: *const c.aiString) []const u8 {
    return s.data[0..s.length];
}

pub const Mat4x4 = [4]@Vector(4, f32);
pub inline fn matFromAiTransform(t: *const c.aiMatrix4x4) Mat4x4 {
    return [_]@Vector(4, f32){
        @Vector(4, f32){t.a1, t.b1, t.c1, t.d1},
        @Vector(4, f32){t.a2, t.b2, t.c2, t.d2},
        @Vector(4, f32){t.a3, t.b3, t.c3, t.d3},
        @Vector(4, f32){t.a4, t.b4, t.c4, t.d4},
    };
}

pub inline fn double_cast_array(comptime OutType: type, array: [*c][*c]OutType.AssimpType, array_length: c_uint) []OutType.Ptr {
    if (array_length == 0) {
        return ([_]OutType.Ptr{undefined})[0..0];
    }
    return @as([*c]OutType.Ptr, @ptrCast(array))[0..array_length];
}

