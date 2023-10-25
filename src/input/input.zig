const std = @import("std");
const kc = @import("keycode.zig");
const wb = @import("../window.zig");

pub const KeyState = enum {
    RELEASED,
    DOWN,
    HELD,
    UP,
};

pub const InputState = struct {
    const Self = @This();
    const KEY_STATE_LEN = @typeInfo(kc.KeyCode).Enum.fields.len;

    key_state: [KEY_STATE_LEN]KeyState,
    keys_to_update: [KEY_STATE_LEN]u8,
    keys_to_update_cursor: u8,
    
    cursor_position: struct {x: i32, y: i32},
    mouse_delta: struct {x: f32, y: f32},

    pub fn init() !Self {
        comptime std.debug.assert(KEY_STATE_LEN < 0xff);

        return Self {
            .key_state = [_]KeyState{KeyState.RELEASED} ** KEY_STATE_LEN,
            .keys_to_update = [_]u8{0} ** KEY_STATE_LEN,
            .keys_to_update_cursor = 0,
            .cursor_position = .{.x = 0, .y = 0},
            .mouse_delta = .{.x = 0.0, .y = 0.0},
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn received_window_event_early(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .KEY_DOWN => |k| {
                const e = @intFromEnum(k.keycode);
                self.key_state[e] = KeyState.DOWN;
                self.keys_to_update[self.keys_to_update_cursor] = e;
                self.keys_to_update_cursor += 1;
            },
            .KEY_UP => |k| {
                const e = @intFromEnum(k.keycode);
                self.key_state[e] = KeyState.UP;
                self.keys_to_update[self.keys_to_update_cursor] = e;
                self.keys_to_update_cursor += 1;
            },
            .CURSOR_MOVED => |c| {
                self.cursor_position.x = c.x_coord;
                self.cursor_position.y = c.y_coord;
            },
            .RAW_MOUSE_MOVED => |m| {
                self.mouse_delta.x += @floatFromInt(m.x_delta);
                self.mouse_delta.y += @floatFromInt(m.y_delta);
            },
            .LOST_FOCUS => {
                // Force all held or pressed keys to UP. Next frame this will transition to RELEASED
                self.keys_to_update_cursor = 0;
                for (self.key_state, 0..) |k, i| {
                    if (k == KeyState.DOWN or k == KeyState.HELD) {
                        self.key_state[i] = KeyState.UP;
                        self.keys_to_update[self.keys_to_update_cursor] = @intCast(i);
                        self.keys_to_update_cursor += 1;
                    }
                }
            },
            else => {},
        }
    }

    pub fn received_window_event_late(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .EVENTS_CLEARED => {
                self.on_update();
            },
            else => {},
        }
    }

    fn on_update(self: *Self) void {
        for (0..self.keys_to_update_cursor) |i| {
            const k = self.keys_to_update[i];
            switch (self.key_state[k]) {
                .DOWN => { self.key_state[k] = KeyState.HELD; },
                .UP => { self.key_state[k] = KeyState.RELEASED; },
                else => {},
            }
        }
        self.keys_to_update_cursor = 0;

        self.mouse_delta.x = 0.0;
        self.mouse_delta.y = 0.0;
    }

    pub fn get_key_state(self: *const Self, key: kc.KeyCode) KeyState {
        return self.key_state[@intFromEnum(key)];
    }

    pub inline fn get_key(self: *const Self, key: kc.KeyCode) bool {
        const state = self.get_key_state(key);
        return state == KeyState.DOWN or state == KeyState.HELD;
    }

    pub inline fn get_key_down(self: *const Self, key: kc.KeyCode) bool {
        return self.get_key_state(key) == KeyState.DOWN;
    }

    pub inline fn get_key_up(self: *const Self, key: kc.KeyCode) bool {
        return self.get_key_state(key) == KeyState.UP;
    }
};
