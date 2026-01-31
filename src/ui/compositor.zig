const Self = @This();
const std = @import("std");
const Imui = @import("ui.zig");

const CompositorUiFunctionPtr = *const fn (*Imui, ?*anyopaque) bool;

const CompositorUiPanel = struct {
    ui_function_ptr: CompositorUiFunctionPtr,
    user_data_ptr: ?*anyopaque,
    key: u64,
};

alloc: std.mem.Allocator,
frame_compositor_panels: std.ArrayList(CompositorUiPanel),
last_frame_ordering_keys: std.ArrayList(u64),

pub fn deinit(self: *Self) void {
    self.frame_compositor_panels.deinit(self.alloc);
    self.last_frame_ordering_keys.deinit(self.alloc);
}

pub fn init(alloc: std.mem.Allocator) !Self {
    return .{
        .alloc = alloc,
        .frame_compositor_panels = .empty,
        .last_frame_ordering_keys = .empty,
    };
}

pub fn push_compositor_panel(self: *Self, function_ptr: CompositorUiFunctionPtr, user_data: ?*anyopaque, key: anytype) void {
    self.frame_compositor_panels.append(self.alloc, .{
        .ui_function_ptr = function_ptr,
        .data = user_data,
        .key = Imui.gen_key(key),
    }) catch |err| {
        std.log.err("Unable to append compositor panel: {}", .{err});
    };
}

/// order the panels in frame_compositor_panels so that the keys match the ordering found in last_frame_ordering_keys
fn order_compositor_panels(self: *Self) void {
    var key_index: usize = 0;
    for (self.last_frame_ordering_keys.items) |last_frame_key| {
        for (self.frame_compositor_panels.items, 0..) |frame_panel, panel_idx| {
            if (frame_panel.key == last_frame_key) {
                std.mem.swap(CompositorUiPanel, &self.frame_compositor_panels.items[key_index], &self.frame_compositor_panels.items[panel_idx]);
                key_index += 1;
                break;
            }
        }
    }
}

/// Renders all compositor panels to the Imui frame and resets internal arrays ready for the next frame
pub fn finish_frame(self: *Self, imui: *Imui) void {
    self.order_compositor_panels();
    self.last_frame_ordering_keys.clearRetainingCapacity();

    for (self.frame_compositor_panels.items) |compositor_panel| {
        const panel_desires_focus = compositor_panel.ui_function_ptr(imui, compositor_panel.user_data_ptr);

        // if the panel desires to be placed on top then prepend its key for next frame, otherwise append
        if (panel_desires_focus) {
            self.last_frame_ordering_keys.insert(self.alloc, 0, compositor_panel.key) catch |err| {
                std.log.warn("Unable to prepend compositor panel key to last frame ordering array: {}", .{err});
            };
        } else {
            self.last_frame_ordering_keys.append(self.alloc, compositor_panel.key) catch |err| {
                std.log.warn("Unable to append compositor panel key to last frame ordering array: {}", .{err});
            };
        }
    }

    self.frame_compositor_panels.clearRetainingCapacity();
}
