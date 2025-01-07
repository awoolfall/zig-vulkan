const std = @import("std");
const tf = @import("transform.zig");
const zm = @import("zmath");
const kc = @import("../input/keycode.zig");
const engine = @import("../engine.zig");
const Window = engine.platform.Window;
const _input = engine.input;
const _time = engine.time;

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

    damping_movement: [2]f32 = [_]f32{ 0.0, 0.0 },
    damping_amount: f32 = 1.0 / 0.1,

    camera_type: enum {
        FLY, ORBIT,
    } = .ORBIT,

    pub fn generate_perspective_matrix(self: *Self, aspect_ratio: f32) zm.Mat {
        return zm.perspectiveFovLh(self.field_of_view_y, aspect_ratio, self.far_field, self.near_field);
    }

    pub fn right_direction(self: *Self) zm.F32x4 {
        return zm.rotate(zm.inverse(zm.quatFromMat(self.view_matrix)), zm.f32x4(1.0, 0.0, 0.0, 0.0));
    }

    pub fn up_direction(self: *const Self) zm.F32x4 {
        return zm.rotate(zm.inverse(zm.quatFromMat(self.view_matrix)), zm.f32x4(0.0, 1.0, 0.0, 0.0));
    }
    
    pub fn forward_direction(self: *const Self) zm.F32x4 {
        return zm.rotate(zm.inverse(zm.quatFromMat(self.view_matrix)), zm.f32x4(0.0, 0.0, 1.0, 0.0));
    }

    pub fn fly_camera_update(
        self: *Self, 
        window: *Window,
        input: *const _input.InputState,
        time: *const _time.TimeState,
    ) void {
        { // Camera Movement
            const move_amount = self.move_speed * time.delta_time_f32();
            const cam_x = 
                float_from_bool(input.get_key(kc.KeyCode.ArrowLeft)) * -move_amount + 
                float_from_bool(input.get_key(kc.KeyCode.ArrowRight)) * move_amount;
            const cam_z = 
                float_from_bool(input.get_key(kc.KeyCode.ArrowDown)) * -move_amount + 
                float_from_bool(input.get_key(kc.KeyCode.ArrowUp)) * move_amount;

            self.view_matrix = zm.mul(self.view_matrix, zm.translation(-cam_x, 0.0, -cam_z));
        }
        
        if (input.get_key_down(kc.KeyCode.MouseRight)) {
            window.show_cursor(false);
            window.confine_cursor_to_current_pos();
        }
        if (input.get_key_up(kc.KeyCode.MouseRight)) {
            window.show_cursor(true);
            window.free_confined_cursor();
        }

        // Camera rotation
        if (input.get_key(kc.KeyCode.MouseRight)) {
            self.view_matrix = zm.mul(
                self.view_matrix, 
                zm.matFromAxisAngle(
                    zm.rotate(zm.quatFromMat(self.view_matrix), zm.f32x4(0.0, -1.0, 0.0, 0.0)), 
                    self.mouse_sensitivity * input.mouse_delta[0]
                )
            );
            self.view_matrix = zm.mul(
                self.view_matrix, 
                zm.matFromAxisAngle(
                    zm.f32x4(-1.0, 0.0, 0.0, 0.0), 
                    self.mouse_sensitivity * input.mouse_delta[1]
                )
            );
        }
    }

    pub fn orbit_camera_update(
        self: *Self, 
        camera_transform: *tf.Transform, 
        orbit_target: zm.F32x4, 
        window: *Window,
        input: *const _input.InputState,
        time: *const _time.TimeState,
    ) void {
        if (input.get_key_down(kc.KeyCode.MouseRight)) {
            window.show_cursor(false);
            window.confine_cursor_to_current_pos();
        }
        if (input.get_key_up(kc.KeyCode.MouseRight)) {
            window.show_cursor(true);
            window.free_confined_cursor();
        }

        // translate orbit distance by input
        const orbit_distance_change = float_from_bool(input.get_key(kc.KeyCode.ArrowDown)) 
            - float_from_bool(input.get_key(kc.KeyCode.ArrowUp));
        self.orbit_distance = self.orbit_distance + self.orbit_distance * (orbit_distance_change * 0.5 * time.delta_time_f32());
        self.orbit_distance = @max(@min(self.orbit_distance, self.max_orbit_distance), self.min_orbit_distance);

        // camera rotation
        if (input.get_key(kc.KeyCode.MouseRight)) {
            self.damping_movement[0] = input.mouse_delta[0] * self.mouse_sensitivity;
            self.damping_movement[1] = input.mouse_delta[1] * self.mouse_sensitivity;
        } else {
            self.damping_movement[0] = std.math.lerp(self.damping_movement[0], 0.0, self.damping_amount * time.delta_time_f32());
            self.damping_movement[1] = std.math.lerp(self.damping_movement[1], 0.0, self.damping_amount * time.delta_time_f32());
        }

        var target_offset = camera_transform.position - orbit_target;
        if (zm.length3(target_offset)[0] < 0.001) {
            target_offset = zm.f32x4(0.0, 0.0, 1.0, 0.0);
        }

        if (!std.math.approxEqAbs(f32, zm.length3(target_offset)[0], self.orbit_distance, 0.05)) {
            camera_transform.position = orbit_target + zm.normalize3(target_offset) * zm.f32x4s(self.orbit_distance);
            camera_transform.position[3] = 0.0;
        }

        target_offset = camera_transform.position - orbit_target;
        target_offset = zm.rotate(zm.quatFromAxisAngle(
                zm.cross3(target_offset, zm.f32x4(0.0, 1.0, 0.0, 0.0)),
                self.damping_movement[1]
            ), target_offset);
        target_offset = zm.rotate(zm.quatFromAxisAngle(
                zm.f32x4(0.0, 1.0, 0.0, 0.0),
                self.damping_movement[0]
            ), target_offset);

        camera_transform.position = orbit_target + target_offset;
        camera_transform.position[3] = 0.0;

        camera_transform.rotation = zm.quatFromMat(zm.inverse(zm.lookAtLh(camera_transform.position, orbit_target, zm.f32x4(0.0, 1.0, 0.0, 0.0))));

        self.view_matrix = camera_transform.generate_view_matrix();
    }

    pub fn update(
        self: *Self, 
        camera_transform: *tf.Transform, 
        orbit_target: zm.F32x4,
        window: *Window,
        input: *const _input.InputState,
        time: *const _time.TimeState,
    ) void {
        if (input.get_key_down(kc.KeyCode.P)) {
            if (self.camera_type == .ORBIT) {
                self.camera_type = .FLY;
            } else {
                self.camera_type = .ORBIT;
            }
        }
        switch (self.camera_type) {
            .FLY => self.fly_camera_update(window, input, time),
            .ORBIT => self.orbit_camera_update(camera_transform, orbit_target, window, input, time),
        }
    }
};

