const std = @import("std");
const zm = @import("zmath");
const ms = @import("mesh.zig");
const tm = @import("time.zig");
const tf = @import("transform.zig");
const an = @import("animation.zig");

pub const AnimController = struct {
    const Self = @This();
    alloc: std.mem.Allocator,
    bone_transforms: []zm.Mat,

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.bone_transforms);
    }

    pub fn init(alloc: std.mem.Allocator) !AnimController {
        const bone_transforms = try alloc.alloc(zm.Mat, ms.MAX_BONES);
        errdefer alloc.free(bone_transforms);
        @memset(bone_transforms[0..], zm.identity());

        return AnimController {
            .alloc = alloc,
            .bone_transforms = bone_transforms,
        };
    }

    pub fn calculate_bone_transforms(
        self: *Self, 
        model: *const ms.Model,
        animation: *an.BoneAnimation,
        properties: struct {
            animation_1: ?*an.BoneAnimation = null,
            lerp_amount: f32 = 0.0,
        },
        time: *const tm.TimeState
    ) []const zm.Mat {
        animation.set_animation_to_time(time.time_since_start_of_app());
        if (properties.animation_1) |anim1| {
            anim1.set_animation_to_time(time.time_since_start_of_app());

            // lerp all channels by the lerp amount using 'animation' as the donor
            const lerp = zm.f32x4s(properties.lerp_amount);
            for (animation.channels) |*c| {
                if (anim1.find_node_anim(c.node_name)) |anim1_c| {
                c.selected_transform.position = 
                    zm.lerpV(c.selected_transform.position, anim1_c.selected_transform.position, lerp);
                c.selected_transform.rotation =
                    zm.slerpV(c.selected_transform.rotation, anim1_c.selected_transform.rotation, lerp);
                c.selected_transform.scale =
                    zm.lerpV(c.selected_transform.scale, anim1_c.selected_transform.scale, lerp);
                }
            }
        }

        model.generate_bone_transforms_for_animation_pose(
            animation,
            self.bone_transforms[0..]
        );

        return self.bone_transforms[0..];
    }
};
