const std = @import("std");
const builtin = @import("builtin");

pub fn SerializableStruct(comptime T: type) type {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (@hasDecl(T, "Serde")) {
                return SerializableStruct(T.Serde.T);
            } else {
                var fields: [std.meta.fields(T).len]std.builtin.Type.StructField = undefined;
                for (std.meta.fields(T), 0..) |field, i| {
                    fields[i] = field;
                    fields[i].type = SerializableStruct(field.type);
                }
                var new_s = s;
                new_s.fields = &fields;
                return @Type(.{
                    .@"struct" = new_s,
                });
            }
        },
        .@"array" => |a| {
            var new_a = a;
            new_a.child = SerializableStruct(a.child);
            return @Type(.{
                .@"array" = new_a,
            });
        },
        .pointer => |p| {
            std.debug.assert(p.size == .Many or p.size == .Slice);
            var new_p = p;
            new_p.child = SerializableStruct(p.child);
            return @Type(.{
                .pointer = new_p,
            });
        },
        .bool, .int, .float, .comptime_int, .comptime_float, .null, .@"enum", .@"union", .vector => return T,
        else => unreachable,
    }
}

pub fn serialize(comptime T: type, allocator: std.mem.Allocator, value: T) !SerializableStruct(T) {
    switch (@typeInfo(T)) {
        .@"struct" => |_| {
            if (@hasDecl(T, "Serde")) {
                const s = try T.Serde.serialize(allocator, value);
                return try serialize(T.Serde.T, allocator, s);
            } else {
                var s: SerializableStruct(T) = undefined;
                const field_names = comptime std.meta.fieldNames(T);
                inline for (field_names) |field_name| {
                    const v = try serialize(@FieldType(T, field_name), allocator, @field(value, field_name));
                    @field(s, field_name) = v;
                }
                return s;
            }
        },
        .@"array" => |a| {
            var ar: SerializableStruct(T) = undefined;
            for (0..a.len) |i| {
                const v = try serialize(a.child, allocator, value[i]);
                ar[i] = v;
            }
            return ar;
        },
        .pointer => |p| {
            std.debug.assert(p.size == .Many or p.size == .Slice);
            const ar = try allocator.alloc(SerializableStruct(p.child), value.len);
            for (0..value.len) |i| {
                ar[i] = try serialize(p.child, allocator, value[i]);
            }
            return ar;
        },
        else => return value,
    }
}

pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, value: SerializableStruct(T)) !T {
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
        .@"array" => |a| {
            var ar: T = undefined;
            for (0..a.len) |i| {
                const v = try deserialize(a.child, allocator, value[i]);
                ar[i] = v;
            }
            return ar;
        },
        .pointer => |p| {
            std.debug.assert(p.size == .Many or p.size == .Slice);
            const ar = try allocator.alloc(p.child, value.len);
            for (0..value.len) |i| {
                ar[i] = try deserialize(p.child, allocator, value[i]);
            }
            return ar;
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
        try std.testing.expectEqual(SerializableStruct(S0.Serde.T) { .a = 1, .b = 2 }, ser);
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
        try std.testing.expectEqual(SerializableStruct(S1) { 
            .a = 1, 
            .s0 = SerializableStruct(S0.Serde.T) { .a = 1, .b = 2 },
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
        try std.testing.expectEqual(SerializableStruct(S2.Serde.T) { 
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
        try std.testing.expectEqual(SerializableStruct(AS) { 
            .ar = [_]SerializableStruct(S0.Serde.T){
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
        try std.testing.expectEqualDeep(SerializableStruct(AS) {
            .ar = &[_]SerializableStruct(S2.Serde.T){
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
