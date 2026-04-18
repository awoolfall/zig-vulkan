const zm = @import("zmath");

const Self = @This();

min: zm.F32x4,
max: zm.F32x4,

pub fn center(self: *const Self) zm.F32x4 {
    return (self.max + self.min) / zm.f32x4s(2.0);
}