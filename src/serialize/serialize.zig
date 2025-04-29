const std = @import("std");
const builtin = @import("builtin");

pub fn Serializable(comptime T: type) type {
    @setEvalBranchQuota(10000);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (@hasDecl(T, "Serde")) {
                return Serializable(T.Serde.T);
            } else {
                var fields: [std.meta.fields(T).len]std.builtin.Type.StructField = undefined;
                for (std.meta.fields(T), 0..) |field, i| {
                    const SerializableType = Serializable(field.type);
                    fields[i] = .{
                        .name = field.name,
                        .type = SerializableType,
                        // TODO: convert the default value to SerializableType at compile time.
                        // for types that are not optionals
                        .default_value_ptr = blk: {
                            if (field.default_value_ptr) |_| {
                                switch (@typeInfo(field.type)) {
                                    .@"optional" => { break :blk &@as(SerializableType, null); },
                                    else => break :blk null,
                                }
                            } else {
                                break :blk null;
                            }
                        },
                        .is_comptime = false,
                        .alignment = field.alignment,
                    };
                }
                var new_s = s;
                new_s.fields = &fields;
                new_s.decls = &.{};
                return @Type(.{
                    .@"struct" = new_s,
                });
            }
        },
        .@"union" => |u| {
            if (@hasDecl(T, "Serde")) {
                return Serializable(T.Serde.T);
            } else {
                var fields: [std.meta.fields(T).len]std.builtin.Type.UnionField = undefined;
                for (std.meta.fields(T), 0..) |field, i| {
                    fields[i] = .{
                        .name = field.name,
                        .type = Serializable(field.type),
                        .alignment = field.alignment,
                    };
                }
                var new_u = u;
                new_u.fields = &fields;
                return @Type(.{
                    .@"union" = new_u,
                });
            }
        },
        .@"array" => |a| {
            var new_a = a;
            new_a.child = Serializable(a.child);
            return @Type(.{
                .@"array" = new_a,
            });
        },
        .pointer => |p| {
            if (p.size != .slice) {
                @compileError("pointers and arbitrary length arrays cannot be serialized");
            }
            var new_p = p;
            new_p.child = Serializable(p.child);
            return @Type(.{
                .pointer = new_p,
            });
        },
        .optional => |o| {
            var new_o = o;
            new_o.child = Serializable(o.child);
            return @Type(.{
                .optional = new_o,
            });
        },
        .@"enum" => |_| {
            if (@hasDecl(T, "Serde")) {
                return Serializable(T.Serde.T);
            } else {
                return T;
            }
        },
        .vector => |v| {
            switch (@typeInfo(v.child)) {
                .pointer => @compileError("vectors of pointers are not serializable"),
                else => return T,
            }
        },
        .bool, .int, .float, .comptime_int, .comptime_float, .null, .void => return T,
        else => { @compileLog(@typeInfo(T)); unreachable; },
    }
}

/// Convert a structure recursively into its serializable form.
pub fn serialize(comptime T: type, allocator: std.mem.Allocator, value: T) !Serializable(T) {
    switch (@typeInfo(T)) {
        .@"struct" => |_| {
            if (@hasDecl(T, "Serde")) {
                const s = try T.Serde.serialize(allocator, value);
                return try serialize(T.Serde.T, allocator, s);
            } else {
                var s: Serializable(T) = undefined;
                const field_names = comptime std.meta.fieldNames(T);
                inline for (field_names) |field_name| {
                    const v = try serialize(@FieldType(T, field_name), allocator, @field(value, field_name));
                    @field(s, field_name) = v;
                }
                return s;
            }
        },
        .@"union" => |_| {
            if (@hasDecl(T, "Serde")) {
                const s = try T.Serde.serialize(allocator, value);
                return try serialize(T.Serde.T, allocator, s);
            } else {
                var s: Serializable(T) = undefined;
                const tag_name = @tagName(value);
                const field_names = comptime std.meta.fieldNames(T);
                inline for (field_names) |field_name| {
                    if (std.mem.eql(u8, field_name, tag_name)) {
                        const v = try serialize(@FieldType(T, field_name), allocator, @field(value, field_name));
                        s = @unionInit(Serializable(T), field_name, v);
                    }
                }
                return s;
            }
        },
        .@"array" => |a| {
            var ar: Serializable(T) = undefined;
            for (0..a.len) |i| {
                const v = try serialize(a.child, allocator, value[i]);
                ar[i] = v;
            }
            return ar;
        },
        .pointer => |p| {
            std.debug.assert(p.size == .many or p.size == .slice);
            const ar = try allocator.alloc(Serializable(p.child), value.len);
            for (0..value.len) |i| {
                ar[i] = try serialize(p.child, allocator, value[i]);
            }
            return ar;
        },
        .optional => |o| {
            return if (value) |v| try serialize(o.child, allocator, v) else null;
        },
        else => return value,
    }
}

