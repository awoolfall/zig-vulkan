const std = @import("std");
const builtin = @import("builtin");
const zm = @import("self").zmath;

pub fn serialize_value(comptime Type: type, alloc: std.mem.Allocator, value: Type) !std.json.Value {
    switch (Type) {
        void => return std.json.Value { .object = std.json.ObjectMap.init(alloc), },
        bool => return std.json.Value { .bool = value, },
        i16 => return std.json.Value { .integer = @intCast(value), },
        i32 => return std.json.Value { .integer = @intCast(value), },
        i64 => return std.json.Value { .integer = value, },
        u16 => return std.json.Value { .integer = @intCast(value), },
        u32 => return std.json.Value { .integer = @intCast(value), },
        usize => return std.json.Value { .integer = @intCast(value), },
        f64 => return std.json.Value { .float = value, },
        f32 => return std.json.Value { .float = @floatCast(value), },
        ([]const u8) => return std.json.Value { .string = try alloc.dupe(u8, value), },
        zm.F32x4 => {
            var array = try std.array_list.Managed(std.json.Value).initCapacity(alloc, 4);
            errdefer array.deinit();
            for (0..4) |idx| {
                try array.append(std.json.Value { .float = value[idx] });
            }
            return std.json.Value { .array = array };
        },
        else => {
            switch (@typeInfo(Type)) {
                .optional => |opt| return if (value == null) std.json.Value { .null = {} } else try serialize_value(opt.child, alloc, value.?),
                .@"enum" => return std.json.Value { .string = try alloc.dupe(u8, @tagName(value)), },
                .@"struct" => |struct_type| return try serialize_struct(Type, alloc, value, struct_type),
                .@"union" => |union_type| return try serialize_union(Type, alloc, value, union_type),
                .pointer => |pointer_type| return try serialize_pointer(Type, alloc, value, pointer_type),
                .array => |array_type| return try serialize_array(Type, alloc, value, array_type),
                else => @compileError(std.fmt.comptimePrint("Unsupported type: {}", .{Type})),
            }
        },
    }
}

fn serialize_struct(comptime Type: type, alloc: std.mem.Allocator, value: Type, struct_type: std.builtin.Type.Struct) !std.json.Value {
    if (@hasDecl(Type, "serialize")) {
        return try Type.serialize(alloc, value);
    } else {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        inline for (struct_type.fields) |field| {
            try object.put(field.name, try serialize_value(field.type, alloc, @field(value, field.name)));
        }

        return std.json.Value { .object = object };
    }
}

fn serialize_union(comptime Type: type, alloc: std.mem.Allocator, value: Type, union_type: std.builtin.Type.Union) !std.json.Value {
    if (@hasDecl(Type, "serialize")) {
        return try Type.serialize(alloc, value);
    } else {
        if (union_type.tag_type) |_| {
            var object = std.json.ObjectMap.init(alloc);
            errdefer object.deinit();

            inline for (union_type.fields) |field| {
                if (std.mem.eql(u8, @tagName(value), field.name)) {
                    try object.put(field.name, try serialize_value(field.type, alloc, @field(value, field.name)));
                }
            }

            return std.json.Value { .object = object };
        } else {
            @compileError("Serializing unions without a tag type are not supported");
        }
    }
}

fn serialize_pointer(comptime Type: type, alloc: std.mem.Allocator, value: Type, pointer_type: std.builtin.Type.Pointer) !std.json.Value {
    switch (pointer_type.size) {
        .slice => {},
        else => @compileError(std.fmt.comptimePrint("Serializing pointer type is not supported: {}", .{Type})),
    }

    var list = std.json.Array.init(alloc);
    errdefer list.deinit();

    for (value) |v| {
        try list.append(try serialize_value(pointer_type.child, alloc, v));
    }

    return std.json.Value { .array = list };
}

fn serialize_array(comptime Type: type, alloc: std.mem.Allocator, value: Type, array_type: std.builtin.Type.Array) !std.json.Value {
    var array = try std.array_list.Managed(std.json.Value).initCapacity(alloc, 4);
    errdefer array.deinit();
    inline for (0..array_type.len) |idx| {
        try array.append(try serialize_value(array_type.child, alloc, value[idx]));
    }
    return std.json.Value { .array = array };
}

