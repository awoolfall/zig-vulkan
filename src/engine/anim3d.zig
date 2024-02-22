const std = @import("std");
const ms = @import("mesh.zig");
const zm = @import("zmath");
const tm = @import("transform.zig");

pub const AnimController3d = struct {
    pub const MAX_BONES: usize = 128;
    animation: *const ms.BoneAnimation,
    start_time_ns: i128 = 0,
    node_anim_offsets: [MAX_BONES]zm.Mat = [_]zm.Mat{zm.identity()} ** MAX_BONES,

    pub fn update(self: *AnimController3d, frame_start_time_ns: i128, map: *std.AutoHashMap(i32, zm.Mat)) void {
        _ = frame_start_time_ns;
        const time: f64 = 1000.05;//@as(f64, @floatFromInt(frame_start_time_ns - self.start_time_ns)) * 0.000000001; 
        std.log.info("runnning anim", .{});
        for (self.animation.channels) |*ch| {
            std.debug.assert(ch.bone_id < MAX_BONES);

            var t = tm.Transform {};

            var found = false;
            for (ch.position_keys, 0..) |*ps, i| {
                if (time > ps.time) {
                    t.position = ch.position_keys[i].value;
                    found = true;
                }
            }
            
            for (ch.rotation_keys, 0..) |*rs, i| {
                if (time > rs.time) {
                    t.rotation = ch.rotation_keys[i].value;
                    found = true;
                }
            }

            for (ch.scale_keys, 0..) |*ss, i| {
                if (time > ss.time) {
                    t.scale = ch.scale_keys[i].value;
                    found = true;
                }
            }
            //self.node_anim_offsets[ch.bone_id] = t.generate_model_matrix();

            if (found) {
                std.log.info("{} scale is {}", .{ch.bone_id, t.scale});
                map.put(@intCast(ch.bone_id), t.generate_model_matrix()) catch unreachable;
            }
        }
    }
};
