const std = @import("std");
const eng = @import("self");
const sr = eng.serialize;

pub const COMPONENT_UUID = "a26abe30-44ad-4e8d-90ea-7a89ac23911b";
pub const COMPONENT_NAME = "Animation Controller";

const Self = @This();

graph: *eng.AnimationGraph,
control_data: eng.AnimationGraph.ControlData,

pub fn deinit(self: *Self) void {
    self.control_data.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    return .{
        .graph = undefined,
        .control_data = try .init(alloc),
    };
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = self;
    _ = alloc;
    _ = entity;
    _ = object;
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    const component: Self = .{
        .graph = undefined,
        .control_data = try .init(alloc),
    };
    
    _ = entity;
    _ = object;
    
    return component;
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = imui;
    _ = key;
    _ = entity;
    _ = component;
}

pub fn trigger_event(self: *Self, event_name: []const u8) void {
    self.graph.trigger_event(event_name, &self.control_data);
}

pub fn set_variable(self: *Self, variable_name: []const u8, value: f32) void {
    self.graph.set_variable(variable_name, value, &self.control_data);
}
