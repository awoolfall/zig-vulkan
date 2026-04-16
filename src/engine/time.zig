const std = @import("std");
const eng = @import("self");
const builtin = @import("builtin");

pub const TimeState = struct {
    const Self = @This();

    frame_number: u128 = 0,
    app_start_time: std.time.Instant,
    frame_start_time: std.time.Instant,
    last_frame_time_s: f64,
    last_frame_wait_time_s: f64,
    target_frame_time_ns: i128,
    target_lost_focus_frame_time_ns: i128 = 1e8, // 10fps
    is_focused: bool = true,
    time_scale: f64 = 1.0,
    
    pub fn init() Self {
        const start_time = std.time.Instant.now() catch unreachable;
        return Self {
            .app_start_time = start_time,
            .frame_start_time = start_time,
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
        var new_frame_start_time = std.time.Instant.now() catch unreachable;
        var frame_diff_ns = new_frame_start_time.since(self.frame_start_time);

        // if there is a target frame rate, do wait here
        const frame_wait_start_time = new_frame_start_time;
        const target_frame_time_ns = if (self.is_focused) self.target_frame_time_ns else self.target_lost_focus_frame_time_ns;
        if (target_frame_time_ns != 0) {
            // while loop to account for "spurious wakeups"
            while (frame_diff_ns < target_frame_time_ns) {
                // sleep remaining ns to hit desired frame rate
                std.Thread.sleep(@intCast(target_frame_time_ns - frame_diff_ns));

                // recollect frame diff times
                new_frame_start_time = std.time.Instant.now() catch unreachable;
                frame_diff_ns = new_frame_start_time.since(self.frame_start_time);
            }
        }
        self.last_frame_wait_time_s = @as(f64, @floatFromInt(new_frame_start_time.since(frame_wait_start_time))) / @as(f64, std.time.ns_per_s);

        self.last_frame_time_s = @as(f64, @floatFromInt(frame_diff_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        self.frame_start_time = new_frame_start_time;
    }

    pub fn received_window_event(self: *Self, event: *const eng.window.WindowEvent) void {
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
        return self.last_frame_time_s * self.time_scale;
    }

    pub inline fn delta_time_f32(self: *const Self) f32 {
        return @floatCast(self.delta_time());
    }

    pub inline fn delta_time_unscaled(self: *const Self) f64 {
        return self.last_frame_time_s;
    }

    pub inline fn delta_time_unscaled_f32(self: *const Self) f32 {
        return @floatCast(self.delta_time_unscaled());
    }

    pub fn set_target_frame_rate(self: *Self, target_fps: f32) void {
        const desired_frame_time_ns: f128 = @as(f128, @floatCast(1.0 / target_fps)) * std.time.ns_per_s;
        self.target_frame_time_ns = @intFromFloat(desired_frame_time_ns);
    }

    pub fn clear_target_frame_rate(self: *Self) void {
        self.target_frame_time_ns = 0;
    }

    pub fn time_since_start_of_app(self: *const Self) f64 {
        const diff_ms = self.frame_start_time.since(self.app_start_time) / std.time.ns_per_ms;
        return @as(f64, @floatFromInt(diff_ms)) / @as(f64, std.time.ms_per_s);
    }
};

