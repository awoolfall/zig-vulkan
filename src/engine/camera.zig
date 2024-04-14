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

    max_orbit_distance: f32,
    min_orbit_distance: f32,
    orbit_distance: f32,

    view_matrix: zm.Mat = zm.identity(),

    camera_type: enum {
        FLY, ORBIT,
    } = .ORBIT,

    pub fn generate_perspective_matrix(self: *Self, aspect_ratio: f32) zm.Mat {
        return zm.perspectiveFovLh(self.field_of_view_y, aspect_ratio, self.near_field, self.far_field);
    }

    pub fn right_direction(self: *Self) zm.F32x4 {
        return zm.rotate(zm.inverse(zm.quatFromMat(self.view_matrix)), zm.f32x4(1.0, 0.0, 0.0, 0.0));
    }

    pub fn forward_direction(self: *const Self) zm.F32x4 {
        return zm.rotate(zm.inverse(zm.quatFromMat(self.view_matrix)), zm.f32x4(0.0, 0.0, 1.0, 0.0));
    }

    pub fn fly_camera_update(
        self: *Self, 
        engine: *app.Engine
    ) void {
        { // Camera Movement
            const move_amount = self.move_speed * engine.time.delta_time_f32();
            const cam_x = 
                float_from_bool(engine.input.get_key(kc.KeyCode.ArrowLeft)) * -move_amount + 
                float_from_bool(engine.input.get_key(kc.KeyCode.ArrowRight)) * move_amount;
            const cam_z = 
                float_from_bool(engine.input.get_key(kc.KeyCode.ArrowDown)) * -move_amount + 
                float_from_bool(engine.input.get_key(kc.KeyCode.ArrowUp)) * move_amount;

            self.view_matrix = zm.mul(self.view_matrix, zm.translation(-cam_x, 0.0, -cam_z));
        }
        
        if (engine.input.get_key_down(kc.KeyCode.MouseRight)) {
            engine.window.show_cursor(false);
            engine.window.confine_cursor_to_current_pos();
        }
        if (engine.input.get_key_up(kc.KeyCode.MouseRight)) {
            engine.window.show_cursor(true);
            engine.window.free_confined_cursor();
        }

        // Camera rotation
        if (engine.input.get_key(kc.KeyCode.MouseRight)) {
            self.view_matrix = zm.mul(
                self.view_matrix, 
                zm.matFromAxisAngle(
                    zm.rotate(zm.quatFromMat(self.view_matrix), zm.f32x4(0.0, -1.0, 0.0, 0.0)), 
                    self.mouse_sensitivity * engine.input.mouse_delta.x
                )
            );
            self.view_matrix = zm.mul(
                self.view_matrix, 
                zm.matFromAxisAngle(
                    zm.f32x4(-1.0, 0.0, 0.0, 0.0), 
                    self.mouse_sensitivity * engine.input.mouse_delta.y
                )
            );
        }
    }

    pub fn orbit_camera_update(
        self: *Self, 
        orbit_target: zm.F32x4, 
        engine: *app.Engine
    ) void {
        if (engine.input.get_key_down(kc.KeyCode.MouseRight)) {
            engine.window.show_cursor(false);
            engine.window.confine_cursor_to_current_pos();
        }
        if (engine.input.get_key_up(kc.KeyCode.MouseRight)) {
            engine.window.show_cursor(true);
            engine.window.free_confined_cursor();
        }

        // camera rotation
        if (engine.input.get_key(kc.KeyCode.MouseRight)) {
            self.view_matrix = zm.mul(
                zm.matFromAxisAngle(
                    zm.f32x4(0.0, -1.0, 0.0, 0.0), 
                    self.mouse_sensitivity * engine.input.mouse_delta.x
                ),
                self.view_matrix,
            );
            self.view_matrix = zm.mul(
                self.view_matrix, 
                zm.matFromAxisAngle(
                    zm.f32x4(-1.0, 0.0, 0.0, 0.0), 
                    self.mouse_sensitivity * engine.input.mouse_delta.y
                )
            );
        }

        // translate orbit distance by input
        const orbit_distance_change = float_from_bool(engine.input.get_key(kc.KeyCode.ArrowDown)) 
            - float_from_bool(engine.input.get_key(kc.KeyCode.ArrowUp));
        self.orbit_distance = self.orbit_distance + (orbit_distance_change * engine.time.delta_time_f32());
        self.orbit_distance = @max(@min(self.orbit_distance, self.max_orbit_distance), self.min_orbit_distance);

        // Reset view matrix translation then set it to be orbit_distance from target in camera dir
        self.view_matrix[3] = zm.f32x4(0.0, 0.0, 0.0, 1.0);
        self.view_matrix = zm.mul(self.view_matrix, zm.translationV(zm.rotate(zm.quatFromMat(self.view_matrix), -orbit_target)));
        self.view_matrix = zm.mul(self.view_matrix, zm.translation(0.0, 0.0, self.orbit_distance));
    }

    pub fn update(
        self: *Self, 
        camera_transform: *tf.Transform, 
        orbit_target: zm.F32x4,
        engine: *app.Engine
    ) void {
        _ = camera_transform;
        if (engine.input.get_key_down(kc.KeyCode.P)) {
            if (self.camera_type == .ORBIT) {
                self.camera_type = .FLY;
            } else {
                self.camera_type = .ORBIT;
            }
        }
        switch (self.camera_type) {
            .FLY => self.fly_camera_update(engine),
            .ORBIT => self.orbit_camera_update(orbit_target, engine),
        }
    }
};

