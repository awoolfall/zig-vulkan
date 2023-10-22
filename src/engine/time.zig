const std = @import("std");
const wb = @import("../window.zig");

pub const TimeState = struct {
    const Self = @This();

    start_time_ns: i128,
    frame_start_time_ns: i128,
    last_frame_time_s: f64,
    target_frame_time_ns: i128,
    
    pub fn init() Self {
        return Self {
            .start_time_ns = std.time.nanoTimestamp(),
            .frame_start_time_ns = std.time.nanoTimestamp(),
            .last_frame_time_s = 1.0/60.0, // default to 60Hz
            .target_frame_time_ns = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn on_update(self: *Self) void {
        // collect frame start time
        var new_frame_start_time_ns = std.time.nanoTimestamp();
        var frame_diff_ns = new_frame_start_time_ns - self.frame_start_time_ns;

        // if there is a target frame rate, do wait here
        if (self.target_frame_time_ns != 0) {
            if (frame_diff_ns < self.target_frame_time_ns) {
                // sleep remaining ns to hit desired frame rate
                std.time.sleep(@intCast(self.target_frame_time_ns - frame_diff_ns));

                // recollect frame start times
                new_frame_start_time_ns = std.time.nanoTimestamp();
                frame_diff_ns = new_frame_start_time_ns - self.frame_start_time_ns;
            }
        }

        // update TimeState timing variables
        self.last_frame_time_s = @as(f64, @floatFromInt(frame_diff_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.frame_start_time_ns = new_frame_start_time_ns;
    }

    pub fn received_window_event(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .EVENTS_CLEARED => { self.on_update(); },
            else => {},
        }
    }

    pub fn get_fps(self: *Self) f64 {
        return 1.0 / self.last_frame_time_s;
    }

    pub fn delta_time_f32(self: *Self) f32 {
        return @floatCast(self.last_frame_time_s);
    }

    pub fn set_target_frame_rate(self: *Self, target_fps: f32) void {
        const desired_frame_time_ns: f128 = @as(f128, @floatCast(1.0 / target_fps)) * std.time.ns_per_s;
        self.target_frame_time_ns = @intFromFloat(desired_frame_time_ns);
    }

    pub fn clear_target_frame_rate(self: *Self) void {
        self.target_frame_time_ns = 0;
    }
};

