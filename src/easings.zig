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

pub fn ease_out_elastic(t: f32) f32 {
    const c4 = (2.0 * std.math.pi) / 3.0;

    if (t <= 0.0) {
        return 0.0;
    } else if (t >= 1.0) {
        return 1.0;
    } else {
        return std.math.pow(f32, 2.0, -10.0 * t) * std.math.sin(((t * 10.0) - 0.75) * c4) + 1.0;
    }
}

pub fn ease_out_expo(t: f32) f32 {
    if (t >= 1.0) {
        return 1.0;
    } else {
        return 1.0 - std.math.pow(f32, 2.0, -10.0 * t);
    }
}

pub const Easing = union(enum) {
    Constant: void,
    OutLinear: void,
    OutQuart: void,
    OutElastic: void,
    OutExpo: void,
    Custom: *const fn(f32) f32,

    pub fn func(self: Easing) *const fn(f32) f32 {
        switch(self) {
            .Constant => return ease_constant,
            .OutLinear => return ease_out_linear,
            .OutQuart => return ease_out_quart,
            .OutElastic => return ease_out_elastic,
            .OutExpo => return ease_out_expo,
            .Custom => |f| return f,
        }
    }
};
