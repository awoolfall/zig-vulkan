const std = @import("std");
const zm = @import("zmath");
const ms = @import("mesh.zig");
const tm = @import("time.zig");
const tf = @import("transform.zig");
const an = @import("animation.zig");
const as = @import("../asset/asset.zig");
const es = @import("../easings.zig");

pub const AnimController = struct {
    const Self = @This();
    arena: std.heap.ArenaAllocator,
    bone_transforms: []zm.Mat,
    variables: std.AutoHashMap(u32, f32),
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
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, nodes: []const Node) !AnimController {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        var arena_alloc = arena.allocator();

        const bone_transforms = try arena_alloc.alloc(zm.Mat, ms.MAX_BONES);
        errdefer arena_alloc.free(bone_transforms);
        @memset(bone_transforms[0..], zm.identity());

        const owned_nodes = try arena_alloc.dupe(Node, nodes);
        errdefer arena_alloc.free(owned_nodes);

        for (owned_nodes) |*node| {
            node.next = try arena_alloc.dupe(NodeTransition, node.next);
        }

        const variables = std.AutoHashMap(u32, f32).init(alloc);
        errdefer variables.deinit();

        return AnimController{
            .arena = arena,
            .bone_transforms = bone_transforms,
            .variables = variables,
            .nodes = owned_nodes,
        };
    }

    pub fn calculate_bone_transforms(self: *Self, asset_manager: *as.AssetManager, model: *const ms.Model) []const zm.Mat {
        var animation_entries = [1]ms.Model.AnimationEntry{
            .{
                .animation = undefined,
                .strength = 1.0,
            },
        } ** 3;
        var num_animation_entries: usize = 0;

        if (self.base_animation) |base_animation_id| {
            if (asset_manager.get_animation(base_animation_id)) |base_animation| {
                base_animation.set_animation_to_time(self.base_animation_time);
                animation_entries[num_animation_entries] = .{
                    .animation = base_animation,
                    .strength = 1.0,
                };
                num_animation_entries += 1;
            } else |_| {}
        }

        switch (self.nodes[self.active_node].node) {
            .Basic => |basic| {
                if (asset_manager.get_animation(basic.animation)) |animation| {
                    if (self.base_animation == null or !basic.animation.asset_id.eql(self.base_animation.?.asset_id)) {
                        animation.set_animation_to_time(self.nodes[self.active_node].time);
                    }

                    animation_entries[num_animation_entries] = .{
                        .animation = animation,
                        .strength = 1.0,
                    };
                    num_animation_entries += 1;
                } else |_| {}
            },
            .Blend1D => |blend| {
                var blend_variable: f32 = 0.0;
                if (blend.variable) |variable| {
                    blend_variable = self.variables.get(variable) orelse 0.0;
                }
                std.debug.assert(blend.left_value <= blend.right_value);
                const blend_value = std.math.clamp((blend_variable - blend.left_value) / (blend.right_value - blend.left_value), 0.0, 1.0);

                if (asset_manager.get_animation(blend.left_animation)) |animation| {
                    if (self.base_animation == null or !blend.left_animation.asset_id.eql(self.base_animation.?.asset_id)) {
                        animation.set_animation_to_time(self.nodes[self.active_node].time);
                    }
                    animation_entries[num_animation_entries] = .{
                        .animation = animation,
                        .strength = 1.0,
                    };
                    num_animation_entries += 1;
                } else |_| {}

                if (asset_manager.get_animation(blend.right_animation)) |animation| {
                    if (self.base_animation == null or !blend.right_animation.asset_id.eql(self.base_animation.?.asset_id)) {
                        animation.set_animation_to_time(self.nodes[self.active_node].time);
                    }
                    animation_entries[num_animation_entries] = .{
                        .animation = animation,
                        .strength = blend_value,
                    };
                    num_animation_entries += 1;
                } else |_| {}
            },
        }

        model.generate_bone_transforms_for_animation_pose(animation_entries[0..num_animation_entries], self.bone_transforms[0..]);
        return self.bone_transforms[0..];
    }

    pub fn hash_variable(variable_id: anytype) u32 {
        return std.hash.XxHash32.hash(0, variable_id);
    }

    pub fn set_variable(self: *Self, variable_id: u32, value: f32) void {
        self.variables.put(variable_id, value) catch unreachable;
    }

    pub fn get_variable(self: *const Self, variable_id: u32) ?f32 {
        return self.variables.get(variable_id);
    }

    pub fn update(self: *Self, time: *const tm.TimeState) void {
        // check if we should transition to a new node
        forblk: for (self.nodes[self.active_node].next) |t| {
            switch (t.condition) {
                .Always => {}, // TODO transition at end of animation
                .Variable => |v| {
                    const value = self.get_variable(v.variable_id) orelse continue :forblk;

                    const should_transition = cblk: {
                        switch (v.comparison) {
                            .Equal => break :cblk std.math.approxEqRel(f32, value, v.value, std.math.floatEps(f32)),
                            .NotEqual => break :cblk !std.math.approxEqRel(f32, value, v.value, std.math.floatEps(f32)),
                            .LessThan => break :cblk (value < v.value),
                            .GreaterThan => break :cblk (value > v.value),
                        }
                    };
                    if (should_transition) {
                        self.current_transition = .{
                            .node_0 = self.active_node,
                            .node_1 = t.node,
                            .time_since_start = 0.0,
                            .transition_duration = t.transition_duration,
                            .transition_easing = t.transition_easing,
                        };
                        self.active_node = t.node;
                        break :forblk;
                    }
                },
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
    }
};

pub const Node = struct {
    node: union(enum) {
        Basic: BasicNode,
        Blend1D: BlendNode1D,
    },
    next: []const NodeTransition,
    time: f64 = 0.0,
};

pub const NodeTransition = struct {
    node: usize,
    condition: TransitionCondition,
    transition_duration: f32 = 0.0,
    transition_easing: es.Easing = .OutLinear,
};

pub const TransitionCondition = union(enum) {
    Always: void,
    Variable: struct {
        variable_id: u32,
        comparison: enum {
            Equal,
            NotEqual,
            LessThan,
            GreaterThan,
        },
        value: f32,
    },
};

pub const BasicNode = struct {
    animation: as.AnimationAssetId,
    strength_variable: ?u32 = null,
};

pub const BlendNode1D = struct {
    left_animation: as.AnimationAssetId,
    right_animation: as.AnimationAssetId,
    variable: ?u32 = null,
    left_value: f32,
    right_value: f32,
};
