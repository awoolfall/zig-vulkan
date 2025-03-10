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

