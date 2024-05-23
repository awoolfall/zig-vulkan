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
        animations: []const ms.Model.AnimationEntry,
    ) []const zm.Mat {
        if (animations.len == 0) { 
            @memset(self.bone_transforms[0..], zm.identity());
            return self.bone_transforms[0..];
        }

        model.generate_bone_transforms_for_animation_pose(
            animations,
            self.bone_transforms[0..]
        );

        return self.bone_transforms[0..];
    }
};
