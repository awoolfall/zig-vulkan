const std = @import("std");
const zm = @import("zmath");
const Transform = @import("transform.zig");
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
    selected_transform: Transform = .{},

    fn find_anim_position(self: *const BoneAnimationChannel, animation_time: f64) ?usize {
        for (0..(self.position_keys.len - 1)) |i| {
            if (animation_time < self.position_keys[i + 1].time) {
                return i;
            }
        }

        return self.position_keys.len - 1;
    }

    fn find_anim_rotation(self: *const BoneAnimationChannel, animation_time: f64) ?usize {
        for (0..(self.rotation_keys.len - 1)) |i| {
            if (animation_time < self.rotation_keys[i + 1].time) {
                return i;
            }
        }

        return self.rotation_keys.len - 1;
    }

    fn find_anim_scale(self: *const BoneAnimationChannel, animation_time: f64) ?usize {
        for (0..(self.scale_keys.len - 1)) |i| {
            if (animation_time < self.scale_keys[i + 1].time) {
                return i;
            }
        }

        return self.scale_keys.len - 1;
    }

    fn select(self: *BoneAnimationChannel, animation_time: f64) void {
        var scale = self.scale_keys[0].value;
        if (self.find_anim_scale(animation_time)) |scale_idx| {
            const scale_0 = self.scale_keys[scale_idx];
            scale = scale_0.value;
            if ((scale_idx + 1) < self.scale_keys.len) {
                const scale_1 = self.scale_keys[scale_idx + 1];
                const scale_t: f32 = @floatCast((animation_time - scale_0.time) / (scale_1.time - scale_0.time));
                scale = zm.lerp(scale_0.value, scale_1.value, scale_t);
            }
        }

        var rotation = self.rotation_keys[0].value;
        if (self.find_anim_rotation(animation_time)) |rotation_idx| {
            const rotation_0 = self.rotation_keys[rotation_idx];
            rotation = rotation_0.value;
            if ((rotation_idx + 1) < self.rotation_keys.len) {
                const rotation_1 = self.rotation_keys[rotation_idx + 1];
                const rotation_t: f32 = @floatCast((animation_time - rotation_0.time) / (rotation_1.time - rotation_0.time));
                rotation = zm.slerp(rotation_0.value, rotation_1.value, rotation_t);
            }
        }

        var position = self.position_keys[0].value;
        if (self.find_anim_position(animation_time)) |position_idx| {
            const position_0 = self.position_keys[position_idx];
            position = position_0.value;
            if ((position_idx + 1) < self.position_keys.len) {
                const position_1 = self.position_keys[position_idx + 1];
                const position_t: f32 = @floatCast((animation_time - position_0.time) / (position_1.time - position_0.time));
                position = zm.lerp(position_0.value, position_1.value, position_t);
            }
        }

        self.selected_transform.position = position;
        self.selected_transform.rotation = rotation;
        self.selected_transform.scale = scale;
    }
};

pub const BoneAnimation = struct {
    name: []u8,
    duration_ticks: f64,
    ticks_per_second: f64,
    channels: []BoneAnimationChannel,
    current_tick: f64 = 0.0,

    pub fn find_node_anim(self: *const BoneAnimation, name: []const u8) ?*const BoneAnimationChannel {
        for (self.channels) |*channel| {
            if (std.mem.eql(u8, channel.node_name, name)) {
                return channel;
            }
        }
        return null;
    }

    pub fn time_to_ticks(self: *const BoneAnimation, time_in_seconds: f64) f64 {
        var ticks_per_second = self.ticks_per_second;
        if (ticks_per_second == 0.0) { ticks_per_second = 25.0; }

        return time_in_seconds * ticks_per_second;
    }

    pub fn set_animation_to_time(
        self: *BoneAnimation,
        time_in_seconds: f64
    ) void {
        const time_in_ticks = time_to_ticks(self, time_in_seconds);
        self.current_tick = @mod(time_in_ticks, self.duration_ticks);

        // set all channels to the specified animation time
        for (self.channels) |*c| {
            c.select(self.current_tick);
        }
    }
};


