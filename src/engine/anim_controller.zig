const std = @import("std");
const zm = @import("zmath");
const ms = @import("mesh.zig");
const tm = @import("time.zig");
const tf = @import("transform.zig");
const an = @import("animation.zig");
const as = @import("../asset/asset.zig");

pub const AnimController = struct {
    const Self = @This();
    arena: std.heap.ArenaAllocator,
    bone_transforms: []zm.Mat,
    variables: std.AutoHashMap(u32, f32),
    nodes: []Node,
    active_node: usize = 0,

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
        if (asset_manager.get_animation(self.nodes[0].animation)) |base_animation| {
            if (asset_manager.get_animation(self.nodes[self.active_node].animation)) |animation| {
                base_animation.set_animation_to_time(self.nodes[0].time);
                if (self.active_node != 0) {
                    animation.set_animation_to_time(self.nodes[self.active_node].time);
                }

                var strength: f32 = 1.0;
                if (self.nodes[self.active_node].strength_variable) |variable| {
                    strength = self.variables.get(variable) orelse 1.0;
                }

                model.generate_bone_transforms_for_animation_pose(&[_]ms.Model.AnimationEntry{
                    .{
                        .animation = base_animation,
                        .strength = 1.0,
                    },
                    .{
                        .animation = animation,
                        .strength = strength,
                    },
                }, self.bone_transforms[0..]);
            } else |e| {
                std.log.err("Failed to get animation for anim controller node: {}", .{e});
                @memset(self.bone_transforms[0..], zm.identity());
            }
        } else |_| {}

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
                .always => unreachable, // TODO transition at end of animation
                .variable => |v| {
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
                        self.active_node = t.node;
                        if (self.active_node != 0) {
                            self.nodes[self.active_node].time = 0.0;
                        }
                        break :forblk;
                    }
                },
            }
        }

        // update active animation
        self.nodes[self.active_node].time += time.delta_time();

        // update base animation if it is not the active node
        if (self.active_node != 0) {
            self.nodes[0].time += time.delta_time();
        }
    }
};

pub const Node = struct {
    const Self = @This();
    animation: as.AnimationAssetId,
    next: []const NodeTransition,
    strength_variable: ?u32 = null,
    time: f64 = 0.0,
};

pub const NodeTransition = struct {
    node: usize,
    condition: TransitionCondition,
};

pub const TransitionCondition = union(enum) {
    always: void,
    variable: struct {
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