/// Convert a structure recursively out from its serializable form.
pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, value: Serializable(T)) !T {
    switch (@typeInfo(T)) {
        .@"struct" => |_| {
            if (@hasDecl(T, "Serde")) {
                const d = try deserialize(T.Serde.T, allocator, value);
                return try T.Serde.deserialize(allocator, d);
            } else {
                var d: T = undefined;
                const field_names = comptime std.meta.fieldNames(T);
                inline for (field_names) |field_name| {
                    const v = try deserialize(@FieldType(T, field_name), allocator, @field(value, field_name));
                    @field(d, field_name) = v;
                }
                return d;
            }
        },
        .@"union" => |_| {
            if (@hasDecl(T, "Serde")) {
                const d = try deserialize(T.Serde.T, allocator, value);
                return try T.Serde.deserialize(allocator, d);
            } else {
                var d: T = undefined;
                const tag_name = @tagName(value);
                const field_names = comptime std.meta.fieldNames(T);
                inline for (field_names) |field_name| {
                    if (std.mem.eql(u8, field_name, tag_name)) {
                        const v = try deserialize(@FieldType(T, field_name), allocator, @field(value, field_name));
                        d = @unionInit(T, field_name, v);
                    }
                }
                return d;
            }
        },
        .@"array" => |a| {
            var ar: T = undefined;
            for (0..a.len) |i| {
                const v = try deserialize(a.child, allocator, value[i]);
                ar[i] = v;
            }
            return ar;
        },
        .pointer => |p| {
            std.debug.assert(p.size == .many or p.size == .slice);
            const ar = try allocator.alloc(p.child, value.len);
            for (0..value.len) |i| {
                ar[i] = try deserialize(p.child, allocator, value[i]);
            }
            return ar;
        },
        .optional => |o| {
            return if (value) |v| try deserialize(o.child, allocator, v) else null;
        },
        else => return value,
    }
}





// Testing Structs //

const S0 = struct {
    a: u32,
    b: u32,

    pub const Serde = struct {
        pub const T = struct {
            a: u32,
            b: u32,
        };

        pub fn serialize(allocator: std.mem.Allocator, value: S0) !T {
            _ = allocator;
            return T {
                .a = value.a,
                .b = value.b,
            };
        }

        pub fn deserialize(allocator: std.mem.Allocator, value: T) !S0 {
            _ = allocator;
            return S0 {
                .a = value.a,
                .b = value.b,
            };
        }
    };
};

const S2 = struct {
    c: u32,

    pub const Serde = struct {
        pub const T = struct {
            d: u32,
        };

        pub fn serialize(allocator: std.mem.Allocator, value: S2) !T {
            _ = allocator;
            return T {
                .d = value.c + 10,
            };
        }

        pub fn deserialize(allocator: std.mem.Allocator, value: T) !S2 {
            _ = allocator;
            return S2 {
                .c = value.d - 10,
            };
        }
    };
};

