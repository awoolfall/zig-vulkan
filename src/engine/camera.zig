const tf = @import("transform.zig");
const zm = @import("zmath");
const kc = @import("../input/keycode.zig");
const app = @import("../app.zig");

const CameraBufferStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
};

inline fn float_from_bool(in: bool) f32 {
    return @floatFromInt(@intFromBool(in));
}

pub const Camera = struct {
    const Self = @This();

    field_of_view_y: f32,
    near_field: f32,
    far_field: f32,

    mouse_sensitivity: f32,
    move_speed: f32,

    pub fn generate_perspective_matrix(self: *Self, aspect_ratio: f32) zm.Mat {
        return zm.perspectiveFovLh(self.field_of_view_y, aspect_ratio, self.near_field, self.far_field);
    }

    pub fn fly_camera_update(self: *Self, camera_transform: *tf.Transform, engine: *app.Engine) void {
        { // Camera Movement
            const move_amount = self.move_speed * engine.time.delta_time_f32();
            const cam_x = 
                float_from_bool(engine.input.get_key(kc.KeyCode.A)) * -move_amount + 
                float_from_bool(engine.input.get_key(kc.KeyCode.D)) * move_amount;
            const cam_z = 
                float_from_bool(engine.input.get_key(kc.KeyCode.S)) * -move_amount + 
                float_from_bool(engine.input.get_key(kc.KeyCode.W)) * move_amount;
            camera_transform.position += 
                camera_transform.forward_direction() * zm.f32x4s(cam_z) + 
                camera_transform.right_direction() * zm.f32x4s(cam_x);
        }
        
        // Camera rotation
        if (engine.input.get_key_down(kc.KeyCode.MouseRight)) {
            engine.window.show_cursor(false);
            engine.window.confine_cursor_to_current_pos();
        }
        if (engine.input.get_key_up(kc.KeyCode.MouseRight)) {
            engine.window.show_cursor(true);
            engine.window.free_confined_cursor();
        }
        if (engine.input.get_key(kc.KeyCode.MouseRight)) {
            camera_transform.rotation = zm.qmul(
                camera_transform.rotation, 
                zm.quatFromAxisAngle(
                    zm.f32x4(0.0, 1.0, 0.0, 0.0), 
                    self.mouse_sensitivity * engine.input.mouse_delta.x
                )
            );
            camera_transform.rotation = zm.qmul(
                camera_transform.rotation, 
                zm.quatFromAxisAngle(
                    camera_transform.right_direction(), 
                    self.mouse_sensitivity * engine.input.mouse_delta.y
                )
            );
        }
    }
};

