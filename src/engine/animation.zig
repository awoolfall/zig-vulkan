const std = @import("std");
const zm = @import("zmath");
const tf = @import("transform.zig");
const ms = @import("mesh.zig");

pub const AnimationKey = struct {
    time: f64,
    value: zm.F32x4,
};

pub const BoneAnimationChannel = struct {
    node_name: []const u8,
    position_keys: []AnimationKey,
    rotation_keys: []AnimationKey,
    scale_keys: []AnimationKey,

    // used in BoneAnimation to select a specific animation time
    selected_transform: tf.Transform = .{},

    fn find_anim_position(self: *const BoneAnimationChannel, animation_time: f64) usize {
        for (0..(self.position_keys.len - 1)) |i| {
            if (animation_time < self.position_keys[i + 1].time) {
                return i;
            }
        }

        return 0;
    }

    fn find_anim_rotation(self: *const BoneAnimationChannel, animation_time: f64) usize {
        for (0..(self.rotation_keys.len - 1)) |i| {
            if (animation_time < self.rotation_keys[i + 1].time) {
                return i;
            }
        }

        return 0;
    }

    fn find_anim_scale(self: *const BoneAnimationChannel, animation_time: f64) usize {
        for (0..(self.scale_keys.len - 1)) |i| {
            if (animation_time < self.scale_keys[i + 1].time) {
                return i;
            }
        }

        return 0;
    }

    fn select(self: *BoneAnimationChannel, animation_time: f64) void {
        const scale_idx = self.find_anim_scale(animation_time);
        const scale_0 = self.scale_keys[scale_idx];
        var scale = scale_0.value;
        if ((scale_idx + 1) < self.scale_keys.len) {
            const scale_1 = self.scale_keys[scale_idx + 1];
            const scale_t: f32 = @floatCast((animation_time - scale_0.time) / (scale_1.time - scale_0.time));
            scale = zm.lerp(scale_0.value, scale_1.value, scale_t);
        }

        const rotation_idx = self.find_anim_rotation(animation_time);
        const rotation_0 = self.rotation_keys[rotation_idx];
        var rotation = rotation_0.value;
        if ((rotation_idx + 1) < self.rotation_keys.len) {
            const rotation_1 = self.rotation_keys[rotation_idx + 1];
            const rotation_t: f32 = @floatCast((animation_time - rotation_0.time) / (rotation_1.time - rotation_0.time));
            rotation = zm.slerp(rotation_0.value, rotation_1.value, rotation_t);
        }

        const position_idx = self.find_anim_position(animation_time);
        const position_0 = self.position_keys[position_idx];
        var position = position_0.value;
        if ((position_idx + 1) < self.position_keys.len) {
            const position_1 = self.position_keys[position_idx + 1];
            const position_t: f32 = @floatCast((animation_time - position_0.time) / (position_1.time - position_0.time));
            position = zm.lerp(position_0.value, position_1.value, position_t);
        }

        self.selected_transform.position = position;
        self.selected_transform.rotation = rotation;
        self.selected_transform.scale = scale;
    }
};

pub const BoneAnimation = struct {
    name: []u8,
    duration: f64,
    ticks_per_second: f64,
    channels: []BoneAnimationChannel,

    pub fn find_node_anim(self: *const BoneAnimation, name: []const u8) ?*const BoneAnimationChannel {
        for (self.channels) |*channel| {
            if (std.mem.eql(u8, channel.node_name, name)) {
                return channel;
            }
        }
        return null;
    }

    pub fn set_animation_to_time(
        self: *BoneAnimation,
        time_in_seconds: f64
    ) void {
        // calculate animation time
        var ticks_per_second = self.ticks_per_second;
        if (ticks_per_second == 0.0) { ticks_per_second = 25.0; }

        const time_in_ticks = time_in_seconds * ticks_per_second;
        const animation_time = @mod(time_in_ticks, self.duration);

        // set all channels to the specified animation time
        for (self.channels) |*c| {
            c.select(animation_time);
        }
    }
};


