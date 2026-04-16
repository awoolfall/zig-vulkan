const std = @import("std");
const eng = @import("self");
const Transform = eng.Transform;
const zm = @import("zmath");
const kc = @import("../input/keycode.zig");

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

    damping_movement: [2]f32 = [_]f32{ 0.0, 0.0 },
    damping_amount: f32 = 1.0 / 0.1,

    local_transform: Transform = .{ .position = zm.f32x4(0.0, 0.0, -1.0, 0.0) },
    transform: Transform = .{},

    pub fn generate_perspective_matrix(self: *const Self, aspect_ratio: f32) zm.Mat {
        var perspective = zm.perspectiveFovRh(self.field_of_view_y, aspect_ratio, self.far_field, self.near_field);

        switch (@import("build_options").graphics_backend) {
            // flip Y to match Vulkan coordinate system of [+Y down, -Z forward, +X right]
            .Vulkan => { perspective[1][1] *= -1.0; },
            else => {},
        }

        return perspective;
    }

    pub fn fly_camera_update(
        self: *Self, 
        window: *eng.window.Window,
        input: *const eng.input.InputState,
        time: *const eng.time.TimeState,
    ) void {
        self.local_transform = self.transform;

        { // Camera Movement
            var move_amount = self.move_speed * time.delta_time_unscaled_f32();
            if (input.get_key(kc.KeyCode.Shift)) {
                move_amount *= 0.01;
            }
            const cam_x = 
                float_from_bool(input.get_key(kc.KeyCode.A)) * -move_amount + 
                float_from_bool(input.get_key(kc.KeyCode.D)) * move_amount;
            const cam_z = 
                float_from_bool(input.get_key(kc.KeyCode.S)) * -move_amount + 
                float_from_bool(input.get_key(kc.KeyCode.W)) * move_amount;

            self.local_transform.position += self.local_transform.forward_direction() * zm.f32x4s(cam_z);
            self.local_transform.position += self.local_transform.right_direction() * zm.f32x4s(cam_x);
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
            self.local_transform.rotation = zm.qmul(
                self.local_transform.rotation,
                zm.quatFromAxisAngle(
                    zm.f32x4(0.0, 1.0, 0.0, 0.0),
                    self.mouse_sensitivity * -input.mouse_delta[0]
                )
            );
            self.local_transform.rotation = zm.qmul(
                self.local_transform.rotation,
                zm.quatFromAxisAngle(
                    self.local_transform.right_direction(),
                    self.mouse_sensitivity * -input.mouse_delta[1]
                )
            );
        }

        // update transform
        self.transform = self.local_transform;
    }

    pub fn orbit_camera_update(
        self: *Self, 
        orbit_target: zm.F32x4, 
        window: *eng.window.Window,
        input: *const eng.input.InputState,
        time: *const eng.time.TimeState,
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
        self.orbit_distance = self.orbit_distance + self.orbit_distance * (orbit_distance_change * 0.5 * time.delta_time_unscaled_f32());
        self.orbit_distance = @max(@min(self.orbit_distance, self.max_orbit_distance), self.min_orbit_distance);

        // camera rotation
        if (input.get_key(kc.KeyCode.MouseRight)) {
            self.damping_movement[0] = -input.mouse_delta[0] * self.mouse_sensitivity;
            self.damping_movement[1] = input.mouse_delta[1] * self.mouse_sensitivity;
        } else {
            self.damping_movement[0] = std.math.lerp(self.damping_movement[0], 0.0, self.damping_amount * time.delta_time_unscaled_f32());
            self.damping_movement[1] = std.math.lerp(self.damping_movement[1], 0.0, self.damping_amount * time.delta_time_unscaled_f32());
        }

        var target_offset = self.local_transform.position;
        if (zm.length3(target_offset)[0] < 0.001) {
            target_offset = zm.f32x4(0.0, 0.0, 1.0, 0.0);
        }

        if (!std.math.approxEqAbs(f32, zm.length3(target_offset)[0], self.orbit_distance, 0.05)) {
            self.local_transform.position = zm.normalize3(target_offset) * zm.f32x4s(self.orbit_distance);
            self.local_transform.position[3] = 0.0;
        }

        target_offset = self.local_transform.position;
        target_offset = zm.rotate(zm.quatFromAxisAngle(
                zm.cross3(target_offset, zm.f32x4(0.0, 1.0, 0.0, 0.0)),
                self.damping_movement[1]
            ), target_offset);
        target_offset = zm.rotate(zm.quatFromAxisAngle(
                zm.f32x4(0.0, 1.0, 0.0, 0.0),
                self.damping_movement[0]
            ), target_offset);

        self.local_transform.position = target_offset;
        self.local_transform.position[3] = 0.0;

        self.local_transform.rotation = zm.quatFromMat(zm.inverse(zm.lookAtRh(self.local_transform.position, zm.f32x4s(0.0), zm.f32x4(0.0, 1.0, 0.0, 0.0))));

        // update transform
        self.transform = self.local_transform;
        self.transform.position += orbit_target;
    }

    pub fn horizontal_to_vertical_fov(horizontal_fov: f32, aspect_ratio: f32) f32 {
        return 2.0 * std.math.atan(std.math.tan(horizontal_fov / 2.0) * (1.0 / aspect_ratio));
    }
};
