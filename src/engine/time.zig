const std = @import("std");
const wb = @import("../window.zig");

pub const TimeState = struct {
    const Self = @This();

    frame_number: u128 = 0,
    start_time_ns: i128,
    frame_start_time_ns: i128,
    last_frame_time_s: f64,
    last_frame_wait_time_s: f64,
    target_frame_time_ns: i128,
    target_lost_focus_frame_time_ns: i128 = 1e8, // 10fps
    is_focused: bool = true,
    
    pub fn init() Self {
        return Self {
            .start_time_ns = std.time.nanoTimestamp(),
            .frame_start_time_ns = std.time.nanoTimestamp(),
            .last_frame_time_s = 1e-5,
            .last_frame_wait_time_s = 1e-5,
            .target_frame_time_ns = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn on_update(self: *Self) void {
        self.frame_number += 1;

        // collect frame time difference
        var frame_diff_ns = std.time.nanoTimestamp() - self.frame_start_time_ns;

        // if there is a target frame rate, do wait here
        self.last_frame_wait_time_s = 0.0;
        const target_frame_time_ns = if (self.is_focused) self.target_frame_time_ns else self.target_lost_focus_frame_time_ns;
        if (target_frame_time_ns != 0) {
            // calculate wait time in seconds
            self.last_frame_wait_time_s = @as(f64, @floatFromInt(target_frame_time_ns - frame_diff_ns)) / std.time.ns_per_s;

            // while loop to account for "spurious wakeups"
            while (frame_diff_ns < target_frame_time_ns) {
                // sleep remaining ns to hit desired frame rate
                std.time.sleep(@intCast(target_frame_time_ns - frame_diff_ns));

                // recollect frame diff times
                frame_diff_ns = std.time.nanoTimestamp() - self.frame_start_time_ns;
            }
        }

        self.last_frame_time_s = @as(f64, @floatFromInt(frame_diff_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.frame_start_time_ns = std.time.nanoTimestamp();
    }

    pub fn received_window_event(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .EVENTS_CLEARED => { self.on_update(); },
            .LOST_FOCUS => { self.is_focused = false; },
            .GAINED_FOCUS => { self.is_focused = true; },
            else => {},
        }
    }

    pub inline fn get_fps(self: *const Self) f64 {
        return 1.0 / self.last_frame_time_s;
    }

    pub inline fn delta_time(self: *const Self) f64 {
        return self.last_frame_time_s;
    }

    pub inline fn delta_time_f32(self: *const Self) f32 {
        return @floatCast(self.last_frame_time_s);
    }

    pub fn set_target_frame_rate(self: *Self, target_fps: f32) void {
        const desired_frame_time_ns: f128 = @as(f128, @floatCast(1.0 / target_fps)) * std.time.ns_per_s;
        self.target_frame_time_ns = @intFromFloat(desired_frame_time_ns);
    }

    pub fn clear_target_frame_rate(self: *Self) void {
        self.target_frame_time_ns = 0;
    }

    pub fn time_since_start_of_app(self: *const Self) f64 {
        return @as(f64, @floatFromInt((self.frame_start_time_ns - self.start_time_ns))) / std.time.ns_per_s;
    }
};

