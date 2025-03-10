const std = @import("std");
const builtin = @import("builtin");

pub fn SerializableStruct(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") {
        return T;
    }

    var fields: [std.meta.fields(T).len]std.builtin.Type.StructField = undefined;
    for (std.meta.fields(T), 0..) |field, i| {
        fields[i] = field;
        switch (@typeInfo(field.type)) {
            .@"struct" => |_| {
                if (@hasDecl(field.type, "Serde")) {
                    fields[i].type = SerializableStruct(field.type.Serde.T);
                } else {
                    fields[i].type = SerializableStruct(field.type);
                }
            },
            else => continue,
        }
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn serialize(comptime T: type, allocator: std.mem.Allocator, value: T) !SerializableStruct(T) {
    if (@typeInfo(T) != .@"struct") {
        return value;
    }

    var serialized: SerializableStruct(T) = undefined;
    const field_names = comptime std.meta.fieldNames(T);
    inline for (field_names) |field_name| {
        const v = blk: {
            const field_type = @FieldType(T, field_name);
            switch (@typeInfo(field_type)) {
                .@"struct" => |_| {
                    if (@hasDecl(field_type, "Serde")) {
                        const s = try field_type.Serde.serialize(allocator, @field(value, field_name));
                        const serializable_s = try serialize(field_type.Serde.T, allocator, s);
                        break :blk serializable_s;
                    } else {
                        const serializable_s = try serialize(field_type, allocator, @field(value, field_name));
                        break :blk serializable_s;
                    }
                },
                else => break :blk @field(value, field_name),
            }
        };
        @field(serialized, field_name) = v;
    }

    return serialized;
}

pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, value: SerializableStruct(T)) !T {
    if (@typeInfo(T) != .@"struct") {
        return value;
    }

    var deserialized: T = undefined;
    const field_names = comptime std.meta.fieldNames(T);
    inline for (field_names) |field_name| {
        const v = blk: {
            const field_type = @FieldType(T, field_name);
            switch (@typeInfo(field_type)) {
                .@"struct" => |_| {
                    if (@hasDecl(field_type, "Serde")) {
                        const s = try deserialize(field_type.Serde.T, allocator, @field(value, field_name));
                        const d = try field_type.Serde.deserialize(allocator, s);
                        break :blk d;
                    } else {
                        const d = try deserialize(field_type, allocator, @field(value, field_name));
                        break :blk d;
                    }
                },
                else => break :blk @field(value, field_name),
            }
        };
        @field(deserialized, field_name) = v;
    }

    return deserialized;
}
