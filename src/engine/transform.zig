const Self = @This();

const zm = @import("zmath");

position: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
rotation: zm.Quat = zm.qidentity(),
scale: zm.F32x4 = zm.f32x4s(1.0),

pub inline fn generate_model_matrix(self: *const Self) zm.Mat {
    return zm.mul(
        zm.scaling(self.scale[0], self.scale[1], self.scale[2]),
        zm.mul(
            zm.matFromQuat(self.rotation), 
            zm.translationV(self.position)
        )
    );
}

pub inline fn generate_view_matrix(self: *const Self) zm.Mat {
    return zm.inverse(self.generate_model_matrix());
}

pub inline fn right_direction(self: *const Self) zm.F32x4 {
    return zm.rotate(self.rotation, zm.f32x4(1.0, 0.0, 0.0, 0.0));
}

pub inline fn up_direction(self: *const Self) zm.F32x4 {
    return zm.rotate(self.rotation, zm.f32x4(0.0, 1.0, 0.0, 0.0));
}

pub inline fn forward_direction(self: *const Self) zm.F32x4 {
    return zm.rotate(self.rotation, zm.f32x4(0.0, 0.0, 1.0, 0.0));
}

pub inline fn lerp(self: *const Self, other: *const Self, t: f32) Self {
    return Self {
        .position = zm.lerp(self.position, other.position, t),
        .rotation = zm.slerp(self.rotation, other.rotation, t),
        .scale = zm.lerp(self.scale, other.scale, t),
    };
}
