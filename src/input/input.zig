const std = @import("std");
const eng = @import("self");
pub const KeyCode = @import("keycode.zig").KeyCode;

pub const KeyState = enum {
    RELEASED,
    DOWN,
    HELD,
    REPEAT,
    UP,
};

pub const InputState = struct {
    const Self = @This();
    const KEY_STATE_LEN = @typeInfo(KeyCode).@"enum".fields.len;

    const FrameData = struct {
        key_state: [KEY_STATE_LEN]KeyState = [_]KeyState{KeyState.RELEASED} ** KEY_STATE_LEN,
        char_events: [8]?[2:0]u8 = [_]?[2:0]u8{null} ** 8,

        cursor_position: [2]i32 = [2]i32{ 0, 0 },
        mouse_delta: [2]f32 = [2]f32{ 0.0, 0.0 },

        dropped_files: [][]u8,
    };

    frame_data: [2]FrameData,
    current_frame_index: usize = 0,

    pub fn init() !Self {
        comptime std.debug.assert(KEY_STATE_LEN < 0xff);

        return Self{ .frame_data = .{
            .{ .dropped_files = try eng.get().general_allocator.alloc([]u8, 0) },
            .{ .dropped_files = try eng.get().general_allocator.alloc([]u8, 0) },
        } };
    }

    pub fn deinit(self: *Self) void {
        for (self.frame_data) |fd| {
            for (fd.dropped_files) |path| {
                eng.get().general_allocator.free(path);
            }
            eng.get().general_allocator.free(fd.dropped_files);
        }
    }

    inline fn get_current_frame_data_const(self: *const Self) *const FrameData {
        return &self.frame_data[self.current_frame_index];
    }

    inline fn get_next_frame_data_const(self: *const Self) *const FrameData {
        return &self.frame_data[(self.current_frame_index + 1) % 2];
    }

    inline fn get_current_frame_data(self: *Self) *FrameData {
        return &self.frame_data[self.current_frame_index];
    }

    inline fn get_next_frame_data(self: *Self) *FrameData {
        return &self.frame_data[(self.current_frame_index + 1) % 2];
    }

    pub fn received_window_event(self: *Self, event: *const eng.os.WindowEvent) void {
        const next_frame_data = self.get_next_frame_data();

        switch (event.*) {
            .KEY_DOWN => |k| {
                const e = @intFromEnum(k.keycode);
                next_frame_data.key_state[e] = KeyState.DOWN;
            },
            .KEY_REPEAT => |k| {
                const e = @intFromEnum(k.keycode);
                next_frame_data.key_state[e] = KeyState.REPEAT;
            },
            .KEY_UP => |k| {
                const e = @intFromEnum(k.keycode);
                next_frame_data.key_state[e] = KeyState.UP;
            },
            .CHAR => |c| {
                for (&next_frame_data.char_events) |*e| {
                    if (e.* == null) {
                        e.* = c.utf8_char_seq;
                        break;
                    }
                }
            },
            .CURSOR_MOVED => |c| {
                next_frame_data.cursor_position[0] = c.x_coord;
                next_frame_data.cursor_position[1] = c.y_coord;
            },
            .RAW_MOUSE_MOVED => |m| {
                next_frame_data.mouse_delta[0] += @floatFromInt(m.x_delta);
                next_frame_data.mouse_delta[1] += @floatFromInt(m.y_delta);
            },
            .LOST_FOCUS => {
                // Force all held or pressed keys to UP. Next frame this will transition to RELEASED
                for (&next_frame_data.key_state) |*ks| {
                    switch (ks.*) {
                        .DOWN, .HELD => ks.* = KeyState.UP,
                        else => {},
                    }
                }
            },
            .DROPPED_FILES => |d| {
                const alloc = eng.get().general_allocator;
                for (next_frame_data.dropped_files) |path| {
                    alloc.free(path);
                }
                next_frame_data.dropped_files = alloc.realloc(next_frame_data.dropped_files, d.paths.len) catch unreachable;
                for (d.paths, 0..) |path, idx| {
                    next_frame_data.dropped_files[idx] = alloc.dupe(u8, path) catch unreachable;
                }
            },
            else => {},
        }
    }

    pub fn start_new_frame(self: *Self) void {
        self.current_frame_index = (self.current_frame_index + 1) % 2;

        const current_frame_data = self.get_current_frame_data_const();
        const next_frame_data = self.get_next_frame_data();

        next_frame_data.key_state = current_frame_data.key_state;

        for (&next_frame_data.key_state) |*ks| {
            switch (ks.*) {
                .DOWN => ks.* = KeyState.HELD,
                .REPEAT => ks.* = KeyState.HELD,
                .UP => ks.* = KeyState.RELEASED,
                else => {},
            }
        }

        next_frame_data.mouse_delta = .{ 0.0, 0.0 };
        @memset(&next_frame_data.char_events, null);

        if (next_frame_data.dropped_files.len != 0) {
            for (next_frame_data.dropped_files) |path| {
                eng.get().general_allocator.free(path);
            }
            next_frame_data.dropped_files = eng.get().general_allocator.realloc(next_frame_data.dropped_files, 0) catch unreachable;
        }
    }

    pub fn get_key_state(self: *const Self, key: KeyCode) KeyState {
        return self.get_current_frame_data_const().key_state[@intFromEnum(key)];
    }

    pub inline fn get_key(self: *const Self, key: KeyCode) bool {
        const state = self.get_key_state(key);
        return state == KeyState.DOWN or state == KeyState.HELD or state == KeyState.REPEAT;
    }

    pub inline fn get_key_down(self: *const Self, key: KeyCode) bool {
        return self.get_key_state(key) == KeyState.DOWN;
    }

    pub inline fn get_key_down_repeat(self: *const Self, key: KeyCode) bool {
        return self.get_key_state(key) == KeyState.DOWN or self.get_key_state(key) == KeyState.REPEAT;
    }

    pub inline fn get_key_up(self: *const Self, key: KeyCode) bool {
        return self.get_key_state(key) == KeyState.UP;
    }

    pub fn get_char_events(self: *const Self) []const ?[2:0]u8 {
        return &self.get_current_frame_data_const().char_events;
    }

    pub fn get_cursor_position(self: *const Self) [2]i32 {
        return self.get_current_frame_data_const().cursor_position;
    }

    pub fn get_mouse_delta(self: *const Self) [2]f32 {
        return self.get_current_frame_data_const().mouse_delta;
    }

    pub fn get_dropped_files(self: *const Self) []const []const u8 {
        return self.get_current_frame_data_const().dropped_files;
    }
};
