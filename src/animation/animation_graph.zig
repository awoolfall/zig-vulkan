const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const es = eng.util.easings;
const sr = eng.serialize;
const Transform = eng.Transform;
const an = @import("animation.zig");

const Self = @This();

pub const ControlData = struct {
    active_node: u32 = 0,
    active_time: f32 = 0.0,

    variable_map: std.AutoHashMap(u32, f32),

    transition: ?struct {
        to_node: u32,
        transition_start_time: f32,
        duration: f32,
    } = null,

    pub fn deinit(self: *ControlData) void {
        self.variable_map.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !ControlData {
        const variable_map = std.AutoHashMap(u32, f32).init(alloc);

        return ControlData {
            .variable_map = variable_map,
        };
    }
};

alloc: std.mem.Allocator,
nodes: std.ArrayList(Node),
base_animation: ?eng.assets.AnimationAssetId = null,

pub fn deinit(self: *Self) void {
    self.clear_nodes();
    self.nodes.deinit(self.alloc);
}

pub fn clear_nodes(self: *Self) void {
    for (self.nodes.items) |node| {
        node.deinit(self.alloc);
    }
    self.nodes.clearRetainingCapacity();
}

pub fn init(alloc: std.mem.Allocator, nodes: []const Node) !Self {
    var nodes_list = try std.ArrayList(Node).initCapacity(alloc, nodes.len);
    errdefer nodes_list.deinit(alloc);
    errdefer for (nodes_list.items) |n| { n.deinit(alloc); };

    for (nodes) |n| {
        var owned_node = n;

        owned_node.next = try alloc.dupe(NodeTransition, n.next);
        errdefer alloc.free(owned_node.next);

        try nodes_list.append(alloc, owned_node);
    }

    return Self {
        .alloc = alloc,
        .nodes = nodes_list,
    };
}

pub fn serialize(alloc: std.mem.Allocator, value: Self) !std.json.Value {
    var object = std.json.ObjectMap.init(alloc);
    errdefer object.deinit();

    try object.put("nodes", try sr.serialize_value([]const Node, alloc, value.nodes.items));
    try object.put("base_animation", try sr.serialize_value(?eng.assets.AnimationAssetId, alloc, value.base_animation));

    return std.json.Value { .object = object };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    var anim_controller = try Self.init(alloc);
    errdefer anim_controller.deinit();

    const object = switch (value) { .object => |obj| obj, else => return error.InvalidType };

    anim_controller.nodes.clearRetainingCapacity();
    if (object.get("nodes")) |v| blk: {
        const nodes = sr.deserialize_value([]Node, alloc, v) catch break :blk;
        defer alloc.free(nodes);

        try anim_controller.nodes.appendSlice(eng.get().general_allocator, nodes);
    }

    if (object.get("base_animation")) |v| blk: { anim_controller.base_animation = sr.deserialize_value(?eng.assets.AnimationAssetId, alloc, v) catch break :blk; }

    return anim_controller;
}

/// Calculates the bone transforms for a given node.
/// This function will blend between the base animation and the animation specified in the node.
fn calculate_bone_transforms_for_node(
    self: *const Self,
    model: *const eng.mesh.Model,
    node: *const Node,
    time_seconds: f32,
    data: *const ControlData,
    out_transforms: []Transform
) void {
    @memset(out_transforms[0..], Transform{});

    switch (node.node) {
        .Basic => |basic| blk: {
            const animation_asset = eng.get().asset_manager.get_asset(eng.assets.AnimationAsset, basic.animation)
                catch break :blk;
            const animation: *eng.animation.QuantisedBoneAnimation = animation_asset.get_animation()
                catch break :blk;

            for (model.bones_info, 0..) |bone_info, i| {
                const channel = animation.find_node_anim(bone_info.bone_name) orelse continue;
                out_transforms[i] = channel.transform_at_time(animation.time_in_ticks(time_seconds));
            }
        },
        .Blend1D => |blend| blk: {
            var blend_variable: f32 = 0.0;
            if (blend.variable) |variable| {
                blend_variable = self.get_variable_by_id(variable, data) orelse 0.0;
            }

            std.debug.assert(blend.left_value <= blend.right_value);
            const blend_value = std.math.clamp((blend_variable - blend.left_value) / (blend.right_value - blend.left_value), 0.0, 1.0);

            const left_animation_asset = eng.get().asset_manager.get_asset(eng.assets.AnimationAsset, blend.left_animation)
                catch break :blk;
            const left_animation: *eng.animation.QuantisedBoneAnimation = left_animation_asset.get_animation()
                catch break :blk;

            var strength: f32 = 1.0;
            if (blend.left_strength_variable) |strength_variable| {
                strength = self.get_variable_by_id(strength_variable, data) orelse 1.0;
            }

            // blend in right animation based on blend variable
            const right_animation_asset = eng.get().asset_manager.get_asset(eng.assets.AnimationAsset, blend.right_animation)
                catch break :blk;
            const right_animation: *eng.animation.QuantisedBoneAnimation = right_animation_asset.get_animation()
                catch break :blk;

            strength = 1.0;
            if (blend.right_strength_variable) |strength_variable| {
                strength = self.get_variable_by_id(strength_variable, data) orelse 1.0;
            }

            for (model.bones_info, 0..) |bone_info, i| {
                const left_transform: ?Transform = tblk: {
                    const left_channel = left_animation.find_node_anim(bone_info.bone_name) orelse break :tblk null;
                    break :tblk left_channel.transform_at_time(left_animation.time_in_ticks(time_seconds));
                };
                const right_transform: ?Transform = tblk: {
                    const right_channel = right_animation.find_node_anim(bone_info.bone_name) orelse break :tblk null;
                    break :tblk right_channel.transform_at_time(left_animation.time_in_ticks(time_seconds));
                };

                if (left_transform != null and right_transform != null) {
                    out_transforms[i] = Transform.lerp(left_transform.?, right_transform.?, blend_value);
                } else if (left_transform == null and right_transform != null) {
                    out_transforms[i] = right_transform.?;
                } else if (left_transform != null and right_transform == null) {
                    out_transforms[i] = left_transform.?;
                } else {
                    out_transforms[i] = Transform {};
                }
            }
        },
    }
}

/// Generates the bone transform matricies for the current active node and any transitioning nodes.
pub fn calculate_bone_transforms(
    self: *const Self,
    alloc: std.mem.Allocator,
    model: *const eng.mesh.Model,
    data: *const ControlData,
    out_transforms: []zm.Mat
) void {
    // calculate the transforms for the current active node
    var active_node_transforms = [_]Transform{.{}} ** eng.mesh.MAX_BONES;
    self.calculate_bone_transforms_for_node(model, &self.nodes.items[data.active_node], data.active_time, data, active_node_transforms[0..]);

    // calculate and blend the transforms for any transitioning nodes based on the transition timings and easing
    if (data.transition) |transition| {
        const transition_time_seconds = data.active_time - transition.transition_start_time;
        var transition_node_transforms = [_]Transform{.{}} ** eng.mesh.MAX_BONES;
        self.calculate_bone_transforms_for_node(model, &self.nodes.items[transition.to_node], transition_time_seconds, data, transition_node_transforms[0..]);

        for (0..active_node_transforms.len) |i| {
            const t = transition_time_seconds / transition.duration;
            const eased_t = eng.util.easings.Easing.OutLinear.ease(t); // TODO: FIX: get easing from transition
            active_node_transforms[i] = Transform.lerp(active_node_transforms[i], transition_node_transforms[i], eased_t);
        }
    }
    
    // generate and return the final bone transforms
    @memset(out_transforms[0..], zm.identity());
    model.generate_bone_transforms_for_pose(alloc, active_node_transforms[0..], out_transforms[0..]);
}

/// Hashes a variable id for future use.
pub fn hash_variable(variable_id: anytype) u32 {
    return std.hash.XxHash32.hash(0, variable_id);
}

/// Sets a variable specified by the hashed variable id to the given value.
pub fn set_variable_by_id(self: *const Self, variable_id: u32, value: f32, data: *ControlData) void {
    _ = self;
    data.variable_map.put(variable_id, value) catch |err| {
        std.log.err("Unable to put animation variable in hash map: {}", .{err});
    };
}

/// Sets a variable specified by the variable name to the given value.
pub fn set_variable(self: *const Self, variable_name: []const u8, value: f32, data: *ControlData) void {
    self.set_variable_by_id(Self.hash_variable(variable_name), value, data);
}

/// Sets a variable specified by the hashed variable id to the given value.
pub fn get_variable_by_id(self: *const Self, variable_id: u32, data: *const ControlData) ?f32 {
    _ = self;
    return data.variable_map.get(variable_id);
}

/// Sets a variable specified by the variable name to the given value.
pub fn get_variable(self: *const Self, variable_name: []const u8, data: *const ControlData) ?f32 {
    return self.get_variable_by_id(Self.hash_variable(variable_name), data);
}

/// Triggers an event specified by the hashed event id.
pub fn trigger_event_by_id(self: *Self, event_id: u32, data: *ControlData) void {
    const active_node = &self.nodes.items[data.active_node];
    outer: for (active_node.next) |*node_transition| {
        switch (node_transition.condition) {
            .Event => |e| {
                if (event_id == e.variable_id) {
                    perform_transition(node_transition, data);
                    break :outer;
                }
            },
            else => {}
        }
    }
}

/// Triggers an event specified by the event name.
pub fn trigger_event(self: *Self, event_name: []const u8, data: *ControlData) void {
    self.trigger_event_by_id(Self.hash_variable(event_name), data);
}

pub fn perform_transition(transition: *const NodeTransition, data: *ControlData) void {
    if (data.transition == null) {
        data.transition = .{
            .to_node = @intCast(transition.node),
            .transition_start_time = data.active_time,
            .duration = transition.transition_duration,
        };
    }
}

/// Updates the animation controller state and transitions to a new node if necessary.
pub fn update(graph: *Self, data: *ControlData) void {
    // check if we should transition to a new node
    for (graph.nodes.items[data.active_node].next) |*transition| fblk: {
        const should_transition = switch (transition.condition) {
            .Always => blk: {
                const animation_id = switch (graph.nodes.items[data.active_node].node) {
                    .Basic => |basic| basic.animation,
                    .Blend1D => |blend| blend.left_animation,
                };
                const animation_asset = eng.get().asset_manager.get_asset(eng.assets.AnimationAsset, animation_id) catch break :blk false;
                const animation: *eng.animation.QuantisedBoneAnimation = animation_asset.get_animation() catch break :blk false;

                break :blk (data.active_time >= (animation.duration_seconds - transition.transition_duration));
            },
            .Float => |condition| blk: {
                const value = data.variable_map.get(condition.variable_id) orelse break :blk false;

                switch (condition.comparison) {
                    .Equal => break :blk std.math.approxEqRel(f32, value, condition.value, std.math.floatEps(f32)),
                    .NotEqual => break :blk !std.math.approxEqRel(f32, value, condition.value, std.math.floatEps(f32)),
                    .LessThan => break :blk (value < condition.value),
                    .GreaterThan => break :blk (value > condition.value),
                }

                break :blk false;
            },
            else => false,
        };

        if (should_transition) {
            eng.AnimationGraph.perform_transition(transition, data);
            break :fblk;
        }
    }
    
    // update active animation time
    data.active_time += eng.get().time.delta_time_f32();

    // update transition timings
    if (data.transition) |*transition| {
        if ((data.active_time - transition.transition_start_time) >= transition.duration) {
            data.active_node = transition.to_node;
            data.active_time = data.active_time - transition.transition_start_time;
            data.transition = null;
        }
    }
}

pub const NodeType = union(enum) {
    Basic: BasicNode,
    Blend1D: BlendNode1D,
};

/// A node in the animation controller state machine.
pub const Node = struct {
    node: NodeType,
    next: []const NodeTransition,

    pub fn deinit(self: *const Node, alloc: std.mem.Allocator) void {
        alloc.free(self.next);
    }
};

/// A transition specification between two nodes in the animation controller state machine.
pub const NodeTransition = struct {
    node: usize,
    condition: TransitionCondition,
    transition_duration: f32 = 0.0,
    transition_easing: es.Easing = .OutLinear,
};

/// A transition condition that can be used to specify when a transition should occur.
pub const TransitionCondition = union(enum) {
    Always: void,
    Float: struct {
        variable_id: u32,
        comparison: enum {
            Equal,
            NotEqual,
            LessThan,
            GreaterThan,
        },
        value: f32,
    },
    Event: struct {
        variable_id: u32,
    },
};

/// A basic node in the animation controller state machine which runs a single 
/// animation with optional strength value.
pub const BasicNode = struct {
    animation: eng.assets.AnimationAssetId,
    strength_variable: ?u32 = null,
};

/// A blend node in the animation controller state machine allowing the blending
/// of animations based on a single variable value.
pub const BlendNode1D = struct {
    left_animation: eng.assets.AnimationAssetId,
    right_animation: eng.assets.AnimationAssetId,
    variable: ?u32 = null,
    left_value: f32,
    right_value: f32,
    left_strength_variable: ?u32 = null,
    right_strength_variable: ?u32 = null,
};
