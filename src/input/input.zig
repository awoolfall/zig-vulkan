const std = @import("std");
const eng = @import("self");
const kc = @import("keycode.zig");
pub const KeyCode = kc.KeyCode;

pub const KeyState = enum {
    RELEASED,
    DOWN,
    HELD,
    REPEAT,
    UP,
};

pub const InputState = struct {
    const Self = @This();
    const KEY_STATE_LEN = @typeInfo(kc.KeyCode).@"enum".fields.len;

    key_state: [KEY_STATE_LEN]KeyState,
    keys_to_update: [KEY_STATE_LEN]u8,
    keys_to_update_cursor: u8,

    char_events: [8]?[2:0]u8,
    
    cursor_position: [2]i32,
    mouse_delta: [2]f32,

    dropped_files: [][]u8,

    pub fn init() !Self {
        comptime std.debug.assert(KEY_STATE_LEN < 0xff);

        return Self {
            .key_state = [_]KeyState{KeyState.RELEASED} ** KEY_STATE_LEN,
            .keys_to_update = [_]u8{0} ** KEY_STATE_LEN,
            .keys_to_update_cursor = 0,
            .char_events = [_]?[2:0]u8{null} ** 8,
            .cursor_position = [2]i32{0, 0},
            .mouse_delta = [2]f32{0.0, 0.0},
            .dropped_files = try eng.get().general_allocator.alloc([]u8, 0),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.dropped_files) |path| {
            eng.get().general_allocator.free(path);
        }
        eng.get().general_allocator.free(self.dropped_files);
    }

    pub fn received_window_event_early(self: *Self, event: *const eng.window.WindowEvent) void {
        switch (event.*) {
            .KEY_DOWN => |k| {
                const e = @intFromEnum(k.keycode);
                self.key_state[e] = KeyState.DOWN;
                self.keys_to_update[self.keys_to_update_cursor] = e;
                self.keys_to_update_cursor += 1;
            },
            .KEY_REPEAT => |k| {
                const e = @intFromEnum(k.keycode);
                self.key_state[e] = KeyState.REPEAT;
                self.keys_to_update[self.keys_to_update_cursor] = e;
                self.keys_to_update_cursor += 1;
            },
            .KEY_UP => |k| {
                const e = @intFromEnum(k.keycode);
                self.key_state[e] = KeyState.UP;
                self.keys_to_update[self.keys_to_update_cursor] = e;
                self.keys_to_update_cursor += 1;
            },
            .CHAR => |c| {
                for (&self.char_events) |*e| {
                    if (e.* == null) {
                        e.* = c.utf8_char_seq;
                        break;
                    }
                }
            },
            .CURSOR_MOVED => |c| {
                self.cursor_position[0] = c.x_coord;
                self.cursor_position[1] = c.y_coord;
            },
            .RAW_MOUSE_MOVED => |m| {
                self.mouse_delta[0] += @floatFromInt(m.x_delta);
                self.mouse_delta[1] += @floatFromInt(m.y_delta);
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
            .DROPPED_FILES => |d| {
                const alloc = eng.get().general_allocator;
                for (self.dropped_files) |path| {
                    alloc.free(path);
                }
                self.dropped_files = alloc.realloc(self.dropped_files, d.paths.len) catch unreachable;
                for (d.paths, 0..) |path, idx| {
                    self.dropped_files[idx] = alloc.dupe(u8, path) catch unreachable;
                }
            },
            else => {},
        }
    }

    pub fn received_window_event_late(self: *Self, event: *const eng.window.WindowEvent) void {
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
                .REPEAT => { self.key_state[k] = KeyState.HELD; },
                .UP => { self.key_state[k] = KeyState.RELEASED; },
                else => {},
            }
        }
        self.keys_to_update_cursor = 0;

        self.mouse_delta = .{0.0, 0.0};
        @memset(&self.char_events, null);

        if (self.dropped_files.len != 0) {
            for (self.dropped_files) |path| {
                eng.get().general_allocator.free(path);
            }
            self.dropped_files = eng.get().general_allocator.realloc(self.dropped_files, 0) catch unreachable;
        }
    }

    pub fn get_key_state(self: *const Self, key: kc.KeyCode) KeyState {
        return self.key_state[@intFromEnum(key)];
    }

    pub inline fn get_key(self: *const Self, key: kc.KeyCode) bool {
        const state = self.get_key_state(key);
        return state == KeyState.DOWN or state == KeyState.HELD or state == KeyState.REPEAT;
    }

    pub inline fn get_key_down(self: *const Self, key: kc.KeyCode) bool {
        return self.get_key_state(key) == KeyState.DOWN;
    }

    pub inline fn get_key_down_repeat(self: *const Self, key: kc.KeyCode) bool {
        return self.get_key_state(key) == KeyState.DOWN or self.get_key_state(key) == KeyState.REPEAT;
    }

    pub inline fn get_key_up(self: *const Self, key: kc.KeyCode) bool {
        return self.get_key_state(key) == KeyState.UP;
    }
};
