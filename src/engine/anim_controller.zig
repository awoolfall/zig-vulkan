const std = @import("std");
const zm = @import("zmath");
const ms = @import("mesh.zig");
const tm = @import("time.zig");
const tf = @import("transform.zig");
const an = @import("animation.zig");
const as = @import("../asset/asset.zig");

pub const AnimController = struct {
    const Self = @This();
    alloc: std.mem.Allocator,
    bone_transforms: []zm.Mat,
    variables: std.AutoHashMap(u32, f32),
    nodes: []Node,
    active_node: usize = 0,

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.bone_transforms);
        self.variables.deinit();
        self.alloc.free(self.nodes);
    }

    pub fn init(alloc: std.mem.Allocator, nodes: []const Node) !AnimController {
        const bone_transforms = try alloc.alloc(zm.Mat, ms.MAX_BONES);
        errdefer alloc.free(bone_transforms);
        @memset(bone_transforms[0..], zm.identity());

        const nodes_owned = try alloc.dupe(Node, nodes);
        errdefer alloc.free(nodes_owned);

        return AnimController {
            .alloc = alloc,
            .bone_transforms = bone_transforms,
            .variables = std.AutoHashMap(u32, f32).init(alloc),
            .nodes = nodes_owned,
        };
    }

    pub fn calculate_bone_transforms(
        self: *Self,
        asset_manager: *as.AssetManager, 
        model: *const ms.Model
    ) []const zm.Mat {
        if (asset_manager.get_animation(self.nodes[self.active_node].animation)) |animation| {
            animation.set_animation_to_time(self.nodes[self.active_node].time);

            model.generate_bone_transforms_for_animation_pose(
                &[_]ms.Model.AnimationEntry {.{
                    .animation = animation,
                    .strength = 1.0,
                }},
                self.bone_transforms[0..]
            );
        } else |e| {
            std.log.err("Failed to get animation for anim controller node: {}", .{e});
            @memset(self.bone_transforms[0..], zm.identity());
        }

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
        forblk: for (self.nodes[self.active_node].next) |mt| {
            if (mt) |t| {
                switch (t.condition) {
                    .always => unreachable, // TODO transition at end of animation
                    .variable => |v| {
                        const value = self.get_variable(v.variable_id) orelse continue :forblk;

                        const should_transition = cblk: { switch (v.comparison) {
                            .Equal => break :cblk std.math.approxEqRel(f32, value, v.value, std.math.floatEps(f32)),
                            .NotEqual => break :cblk !std.math.approxEqRel(f32, value, v.value, std.math.floatEps(f32)),
                            .LessThan => break :cblk (value < v.value),
                            .GreaterThan => break :cblk (value > v.value),
                        } };
                        if (should_transition) {
                            self.active_node = t.node;
                            break :forblk;
                        }
                    },
                }
            }
        }

        self.nodes[self.active_node].time += time.delta_time();
    }
};

pub const Node = struct {
    const Self = @This();
    animation: as.AnimationAssetId,
    next: [4]?NodeTransition,
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
