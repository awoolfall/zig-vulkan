const std = @import("std");

pub fn ease_out_quart(x: f32) f32 {
    return 1.0 - std.math.pow(f32, 1.0 - x, 4.0);
}