test "serialize/deserialize" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    {
        // simple
        const s = S0 {
            .a = 1,
            .b = 2,
        };
        const ser = serialize(S0, std.testing.allocator, s) catch unreachable;
        try std.testing.expectEqual(Serializable(S0.Serde.T) { .a = 1, .b = 2 }, ser);
        const json = try std.json.stringifyAlloc(arena.allocator(), ser, .{});
        try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}", json);
        const des = deserialize(S0, std.testing.allocator, ser) catch unreachable;
        try std.testing.expectEqual(s, des);
    }

    _ = arena.reset(.retain_capacity);
    {
        // nested serde in a standard struct
        const s = S0 {
            .a = 1,
            .b = 2,
        };
        const S1 = struct {
            a: u32,
            s0: S0,
        };
        const s1 = S1 {
            .a = 1,
            .s0 = s,
        };
        const ser = serialize(S1, std.testing.allocator, s1) catch unreachable;
        try std.testing.expectEqual(Serializable(S1) { 
            .a = 1, 
            .s0 = Serializable(S0.Serde.T) { .a = 1, .b = 2 },
        }, ser);
        const json = try std.json.stringifyAlloc(arena.allocator(), ser, .{});
        try std.testing.expectEqualStrings("{\"a\":1,\"s0\":{\"a\":1,\"b\":2}}", json);
        const des = deserialize(S1, std.testing.allocator, ser) catch unreachable;
        try std.testing.expectEqual(s1, des);
    }

    _ = arena.reset(.retain_capacity);
    {
        // non trivial serde conversion
        const s2 = S2 {
            .c = 10,
        };
        const ser = serialize(S2, std.testing.allocator, s2) catch unreachable;
        try std.testing.expectEqual(Serializable(S2.Serde.T) { 
            .d = 10 + 10,
        }, ser);
        const json = try std.json.stringifyAlloc(arena.allocator(), ser, .{});
        try std.testing.expectEqualStrings("{\"d\":20}", json);
        const des = deserialize(S2, std.testing.allocator, ser) catch unreachable;
        try std.testing.expectEqual(s2, des);
    }

    _ = arena.reset(.retain_capacity);
    {
        // array with serde elements
        const AS = struct {
            ar: [4]S0,
        };
        const s = AS {
            .ar = [_]S0{
                S0 { .a = 1, .b = 2 },
                S0 { .a = 3, .b = 4 },
                S0 { .a = 5, .b = 6 },
                S0 { .a = 7, .b = 8 },
            },
        };
        const ser = serialize(AS, std.testing.allocator, s) catch unreachable;
        try std.testing.expectEqual(Serializable(AS) { 
            .ar = [_]Serializable(S0.Serde.T){
                .{ .a = 1, .b = 2 },
                .{ .a = 3, .b = 4 },
                .{ .a = 5, .b = 6 },
                .{ .a = 7, .b = 8 },
            }
        }, ser);
        const json = try std.json.stringifyAlloc(arena.allocator(), ser, .{});
        try std.testing.expectEqualStrings("{\"ar\":[{\"a\":1,\"b\":2},{\"a\":3,\"b\":4},{\"a\":5,\"b\":6},{\"a\":7,\"b\":8}]}", json);
        const des = deserialize(AS, std.testing.allocator, ser) catch unreachable;
        try std.testing.expectEqual(s, des);
    }

    _ = arena.reset(.retain_capacity);
    {
        // slices with serde elements
        // TODO WARNING this only works with arena allocators since the internal slices are duplicated
        // using any other allocator may result in leaks
        const AS = struct {
            ar: []const S2,
        };
        const a = [_]S2 {
            S2 { .c = 1 },
            S2 { .c = 2 },
            S2 { .c = 3 },
            S2 { .c = 4 },
        };
        const s = AS {
            .ar = a[0..],
        };
        const ser = serialize(AS, arena.allocator(), s) catch unreachable;
        try std.testing.expectEqualDeep(Serializable(AS) {
            .ar = &[_]Serializable(S2.Serde.T){
                .{ .d = 1 + 10 },
                .{ .d = 2 + 10 },
                .{ .d = 3 + 10 },
                .{ .d = 4 + 10 },
            }
        }, ser);
        const json = try std.json.stringifyAlloc(arena.allocator(), ser, .{});
        try std.testing.expectEqualStrings("{\"ar\":[{\"d\":11},{\"d\":12},{\"d\":13},{\"d\":14}]}", json);
        const des = deserialize(AS, arena.allocator(), ser) catch unreachable;
        try std.testing.expectEqualDeep(s, des);
    }
}
