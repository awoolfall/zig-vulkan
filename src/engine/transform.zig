const zm = @import("zmath");

pub const Transform = struct {
    const Self = @This();

    position: zm.F32x4,
    rotation: zm.Quat,
    scale: f32,

    pub fn new() Self {
        return Self {
            .position = zm.f32x4s(0.0),
            .rotation = zm.qidentity(),
            .scale = 1.0,
        };
    }

    pub inline fn generate_model_matrix(self: *const Self) zm.Mat {
        return zm.mul(
            zm.scaling(self.scale, self.scale, self.scale),
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
};

