const tf = @import("transform.zig");
const zm = @import("zmath");
const ip = @import("../input/input.zig");
const kc = @import("../input/keycode.zig");
const tm = @import("../engine/time.zig");

const CameraBufferStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
};

inline fn float_from_bool(in: bool) f32 {
    return @floatFromInt(@intFromBool(in));
}

pub const Camera = struct {
    const Self = @This();

    transform: tf.Transform,
    field_of_view_y: f32,
    near_field: f32,
    far_field: f32,

    mouse_sensitivity: f32,
    move_speed: f32,

    pub fn generate_perspective_matrix(self: *Self, aspect_ratio: f32) zm.Mat {
        return zm.perspectiveFovLh(self.field_of_view_y, aspect_ratio, self.near_field, self.far_field);
    }

    pub fn update(self: *Self, input: *const ip.InputState, time: *const tm.TimeState) void {
        { // Camera Movement
            const move_amount = self.move_speed * time.delta_time_f32();
            const cam_x = 
                float_from_bool(input.get_key(kc.KeyCode.A)) * -move_amount + 
                float_from_bool(input.get_key(kc.KeyCode.D)) * move_amount;
            const cam_z = 
                float_from_bool(input.get_key(kc.KeyCode.S)) * -move_amount + 
                float_from_bool(input.get_key(kc.KeyCode.W)) * move_amount;
            self.transform.position += 
                self.transform.forward_direction() * zm.f32x4s(cam_z) + 
                self.transform.right_direction() * zm.f32x4s(cam_x);
        }
        
        // Camera rotation
        if (input.get_key(kc.KeyCode.MouseRight)) {
            self.transform.rotation = zm.qmul(
                self.transform.rotation, 
                zm.quatFromAxisAngle(
                    zm.f32x4(0.0, 1.0, 0.0, 0.0), 
                    self.mouse_sensitivity * input.mouse_delta.x
                )
            );
            self.transform.rotation = zm.qmul(
                self.transform.rotation, 
                zm.quatFromAxisAngle(
                    self.transform.right_direction(), 
                    self.mouse_sensitivity * input.mouse_delta.y
                )
            );
        }
    }
};

