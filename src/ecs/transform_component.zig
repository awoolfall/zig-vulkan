const std = @import("std");
const eng = @import("self");
const sr = eng.serialize;
const zm = eng.zmath;

pub const COMPONENT_UUID = "91759bfb-2d89-4758-934d-f46ba94ae2a7";
pub const COMPONENT_NAME = "Transform";

const Self = @This();

transform: eng.Transform = .{},

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return .{};
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try sr.serialize_object_value(alloc, object, eng.Transform, "transform", self.transform);
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    var component: Self = .{};

    component.transform = try sr.deserialize_object_value(alloc, &object, eng.Transform, "transform") orelse component.transform;

    return component;
}

pub fn editor_ui(imui: *eng.Imui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = entity;

    const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(outer_layout)) |w| {
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
        w.children_gap = 5.0;
    }

    {
        _ = imui.push_form_layout_item(.{@src()});
        defer imui.pop_layout();

        _ = eng.Imui.widgets.label.create(imui, "position: ");
        _ = eng.Imui.widgets.number_slider.create(imui, &component.transform.position[0], .{}, key ++ .{@src()});
        _ = eng.Imui.widgets.number_slider.create(imui, &component.transform.position[1], .{}, key ++ .{@src()});
        _ = eng.Imui.widgets.number_slider.create(imui, &component.transform.position[2], .{}, key ++ .{@src()});
    }
    {
        _ = imui.push_form_layout_item(.{@src()});
        defer imui.pop_layout();

        _ = eng.Imui.widgets.label.create(imui, "rotation: ");
        var rot = zm.loadArr3(zm.quatToRollPitchYaw(component.transform.rotation)) * zm.f32x4s(180.0 / std.math.pi);
        const rx = eng.Imui.widgets.number_slider.create(imui, &rot[0], .{}, key ++ .{@src()});
        const ry = eng.Imui.widgets.number_slider.create(imui, &rot[1], .{}, key ++ .{@src()});
        const rz = eng.Imui.widgets.number_slider.create(imui, &rot[2], .{}, key ++ .{@src()});

        if (rx.data_changed or ry.data_changed or rz.data_changed) {
            rot = rot * zm.f32x4s(std.math.pi / 180.0);
            component.transform.rotation = zm.quatFromRollPitchYawV(rot);
        }
    }
    {
        _ = imui.push_form_layout_item(.{@src()});
        defer imui.pop_layout();

        _ = eng.Imui.widgets.label.create(imui, "scale: ");
        _ = eng.Imui.widgets.number_slider.create(imui, &component.transform.scale[0], .{}, key ++ .{@src()});
        _ = eng.Imui.widgets.number_slider.create(imui, &component.transform.scale[1], .{}, key ++ .{@src()});
        _ = eng.Imui.widgets.number_slider.create(imui, &component.transform.scale[2], .{}, key ++ .{@src()});
    }
}