pub fn deserialize_value(comptime Type: type, alloc: std.mem.Allocator, value: std.json.Value) !Type {
    switch (Type) {
        void => switch (value) { .object => {}, else => return error.InvalidType, },
        bool => switch (value) { .bool => |b| return b, else => return error.InvalidType, },
        i16 => switch (value) { .integer => |i| return @intCast(i), else => return error.InvalidType, },
        i32 => switch (value) { .integer => |i| return @intCast(i), else => return error.InvalidType, },
        i64 => switch (value) { .integer => |i| return i, else => return error.InvalidType, },
        u16 => switch (value) { .integer => |i| return @intCast(i), else => return error.InvalidType, },
        u32 => switch (value) { .integer => |i| return @intCast(i), else => return error.InvalidType, },
        usize => switch (value) { .integer => |i| return @intCast(i), else => return error.InvalidType, },
        f64 => switch (value) { .float => |f| return f, .integer => |i| return @floatFromInt(i), else => return error.InvalidType, },
        f32 => switch (value) { .float => |f| return @floatCast(f), .integer => |i| return @floatFromInt(i), else => return error.InvalidType, },
        ([]const u8) => switch (value) { .string => |s| return try alloc.dupe(u8, s), else => return error.InvalidType, },
        zm.F32x4 => {
            const arr = switch (value) { .array => |arr| arr, else => return error.InvalidType, };
            if (arr.items.len != 4) { return error.InvalidNumberOfArrayElements; }
            var f32x4 = zm.f32x4s(0.0);
            inline for (0..4) |idx| {
                f32x4[idx] = try deserialize_value(f32, alloc, arr.items[idx]);
            }
            return f32x4;
        },
        else => {
            switch (@typeInfo(Type)) {
                .optional => |opt| switch (value) { .null => return null, else => return try deserialize_value(opt.child, alloc, value), },
                .@"enum" => switch (value) { .string => |s| return std.meta.stringToEnum(Type, s) orelse return error.InvalidEnum, else => return error.InvalidType, },
                .@"struct" => |struct_type| return try deserialize_struct(Type, alloc, value, struct_type),
                .@"union" => |union_type| return try deserialize_union(Type, alloc, value, union_type),
                .pointer => |pointer_type| return try deserialize_pointer(Type, alloc, value, pointer_type),
                .array => |array_type| return try deserialize_array(Type, alloc, value, array_type),
                else => @compileError(std.fmt.comptimePrint("Unsupported type: {}", .{Type})),
            }
        },
    }
}

fn deserialize_struct(comptime Type: type, alloc: std.mem.Allocator, value: std.json.Value, struct_type: std.builtin.Type.Struct) !Type {
    if (@hasDecl(Type, "deserialize")) {
        return try Type.deserialize(alloc, value);
    } else {
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType };

        // default values arena
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        var ret: Type = undefined;
        inline for (struct_type.fields) |field| {
            const field_value: ?std.json.Value = object.get(field.name) orelse blk: {
                if (field.defaultValue()) |default_value| {
                    break :blk serialize_value(field.type, arena.allocator(), default_value) catch null;
                } else {
                    return error.IncompleteStruct;
                }
            };
            if (field_value) |fv| {
                @field(ret, field.name) = try deserialize_value(field.type, alloc, fv);
            }
        }
        return ret;
    }
}

fn deserialize_union(comptime Type: type, alloc: std.mem.Allocator, value: std.json.Value, union_type: std.builtin.Type.Union) !Type {
    if (@hasDecl(Type, "deserialize")) {
        return try Type.deserialize(alloc, value);
    } else {
        if (union_type.tag_type) |_| {
            const object = switch (value) { .object => |obj| obj, else => return error.InvalidType };

            var iterator = object.iterator();
            if (iterator.next()) |pair| {
                inline for (union_type.fields) |field| {
                    if (std.mem.eql(u8, field.name, pair.key_ptr.*)) {
                        return @unionInit(Type, field.name, try deserialize_value(@FieldType(Type, field.name), alloc, pair.value_ptr.*));
                    }
                }
            }
        } else {
            @compileError("Deserializing unions without a tag type are not supported");
        }
        return error.IncompleteStruct;
    }
}

fn deserialize_pointer(comptime Type: type, alloc: std.mem.Allocator, value: std.json.Value, pointer_type: std.builtin.Type.Pointer) !Type {
    switch (pointer_type.size) {
        .slice => {},
        else => @compileError(std.fmt.comptimePrint("Deerializing pointer type is not supported: {}", .{Type})),
    }

    const array = switch (value) { .array => |arr| arr, else => return error.InvalidType };
    
    const slice = try alloc.alloc(pointer_type.child, array.items.len);
    errdefer alloc.free(slice);

    var slice_list = std.ArrayList(pointer_type.child).initBuffer(slice);

    for (array.items) |item| {
        try slice_list.appendBounded(try deserialize_value(pointer_type.child, alloc, item));
    }

    return slice;
}

fn deserialize_array(comptime Type: type, alloc: std.mem.Allocator, value: std.json.Value, array_type: std.builtin.Type.Array) !Type {
    const arr = switch (value) { .array => |arr| arr, else => return error.InvalidType, };
    var ret_array: Type = undefined;
    inline for (0..array_type.len) |idx| {
        ret_array[idx] = try deserialize_value(array_type.child, alloc, arr.items[idx]);
    }
    return ret_array;
}
