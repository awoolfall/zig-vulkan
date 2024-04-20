const std = @import("std");

pub fn ease_constant(_: f32) f32 {
    return 0.0;
}

pub fn ease_out_linear(t: f32) f32 {
    return t;
}

pub fn ease_out_quart(t: f32) f32 {
    return 1.0 - std.math.pow(f32, 1.0 - t, 4.0);
}

pub const Easing = union(enum) {
    Constant: void,
    OutLinear: void,
    OutQuart: void,
    Custom: *const fn(f32) f32,

    pub fn func(self: Easing) *const fn(f32) f32 {
        switch(self) {
            .Constant => return ease_constant,
            .OutLinear => return ease_out_linear,
            .OutQuart => return ease_out_quart,
            .Custom => |f| return f,
        }
    }
};
