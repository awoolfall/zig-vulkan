const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const Transform = eng.Transform;

pub const QuantisedBoneAnimationChannel = struct {
    node_name: []const u8,
    position_keys: []zm.F32x4,
    rotation_keys: []zm.F32x4,
    scale_keys: []zm.F32x4,

    pub fn deinit(self: *const QuantisedBoneAnimationChannel, alloc: std.mem.Allocator) void {
        alloc.free(self.node_name);
        alloc.free(self.position_keys);
        alloc.free(self.rotation_keys);
        alloc.free(self.scale_keys);
    }

    fn lerp_between_frames(channel: []const zm.F32x4, frame_tick: f32) zm.F32x4 {
        std.debug.assert(channel.len != 0);
        const lower_value = channel[@intFromFloat(@mod(@floor(frame_tick), @as(f32, @floatFromInt(channel.len))))];
        const upper_value = channel[@intFromFloat(@mod(@floor(frame_tick + 1.0), @as(f32, @floatFromInt(channel.len))))];
        return zm.lerp(lower_value, upper_value, @mod(frame_tick, 1.0));
    }

    pub fn transform_at_time(self: *const QuantisedBoneAnimationChannel, frame_tick: f32) Transform {
        return Transform {
            .position = lerp_between_frames(self.position_keys, frame_tick),
            .rotation = lerp_between_frames(self.rotation_keys, frame_tick),
            .scale = lerp_between_frames(self.scale_keys, frame_tick),
        };
    }
};

pub const QuantisedBoneAnimation = struct {
    name: []u8,
    duration_ticks: usize,
    duration_seconds: f32,
    ticks_per_second: f32,
    channels: []QuantisedBoneAnimationChannel,

    pub fn deinit(self: *const QuantisedBoneAnimation, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.channels) |channel| {
            channel.deinit(alloc);
        }
        alloc.free(self.channels);
    }

    pub fn find_node_anim(self: *const QuantisedBoneAnimation, name: []const u8) ?*const QuantisedBoneAnimationChannel {
        for (self.channels) |*channel| {
            if (std.mem.eql(u8, channel.node_name, name)) {
                return channel;
            }
        }
        return null;
    }

    pub fn time_in_ticks(self: *QuantisedBoneAnimation, time_in_seconds: f32) f32 {
        return time_in_seconds * self.ticks_per_second;
    }
};

pub const AnimationKey = struct {
    time: f64,
    value: zm.F32x4,
};

pub const BoneAnimationChannel = struct {
    node_name: []const u8,
    position_keys: []AnimationKey,
    rotation_keys: []AnimationKey,
    scale_keys: []AnimationKey,

    pub fn deinit(self: *BoneAnimationChannel, alloc: std.mem.Allocator) void {
        alloc.free(self.node_name);
        alloc.free(self.position_keys);
        alloc.free(self.rotation_keys);
        alloc.free(self.scale_keys);
    }

    pub fn quantise(self: *const BoneAnimationChannel, alloc: std.mem.Allocator, out_tick_duration_seconds: f32, out_animation_duration_ticks: usize) !QuantisedBoneAnimationChannel {
        const owned_node_name = try alloc.dupe(u8, self.node_name);
        errdefer alloc.free(owned_node_name);
        
        const position_keys = try alloc.alloc(zm.F32x4, out_animation_duration_ticks);
        errdefer alloc.free(position_keys);

        const rotation_keys = try alloc.alloc(zm.F32x4, out_animation_duration_ticks);
        errdefer alloc.free(rotation_keys);

        const scale_keys = try alloc.alloc(zm.F32x4, out_animation_duration_ticks);
        errdefer alloc.free(scale_keys);

        for (0..out_animation_duration_ticks) |tick_idx| {
            const selected_transform = self.select(@as(f64, @floatFromInt(tick_idx)) * out_tick_duration_seconds);
            position_keys[tick_idx] = selected_transform.position;
            rotation_keys[tick_idx] = selected_transform.rotation;
            scale_keys[tick_idx] = selected_transform.scale;
        }

        return QuantisedBoneAnimationChannel {
            .node_name = owned_node_name,
            .position_keys = position_keys,
            .rotation_keys = rotation_keys,
            .scale_keys = scale_keys,
        };
    }

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

    fn select(self: *const BoneAnimationChannel, animation_time: f64) Transform {
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

        return Transform {
            .position = position,
            .rotation = rotation,
            .scale = scale,
        };
    }
};

pub const BoneAnimation = struct {
    name: []u8,
    duration_seconds: f64,
    channels: []BoneAnimationChannel,

    pub fn deinit(self: *BoneAnimation, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.channels) |channel| {
            channel.deinit(alloc);
        }
        alloc.free(self.channels);
    }

    pub fn quantise(self: *const BoneAnimation, alloc: std.mem.Allocator, out_tick_duration_seconds: f32) !QuantisedBoneAnimation {
        const num_ticks: usize = @intFromFloat(@ceil(self.duration_seconds / out_tick_duration_seconds));

        const owned_name = try alloc.dupe(u8, self.name);
        errdefer alloc.free(owned_name);

        const quantised_channels = try alloc.alloc(QuantisedBoneAnimationChannel, self.channels.len);
        errdefer alloc.free(quantised_channels);

        var quantised_channels_list = std.ArrayList(QuantisedBoneAnimationChannel).initBuffer(quantised_channels);
        errdefer for (quantised_channels_list.items) |c| { c.deinit(alloc); };

        for (self.channels) |channel| {
            const quantised_channel = try channel.quantise(alloc, out_tick_duration_seconds, num_ticks);
            errdefer quantised_channel.deinit(alloc);

            try quantised_channels_list.appendBounded(quantised_channel);
        }

        return QuantisedBoneAnimation {
            .name = owned_name,
            .channels = quantised_channels,
            .duration_ticks = num_ticks,
            .duration_seconds = @as(f32, @floatFromInt(num_ticks)) * out_tick_duration_seconds,
            .ticks_per_second = 1.0 / out_tick_duration_seconds,
        };
    }
};


