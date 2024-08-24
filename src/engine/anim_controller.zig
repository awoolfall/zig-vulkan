const std = @import("std");
const zm = @import("zmath");
const ms = @import("mesh.zig");
const tm = @import("time.zig");
const tf = @import("transform.zig");
const an = @import("animation.zig");
const as = @import("../asset/asset.zig");
const es = @import("../easings.zig");

/// Animation Controller provides a state machine for controlling skeletal animations. 
/// It provides functionality to blend between animations based on variable values and node transitions.
pub const AnimController = struct {
    const Self = @This();
    arena: std.heap.ArenaAllocator,
    variables: std.AutoHashMap(u32, f32),
    triggered_events: std.ArrayList(u32),
    nodes: []Node,
    active_node: usize = 0,
    base_animation: ?as.AnimationAssetId = null,
    base_animation_time: f64 = 0.0,

    current_transition: ?struct {
        node_0: usize,
        node_1: usize,
        time_since_start: f64,
        transition_duration: f64,
        transition_easing: es.Easing,
    } = null,

    pub fn deinit(self: *Self) void {
        self.variables.deinit();
        self.triggered_events.deinit();
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, nodes: []const Node) !AnimController {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        var arena_alloc = arena.allocator();

        const owned_nodes = try arena_alloc.dupe(Node, nodes);
        errdefer arena_alloc.free(owned_nodes);

        for (owned_nodes) |*node| {
            node.next = try arena_alloc.dupe(NodeTransition, node.next);
        }

        var variables = std.AutoHashMap(u32, f32).init(alloc);
        errdefer variables.deinit();

        return AnimController{
            .arena = arena,
            .variables = variables,
            .triggered_events = try std.ArrayList(u32).initCapacity(alloc, 4),
            .nodes = owned_nodes,
        };
    }

    pub fn clone(self: *const Self, alloc: std.mem.Allocator) !AnimController {
        return try Self.init(alloc, self.nodes);
    }

    /// Calculates the bone transforms for a given node.
    /// This function will blend between the base animation and the animation specified in the node.
    fn calculate_bone_transforms_for_node(self: *Self, asset_manager: *as.AssetManager, model: *const ms.Model, node: *const Node, out_transforms: []tf.Transform) void {
        @memset(out_transforms[0..], tf.Transform{});

        // calcualte base animation transforms at full strength
        if (self.base_animation) |base_animation_id| {
            if (asset_manager.get_animation(base_animation_id)) |base_animation| {
                base_animation.set_animation_to_time(self.base_animation_time);
                model.blend_animation_bone_transforms(base_animation, 1.0, out_transforms[0..]);
            } else |_| {}
        }

        // blend in node animations
        switch (node.node) {
            .Basic => |basic| {
                // blend in the single basic animation based on the provided strength variable
                if (asset_manager.get_animation(basic.animation)) |animation| {
                    if (self.base_animation == null or !basic.animation.asset_id.eql(self.base_animation.?.asset_id)) {
                        animation.set_animation_to_time(node.time);
                    }

                    var strength: f32 = 1.0;
                    if (basic.strength_variable) |strength_variable| {
                        strength = self.get_variable_by_id(strength_variable) orelse 1.0;
                    }

                    model.blend_animation_bone_transforms(animation, strength, out_transforms[0..]);
                } else |_| {}
            },
            .Blend1D => |blend| {
                // replace base animation with blended animation between two animations based on the provided blend variable
                var blend_variable: f32 = 0.0;
                if (blend.variable) |variable| {
                    blend_variable = self.get_variable_by_id(variable) orelse 0.0;
                }

                std.debug.assert(blend.left_value <= blend.right_value);
                const blend_value = std.math.clamp((blend_variable - blend.left_value) / (blend.right_value - blend.left_value), 0.0, 1.0);

                // replace base animation with left animation at full strength
                if (asset_manager.get_animation(blend.left_animation)) |animation| {
                    if (self.base_animation == null or !blend.left_animation.asset_id.eql(self.base_animation.?.asset_id)) {
                        animation.set_animation_to_time(node.time);
                    }

                    var strength: f32 = 1.0;
                    if (blend.left_strength_variable) |strength_variable| {
                        strength = self.get_variable_by_id(strength_variable) orelse 1.0;
                    }

                    model.blend_animation_bone_transforms(animation, 1.0 * strength, out_transforms[0..]);
                } else |_| {}

                // blend in right animation based on blend variable
                if (asset_manager.get_animation(blend.right_animation)) |animation| {
                    if (self.base_animation == null or !blend.right_animation.asset_id.eql(self.base_animation.?.asset_id)) {
                        animation.set_animation_to_time(node.time);
                    }

                    var strength: f32 = 1.0;
                    if (blend.right_strength_variable) |strength_variable| {
                        strength = self.get_variable_by_id(strength_variable) orelse 1.0;
                    }

                    model.blend_animation_bone_transforms(animation, blend_value * strength, out_transforms[0..]);
                } else |_| {}
            },
        }
    }

    /// Generates the bone transform matricies for the current active node and any transitioning nodes.
    pub fn calculate_bone_transforms(self: *Self, asset_manager: *as.AssetManager, model: *const ms.Model, out_transforms: []zm.Mat) void {
        // calculate the transforms for the current active node
        var active_node_transforms = [_]tf.Transform{.{}} ** ms.MAX_BONES;
        self.calculate_bone_transforms_for_node(asset_manager, model, &self.nodes[self.active_node], active_node_transforms[0..]);

        // calculate and blend the transforms for any transitioning nodes based on the transition timings and easing
        if (self.current_transition) |transition| {
            var transition_node_transforms = [_]tf.Transform{.{}} ** ms.MAX_BONES;
            self.calculate_bone_transforms_for_node(asset_manager, model, &self.nodes[transition.node_0], transition_node_transforms[0..]);

            for (0..active_node_transforms.len) |i| {
                const t: f32 = @floatCast(transition.time_since_start / transition.transition_duration);
                const eased_t = transition.transition_easing.ease(t);
                active_node_transforms[i] = transition_node_transforms[i].lerp(&active_node_transforms[i], eased_t);
            }
        }
        
        // generate and return the final bone transforms
        @memset(out_transforms[0..], zm.identity());
        model.generate_bone_transforms_for_pose(active_node_transforms[0..], out_transforms[0..]);
    }

    /// Hashes a variable id for future use.
    pub fn hash_variable(variable_id: anytype) u32 {
        return std.hash.XxHash32.hash(0, variable_id);
    }

    /// Sets a variable specified by the hashed variable id to the given value.
    pub fn set_variable_by_id(self: *Self, variable_id: u32, value: f32) void {
        self.variables.put(variable_id, value) catch unreachable;
    }

    /// Gets the value of a variable specified by the hashed variable id.
    pub fn get_variable_by_id(self: *const Self, variable_id: u32) ?f32 {
        return self.variables.get(variable_id);
    }

    /// Sets a variable specified by the variable name to the given value.
    pub fn set_variable(self: *Self, variable_name: []const u8, value: f32) void {
        self.set_variable_by_id(Self.hash_variable(variable_name), value);
    }

    /// Gets the value of a variable specified by the variable name.
    pub fn get_variable(self: *const Self, variable_name: []const u8) ?f32 {
        return self.get_variable_by_id(Self.hash_variable(variable_name));
    }

    /// Triggers an event specified by the hashed event id.
    pub fn trigger_event_by_id(self: *Self, event_id: u32) void {
        self.triggered_events.append(event_id) catch unreachable;
    }

    /// Triggers an event specified by the event name.
    pub fn trigger_event(self: *Self, event_name: []const u8) void {
        self.trigger_event_by_id(Self.hash_variable(event_name));
    }

    /// Updates the animation controller state and transitions to a new node if necessary.
    pub fn update(self: *Self, asset_manager: *const as.AssetManager, time: *const tm.TimeState) void {
        // check if we should transition to a new node
        forblk: for (self.nodes[self.active_node].next) |t| {
            const should_transition = cblk: { switch (t.condition) {
                .Always => {
                    const animation_asset = switch (self.nodes[self.active_node].node) {
                        .Basic => |basic| basic.animation,
                        .Blend1D => |blend| blend.left_animation,
                    };
                    const animation = asset_manager.get_animation(animation_asset) catch break :cblk false;
                    const current_ticks = animation.time_to_ticks(self.nodes[self.active_node].time);
                    const transition_start_ticks = animation.time_to_ticks(t.transition_duration);
                    break :cblk (current_ticks >= animation.duration_ticks - transition_start_ticks);
                },
                .Float => |v| {
                    const value = self.get_variable_by_id(v.variable_id) orelse continue :forblk;

                    switch (v.comparison) {
                        .Equal => break :cblk std.math.approxEqRel(f32, value, v.value, std.math.floatEps(f32)),
                        .NotEqual => break :cblk !std.math.approxEqRel(f32, value, v.value, std.math.floatEps(f32)),
                        .LessThan => break :cblk (value < v.value),
                        .GreaterThan => break :cblk (value > v.value),
                    }
                },
                .Event => |e| {
                    for (self.triggered_events.items) |triggered_event| {
                        if (triggered_event == e.variable_id) {
                            break :cblk true;
                        }
                    }
                    break :cblk false;
                },
            } };

            if (should_transition) {
                self.current_transition = .{
                    .node_0 = self.active_node,
                    .node_1 = t.node,
                    .time_since_start = 0.0,
                    .transition_duration = t.transition_duration,
                    .transition_easing = t.transition_easing,
                };
                self.active_node = t.node;
                self.nodes[self.active_node].time = 0.0;
                break :forblk;
            }
        }
        
        // update active animation time
        self.nodes[self.active_node].time += time.delta_time();

        // update transition timings
        if (self.current_transition) |*transition| {
            transition.time_since_start += time.delta_time();
            self.nodes[transition.node_0].time += time.delta_time();

            // conclude transition if finished
            if (transition.time_since_start >= transition.transition_duration) {
                self.current_transition = null;
            }
        }

        // update base animation time
        self.base_animation_time += time.delta_time();

        // clear triggered events
        self.triggered_events.clearRetainingCapacity();
    }
};

/// A node in the animation controller state machine.
pub const Node = struct {
    node: union(enum) {
        Basic: BasicNode,
        Blend1D: BlendNode1D,
    },
    next: []const NodeTransition,
    time: f64 = 0.0,
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
    animation: as.AnimationAssetId,
    strength_variable: ?u32 = null,
};

/// A blend node in the animation controller state machine allowing the blending
/// of animations based on a single variable value.
pub const BlendNode1D = struct {
    left_animation: as.AnimationAssetId,
    right_animation: as.AnimationAssetId,
    variable: ?u32 = null,
    left_value: f32,
    right_value: f32,
    left_strength_variable: ?u32 = null,
    right_strength_variable: ?u32 = null,
};
