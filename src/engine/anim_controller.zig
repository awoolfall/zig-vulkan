const std = @import("std");
const zm = @import("zmath");
const ms = @import("mesh.zig");
const tm = @import("time.zig");
const Transform = @import("transform.zig");
const an = @import("animation.zig");
const as = @import("../asset/asset.zig");
const es = @import("../easings.zig");
const sr = @import("../serialize/serialize.zig");

/// Animation Controller provides a state machine for controlling skeletal animations. 
/// It provides functionality to blend between animations based on variable values and node transitions.
pub const AnimController = struct {
    const Self = @This();
    arena: std.heap.ArenaAllocator,
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
    
    pub const Descriptor = struct {
        nodes: []Node,
        base_animation: ?as.AnimationAssetId = null,
    };

    pub fn init(alloc: std.mem.Allocator, desc: Descriptor) !AnimController {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        var arena_alloc = arena.allocator();

        const owned_nodes = try arena_alloc.dupe(Node, desc.nodes);
        errdefer arena_alloc.free(owned_nodes);

        for (owned_nodes) |*node| {
            node.next = try arena_alloc.dupe(NodeTransition, node.next);
        }

        var variables = std.AutoHashMap(u32, f32).init(alloc);
        errdefer variables.deinit();

        return AnimController{
            .arena = arena,
            .variables = variables,
            .nodes = owned_nodes,
            .base_animation = desc.base_animation,
        };
    }

    pub fn descriptor(self: *const Self, alloc: std.mem.Allocator) !Descriptor {
        const owned_nodes = try alloc.dupe(Node, self.nodes);
        errdefer alloc.free(owned_nodes);

        return Descriptor {
            .nodes = owned_nodes,
            .base_animation = self.base_animation,
        };
    }

    /// Calculates the bone transforms for a given node.
    /// This function will blend between the base animation and the animation specified in the node.
    fn calculate_bone_transforms_for_node(self: *Self, asset_manager: *as.AssetManager, model: *const ms.Model, node: *const Node, out_transforms: []Transform) void {
        @memset(out_transforms[0..], Transform{});

        // calcualte base animation transforms at full strength
        if (self.base_animation) |base_animation_id| blk: {
            const animation_asset = asset_manager.get_asset(as.AnimationAsset, base_animation_id)
                catch break :blk;
            const base_animation = animation_asset.get_animation()
                catch break :blk;

            base_animation.set_animation_to_time(self.base_animation_time);
            model.blend_animation_bone_transforms(base_animation, 1.0, out_transforms[0..]);
        }

        // blend in node animations
        switch (node.node) {
            .Basic => |basic| blk: {
                // blend in the single basic animation based on the provided strength variable
                const animation_asset = asset_manager.get_asset(as.AnimationAsset, basic.animation)
                    catch break :blk;
                const animation = animation_asset.get_animation()
                    catch break :blk;

                if (self.base_animation == null or !basic.animation.eql(self.base_animation.?)) {
                    animation.set_animation_to_time(node.time);
                }

                var strength: f32 = 1.0;
                if (basic.strength_variable) |strength_variable| {
                    strength = self.get_variable_by_id(strength_variable) orelse 1.0;
                }

                model.blend_animation_bone_transforms(animation, strength, out_transforms[0..]);
            },
            .Blend1D => |blend| blk: {
                // replace base animation with blended animation between two animations based on the provided blend variable
                var blend_variable: f32 = 0.0;
                if (blend.variable) |variable| {
                    blend_variable = self.get_variable_by_id(variable) orelse 0.0;
                }

                std.debug.assert(blend.left_value <= blend.right_value);
                const blend_value = std.math.clamp((blend_variable - blend.left_value) / (blend.right_value - blend.left_value), 0.0, 1.0);

                // replace base animation with left animation at full strength
                const left_animation_asset = asset_manager.get_asset(as.AnimationAsset, blend.left_animation)
                    catch break :blk;
                const left_animation = left_animation_asset.get_animation()
                    catch break :blk;

                if (self.base_animation == null or !blend.left_animation.eql(self.base_animation.?)) {
                    left_animation.set_animation_to_time(node.time);
                }

                var strength: f32 = 1.0;
                if (blend.left_strength_variable) |strength_variable| {
                    strength = self.get_variable_by_id(strength_variable) orelse 1.0;
                }

                model.blend_animation_bone_transforms(left_animation, 1.0 * strength, out_transforms[0..]);

                // blend in right animation based on blend variable
                const right_animation_asset = asset_manager.get_asset(as.AnimationAsset, blend.right_animation)
                    catch break :blk;
                const right_animation = right_animation_asset.get_animation()
                    catch break :blk;

                if (self.base_animation == null or !blend.right_animation.eql(self.base_animation.?)) {
                    right_animation.set_animation_to_time(node.time);
                }

                strength = 1.0;
                if (blend.right_strength_variable) |strength_variable| {
                    strength = self.get_variable_by_id(strength_variable) orelse 1.0;
                }

                model.blend_animation_bone_transforms(right_animation, blend_value * strength, out_transforms[0..]);
            },
        }
    }

    /// Generates the bone transform matricies for the current active node and any transitioning nodes.
    pub fn calculate_bone_transforms(self: *Self, alloc: std.mem.Allocator, asset_manager: *as.AssetManager, model: *const ms.Model, out_transforms: []zm.Mat) void {
        // calculate the transforms for the current active node
        var active_node_transforms = [_]Transform{.{}} ** ms.MAX_BONES;
        self.calculate_bone_transforms_for_node(asset_manager, model, &self.nodes[self.active_node], active_node_transforms[0..]);

        // calculate and blend the transforms for any transitioning nodes based on the transition timings and easing
        if (self.current_transition) |transition| {
            var transition_node_transforms = [_]Transform{.{}} ** ms.MAX_BONES;
            self.calculate_bone_transforms_for_node(asset_manager, model, &self.nodes[transition.node_0], transition_node_transforms[0..]);

            for (0..active_node_transforms.len) |i| {
                const t: f32 = @floatCast(transition.time_since_start / transition.transition_duration);
                const eased_t = transition.transition_easing.ease(t);
                active_node_transforms[i] = transition_node_transforms[i].lerp(&active_node_transforms[i], eased_t);
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
        const active_node = &self.nodes[self.active_node];
        for (active_node.next) |*node_transition| {
            switch (node_transition.condition) {
                .Event => |e| {
                    if (event_id == e.variable_id) {
                        self.perform_transition(node_transition);
                        break;
                    }
                },
                else => {}
            }
        }
    }

    /// Triggers an event specified by the event name.
    pub fn trigger_event(self: *Self, event_name: []const u8) void {
        self.trigger_event_by_id(Self.hash_variable(event_name));
    }

    fn perform_transition(self: *Self, transition: *const NodeTransition) void {
        self.current_transition = .{
            .node_0 = self.active_node,
            .node_1 = transition.node,
            .time_since_start = 0.0,
            .transition_duration = transition.transition_duration,
            .transition_easing = transition.transition_easing,
        };
        self.active_node = transition.node;
        self.nodes[self.active_node].time = 0.0;
    }

    /// Updates the animation controller state and transitions to a new node if necessary.
    pub fn update(self: *Self, asset_manager: *const as.AssetManager, time: *const tm.TimeState) void {
        // check if we should transition to a new node
        forblk: for (self.nodes[self.active_node].next) |t| {
            const should_transition = cblk: { switch (t.condition) {
                .Always => {
                    const animation_id = switch (self.nodes[self.active_node].node) {
                        .Basic => |basic| basic.animation,
                        .Blend1D => |blend| blend.left_animation,
                    };
                    const animation_asset = asset_manager.get_asset(as.AnimationAsset, animation_id)
                        catch break :cblk false;
                    const animation = animation_asset.get_animation()
                        catch break :cblk false;

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
                else => break :cblk false,
            } };

            if (should_transition) {
                self.perform_transition(&t);
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
    }
};

pub const NodeType = union(enum) {
    Basic: BasicNode,
    Blend1D: BlendNode1D,
};

/// A node in the animation controller state machine.
pub const Node = struct {
    node: NodeType,
    next: []const NodeTransition,
    time: f64 = 0.0,

    pub const Serde = struct {
        pub const T = struct {
            node: NodeType,
            next: []const NodeTransition,
        };

        pub fn serialize(alloc: std.mem.Allocator, value: Node) !T {
            return T {
                .node = value.node,
                .next = try alloc.dupe(NodeTransition, value.next),
            };
        }

        pub fn deserialize(alloc: std.mem.Allocator, value: T) !Node {
            return Node {
                .node = value.node,
                .next = try alloc.dupe(NodeTransition, value.next),
            };
        }
    };
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
