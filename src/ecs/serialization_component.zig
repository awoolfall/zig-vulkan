const std = @import("std");
const eng = @import("self");
const sr = eng.serialize;

pub const COMPONENT_UUID = "6fe4ecb9-a6a3-49ae-b354-d1d1f4c81462";
pub const COMPONENT_NAME = "Serialization";

const Self = @This();

serialize_id: ?u32 = null,

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return .{};
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try object.put("serialize_id", try sr.serialize_value(?u32, alloc, self.serialize_id));
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    var component: Self = .{};

    if (object.get("serialize_id")) |v| blk: { component.serialize_id = sr.deserialize_value(?u32, alloc, v) catch break :blk; }

    return component;
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = entity;

    const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(outer_layout)) |w| {
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
    }

    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = eng.ui.widgets.label.create(imui, "serialization id: ");
        const serialization_id_string = if (component.serialize_id) |serialization_id|
            try std.fmt.allocPrint(imui.widget_allocator(), "{}", .{serialization_id})
            else "TBD on next save";
        _ = eng.ui.widgets.label.create(imui, serialization_id_string);
    }
}
