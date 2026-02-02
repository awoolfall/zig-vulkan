const std = @import("std");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const engine = @import("self");
const _gfx = engine.gfx;
const tm = engine.time;
const in = engine.input;
const es = engine.easings;
const platform = engine.platform;
const path = engine.path;

pub const font = @import("render/font.zig");
pub const qr = @import("render/quad_renderer.zig");
const QuadRenderer = qr.QuadRenderer;
const RectPixels = engine.Rect;

pub const Palette = @import("palette.zig");
pub const widgets = @import("widgets.zig");
const ImuiCompositor = @import("compositor.zig");

const Self = @This();

pub const FontEnum = enum(usize) {
    GeistMono = 0,
    Geist,
    Count,

    fn font_paths(font_enum: FontEnum, alloc: std.mem.Allocator) !struct {json: path.Path, png: path.Path} {
        switch (font_enum) {
            FontEnum.GeistMono => return .{
                .json = try path.Path.init(alloc, .{.ExeRelative = "../../res/GeistMono-Regular.json"}),
                .png = try path.Path.init(alloc, .{.ExeRelative = "../../res/GeistMono-Regular.png"}),
            },
            FontEnum.Geist => return .{
                .json = try path.Path.init(alloc, .{.ExeRelative = "../../res/Geist-Regular.json"}),
                .png = try path.Path.init(alloc, .{.ExeRelative = "../../res/Geist-Regular.png"}),
            },
            FontEnum.Count => unreachable,
        }
    }
};

pub fn position_pixels_to_screen_space(x: f32, y: f32, max_width: f32, max_height: f32) [2]f32 {
    const y_multiplier = switch (@import("build_options").graphics_backend) {
        .Direct3D11 => -1.0,
        else => 1.0,
    };
    return [2]f32{
        ((x / max_width) * 2.0) - 1.0,
        (((y / max_height) * 2.0) - 1.0) * y_multiplier,
    };
}

pub const SizeKind = enum {
    None,
    Pixels,
    TextContent,
    ParentPercentage,
    ChildrenSize,
};

pub const SemanticSize = struct {
    kind: SizeKind,
    value: f32,
    shrinkable: bool = false,
    minimum_pixel_size: f32 = 0.0,
};

pub const Axis = enum(usize) {
    X = 0,
    Y = 1,
};
pub const AxisCount = std.meta.fields(Axis).len;

pub const Key = u64;

pub fn gen_key(key_input: anytype) Key {
    var hasher = std.hash.XxHash64.init(0);
    const len = std.meta.fields(@TypeOf(key_input)).len;
    inline for (0..len) |i| {
        hasher.update(&std.mem.toBytes(key_input[i]));
    }
    return hasher.final();
}

pub const WidgetFlags = packed struct(u32) {
    render: bool = true,
    render_quad: bool = true,
    hover_effect: bool = true,

    allows_overflow_x: bool = false,
    allows_overflow_y: bool = false,

    floating_x: bool = false,
    floating_y: bool = false,

    clickable: bool = false,

    is_form_layout_item: bool = false,

    __unused: u23 = 0,

    pub inline fn get_allow_overflow_flag(flags: *const WidgetFlags, axis: Axis) bool {
        switch (axis) {
            .X => { return flags.allows_overflow_x; },
            .Y => { return flags.allows_overflow_y; },
        }
    }

    pub inline fn get_floating_flag(flags: *const WidgetFlags, axis: Axis) bool {
        switch (axis) {
            .X => { return flags.floating_x; },
            .Y => { return flags.floating_y; },
        }
    }
};

pub const VerticalAlignment = enum {
    Top,
    Middle,
    Bottom,
};

pub const HorizontalAlign = enum {
    Left,
    Middle,
    Right,
};

inline fn rect_size(rect: RectPixels, axis: usize) f32 {
    return switch (axis) {
        0 => rect.width(),
        1 => rect.height(),
        else => unreachable,
    };
}

pub const Widget = struct {
    semantic_size: [AxisCount]SemanticSize,

    key: Key,

    // sibling data
    next_sibling: ?WidgetId = null,
    prev_sibling: ?WidgetId = null,
    parent: ?WidgetId = null,

    // parent data
    layout_axis: ?Axis = null,
    first_child: ?WidgetId = null,
    last_child: ?WidgetId = null,
    num_children: usize = 0,
    children_gap: f32 = 0.0,

    priority: u32 = 0,

    form_labels_width: f32 = 0.0,

    computed_size: [2]f32 = .{ 0.0, 0.0 },
    computed_relative_position: [2]f32 = .{ 0.0, 0.0 },
    computed_pixel_offset: [2]f32 = .{ 0.0, 0.0 },

    active_t: f32 = 0.0,
    active_t_timescale: f32 = 0.1,
    hot_t: f32 = 0.0,
    hot_t_timescale: f32 = 0.1,

    flags: WidgetFlags = .{},

    text_content: ?struct {
        font: FontEnum = FontEnum.GeistMono,
        text: []const u8,
        size: f32 = 15.0,
        colour: ?zm.F32x4 = null,
    } = null,

    background_colour: ?zm.F32x4 = null,
    border_colour: ?zm.F32x4 = null,
    border_width_px: RectPixels = .{},
    corner_radii_px: qr.CornerRadiiPx = .{},
    texture: ?struct {
        texture_view: _gfx.ImageView.Ref,
        sampler: _gfx.Sampler.Ref,
    } = null,

    margin_px: RectPixels = .{},
    padding_px: RectPixels = .{},

    // anchor determines the position within the potential space allowed by the layout
    anchor: [2]f32 = .{0.0, 0.0},
    // pivot determines the coordinate on the widget's box that sticks to the anchor
    pivot: [2]f32 = .{0.0, 0.0},

    widget_data: ?*anyopaque = null,

    pub fn rect(self: *const Widget) RectPixels {
        const position: [2]f32 = .{
            self.computed_relative_position[0] + self.computed_pixel_offset[0],
            self.computed_relative_position[1] + self.computed_pixel_offset[1],
        };
        return RectPixels {
            .left = position[0],
            .top = position[1],
            .right = position[0] + self.border_width_px.left + self.padding_px.left + self.computed_size[0] + self.padding_px.right + self.border_width_px.right,
            .bottom = position[1] + self.border_width_px.top + self.padding_px.top + self.computed_size[1] + self.padding_px.bottom + self.border_width_px.bottom,
        };
    }

    pub fn content_rect(self: *const Widget) RectPixels {
        const r = self.rect();
        return RectPixels {
            .left = r.left + self.border_width_px.left + self.padding_px.left,
            .right = r.right - self.border_width_px.right - self.padding_px.right,
            .top = r.top + self.border_width_px.top + self.padding_px.top,
            .bottom = r.bottom - self.border_width_px.bottom - self.padding_px.bottom,
        };
    }

    pub fn outer_rect(self: *const Widget) RectPixels {
        const r = self.rect();
        return RectPixels {
            .left = r.left - self.margin_px.left,
            .right = r.right + self.margin_px.right,
            .top = r.top - self.margin_px.top,
            .bottom = r.bottom + self.margin_px.bottom,
        };
    }

    pub fn size(self: *const Widget) [2]f32 {
        const r = self.rect();
        return .{ r.width(), r.height() };
    }

    pub fn content_size(self: *const Widget) [2]f32 {
        const r = self.content_rect();
        return .{ r.width(), r.height() };
    }

    pub fn outer_size(self: *const Widget) [2]f32 {
        const r = self.outer_rect();
        return .{ r.width(), r.height() };
    }
};

pub fn WidgetSignal(comptime T: type) type {
    return struct {
        clicked: bool = false,
        hover: bool = false,
        dragged: bool = false,
        data_changed: bool = false,
        init: bool = false,
        id: T,
    };
}

pub const DontCareKey: Key = 0;

pub const WidgetLocation = enum(u1) {
    Standard,
    Priority,
};

pub const WidgetId = struct {
    pointer: *Widget,

    pub fn get(self: *const WidgetId) *Widget {
        return self.pointer;
    }

    pub fn get_last_frame(self: *const WidgetId, imui: *const Self) ?*const Widget {
        return imui.get_widget_from_last_frame(self.*);
    }

    pub fn get_widget_data(self: *const WidgetId, comptime WidgetDataType: type, imui: *Self) !struct { *WidgetDataType, WidgetDataState } {
        return imui.get_widget_data(WidgetDataType, self.*);
    }
};

const RootWidget = struct {
    widget: WidgetId,
    priority: u32,
};

alloc: std.mem.Allocator,

// hot and active items for the current frame
hot_item: ?Key = null,
active_item: ?Key = null,

// hot and active items for the next frame
// these are modified during widget creation and set to the current values at render time
next_hot_item: ?WidgetId = null,
next_active_item: ?WidgetId = null,

// focus item
focus_item: ?Key = null,
should_clear_focus_next_frame: bool = false,

primary_interact_key: in.KeyCode = in.KeyCode.MouseLeft,

quad_renderer: QuadRenderer,
fonts: [@intFromEnum(FontEnum.Count)]font.Font,

parent_stack: std.ArrayList(WidgetId),
palette_stack: std.ArrayList(Palette),

root_widgets: std.ArrayList(RootWidget),

last_frame_index: u8 = 0,
frame_widgets_maps: [2]std.AutoHashMap(Key, WidgetId),
arenas: [2]std.heap.ArenaAllocator,

deinit_functions: std.ArrayList(*const fn (alloc: std.mem.Allocator) void) = .empty,

compositor: ImuiCompositor,

pub fn deinit(self: *Self) void {
    self.compositor.deinit();

    for (self.deinit_functions.items) |func| {
        func(self.alloc);
    }
    self.deinit_functions.deinit(self.alloc);

    for (&self.fonts) |*f| {
        f.deinit();
    }
    self.quad_renderer.deinit();

    self.palette_stack.deinit(self.alloc);
    self.parent_stack.deinit(self.alloc);
    self.root_widgets.deinit(self.alloc);

    for (&self.frame_widgets_maps) |*frame_widget_map| {
        frame_widget_map.deinit();
    }

    for (self.arenas) |a| {
        a.deinit();
    }
}

pub fn init(alloc: std.mem.Allocator) !Self {
    // Initialize fonts
    var fonts: [@intFromEnum(FontEnum.Count)]font.Font = [_]font.Font{undefined} ** @intFromEnum(FontEnum.Count);
    for (0..@intFromEnum(FontEnum.Count)) |idx| {
        const font_enum = @as(FontEnum, @enumFromInt(idx));

        const font_paths = try font_enum.font_paths(alloc);
        defer { font_paths.json.deinit(); font_paths.png.deinit(); }

        const font_obj = try font.Font.init(
            font_paths.json,
            font_paths.png,
        );
        fonts[idx] = font_obj;
    }

    var compositor = try ImuiCompositor.init(alloc);
    errdefer compositor.deinit();

    var self = Self {
        .alloc = alloc,
        .parent_stack = .empty,
        .palette_stack = .empty,
        .root_widgets = .empty,
        .frame_widgets_maps = .{
            .init(alloc),
            .init(alloc),
        },
        .arenas = [_]std.heap.ArenaAllocator{
            std.heap.ArenaAllocator.init(alloc),
            std.heap.ArenaAllocator.init(alloc),
        },
        .quad_renderer = try QuadRenderer.init(alloc),
        .fonts = fonts,
        .compositor = compositor,
    };

    _ = self.add_fullscreen_root_widget(0);
    return self;
}

pub fn get_font(self: *Self, font_enum: FontEnum) *font.Font {
    return &self.fonts[@intFromEnum(font_enum)];
}

fn arena(self: *Self) *std.heap.ArenaAllocator {
    return &self.arenas[(@as(usize, @intCast(self.last_frame_index)) + 1) % 2];
}

fn this_frame_widgets_map(self: *Self) *std.AutoHashMap(Key, WidgetId) {
    return &self.frame_widgets_maps[(@as(usize, @intCast(self.last_frame_index)) + 1) % 2];
}

fn last_frame_widgets_map(self: *Self) *std.AutoHashMap(Key, WidgetId) {
    return &self.frame_widgets_maps[(@as(usize, @intCast(self.last_frame_index))) % 2];
}

pub fn widget_allocator(self: *const Self) std.mem.Allocator {
    return @constCast(self).arena().allocator();
}

pub fn palette(self: *const Self) Palette {
    return self.palette_stack.getLastOrNull() orelse Palette.default_palette;
}

fn add_heirarchy_links(self: *Self, parent_id: WidgetId, widget_id: WidgetId) !void {
    std.debug.assert(parent_id.pointer != widget_id.pointer);

    const parent = self.get_widget(parent_id) orelse return error.ParentDoesNotExist;
    const widget = self.get_widget(widget_id) orelse return error.WidgetDoesNotExist;

    widget.parent = parent_id;

    if (parent.first_child == null) {
        parent.first_child = widget_id;
        parent.last_child = widget_id;
    } else {
        std.debug.assert(parent.last_child != null);
        const sibling_id = parent.last_child.?;
        const sibling = self.get_widget(sibling_id) orelse return error.SiblingDoesNotExist;
        sibling.next_sibling = widget_id;
        parent.last_child = widget_id;
        widget.prev_sibling = sibling_id;
    }

    parent.num_children += 1;
}

inline fn apply_padding(widget: *Widget, axis: usize) void {
    switch (axis) {
        0 => widget.computed.size[0] += widget.padding_px.left + widget.padding_px.right,
        1 => widget.computed.size[1] += widget.padding_px.top + widget.padding_px.bottom,
        else => {}
    }
}

inline fn apply_border_padding(widget: *Widget, axis: usize) void {
    switch (axis) {
        0 => widget.computed.size[0] += widget.border_width_px.left + widget.border_width_px.right,
        1 => widget.computed.size[1] += widget.border_width_px.top + widget.border_width_px.bottom,
        else => {}
    }
}

fn compute_standalone_widget_size(self: *Self, widget: *Widget) void {
    for (widget.semantic_size, 0..) |s, axis| {
        switch (s.kind) {
            .Pixels => {
                widget.computed_size[axis] = @max(s.value, s.minimum_pixel_size);
            },
            .TextContent => {
                const size = if (widget.text_content) |*text| blk: {
                    const text_bounds = self.get_font(text.font).text_bounds_2d_pixels(
                        text.text,
                        text.size
                    );
                    switch (axis) {
                        0 => break :blk text_bounds.width(),
                        1 => break :blk text_bounds.height() - self.get_font(text.font).font_metrics.descender,
                        else => {unreachable;}
                    }
                } else blk: {
                    std.log.warn("widget with size kind \"Text Content\" does not have any text content.", .{});
                    break :blk 0.0;
                };
                widget.computed_size[axis] = @max(size, s.minimum_pixel_size);
            },
            else => {},
        }
    }
}

pub fn add_widget(self: *Self, widget: Widget, priority: ?u32) WidgetId {
    const owned_widget = self.arena().allocator().create(Widget) catch unreachable;
    owned_widget.* = widget;

    // we need to own the text content so duplicate it using this frame's arena before adding the widget
    if (owned_widget.text_content) |*text| {
        text.text = self.arena().allocator().dupe(u8, text.text) catch unreachable;
    }

    const widget_id = WidgetId {
        .pointer = owned_widget,
    };

    var parent_priority: u32 = 0;
    if (self.parent_stack.getLastOrNull()) |parent_id| {
        self.add_heirarchy_links(parent_id, widget_id) catch unreachable;
        parent_priority = parent_id.get().priority;
    }

    owned_widget.priority = priority orelse parent_priority;

    if (priority != null) {
        self.root_widgets.append(self.alloc, .{ .widget = widget_id, .priority = owned_widget.priority, }) catch unreachable;
    }

    (if (owned_widget.key == DontCareKey) self.this_frame_widgets_map().put(owned_widget.key, widget_id)
    else self.this_frame_widgets_map().putNoClobber(owned_widget.key, widget_id))
    catch |err| {
        std.log.err("Failed to put widget in frame map: {}", .{err});
        unreachable;
    };

    return widget_id;
}

fn add_root_widget(self: *Self, widget: Widget, priority: ?u32) WidgetId {
    const owned_widget = self.arena().allocator().create(Widget) catch unreachable;
    owned_widget.* = widget;

    // we need to own the text content so duplicate it using this frame's arena before adding the widget
    if (owned_widget.text_content) |*text| {
        text.text = self.arena().allocator().dupe(u8, text.text) catch unreachable;
    }

    const widget_id = WidgetId {
        .pointer = owned_widget,
    };

    owned_widget.priority = priority orelse @intCast(self.root_widgets.items.len);

    self.this_frame_widgets_map().putNoClobber(owned_widget.key, widget_id) catch |err| {
        std.log.err("Failed to put widget in frame map: {}", .{err});
        unreachable;
    };

    self.root_widgets.append(self.alloc, .{ .widget = widget_id, .priority = owned_widget.priority, }) catch unreachable;
    self.parent_stack.append(self.alloc, widget_id) catch unreachable;

    return widget_id;
}

pub fn any_of_widgets_is_hot(self: *const Self, widget_keys: []const Key) bool {
    if (self.hot_item) |hi| {
        for (widget_keys) |k| {
            if (hi == k) {
                return true;
            }
        }
    }
    return false;
}

pub fn any_of_widgets_is_active(self: *const Self, widget_keys: []const Key) bool {
    if (self.active_item) |ai| {
        for (widget_keys) |k| {
            if (ai == k) {
                return true;
            }
        }
    }
    return false;
}

pub fn any_of_widgets_is_focus(self: *const Self, widget_keys: []const Key) bool {
    if (self.focus_item) |hi| {
        for (widget_keys) |k| {
            if (hi == k) {
                return true;
            }
        }
    }
    return false;
}

pub fn has_focus(self: *const Self) bool {
    //return self.focus_item != null;
    return self.hot_item != null or self.active_item != null or self.focus_item != null;
}

pub fn clear_focus_item(self: *Self) void {
    self.focus_item = null;
}

// TODO remove this function
pub fn get_widget(self: *Self, widget_id: WidgetId) ?*Widget {
    _ = self;
    return widget_id.get();
}

pub const WidgetDataState = enum {
    Init,
    Cont,
};

pub fn get_widget_data(self: *Self, comptime WidgetDataType: type, widget_id: WidgetId) !struct { *WidgetDataType, WidgetDataState } {
    const widget = self.get_widget(widget_id) orelse return error.UnableToGetWidget;

    var widget_data_state: WidgetDataState = .Cont;

    if (widget.widget_data == null) {
        const widget_data = try self.arena().allocator().create(WidgetDataType);
        widget.widget_data = widget_data;

        if (self.get_widget_from_last_frame(widget_id)) |lfw| {
            widget_data_state = .Cont;

            const lfw_data_ptr: *WidgetDataType = @alignCast(@ptrCast(lfw.widget_data orelse return error.LastFrameWidgetHadNullData));
            switch (@typeInfo(WidgetDataType)) {
                .@"struct", .@"enum", .@"union" => {
                    widget_data.* = try lfw_data_ptr.clone(self.arena().allocator());
                },
                else => {
                    widget_data.* = lfw_data_ptr.*;
                }
            }
        } else {
            widget_data_state = .Init;

            switch (@typeInfo(WidgetDataType)) {
                .@"struct", .@"enum", .@"union" => {
                    widget_data.* = try WidgetDataType.init(self.arena().allocator());
                },
                else => {
                    widget_data.* = std.mem.zeroes(WidgetDataType);
                }
            }
        }
    }

    return .{
        @alignCast(@ptrCast(widget.widget_data orelse return error.WidgetDoesNotHaveData)),
        widget_data_state,
    };
}

pub fn get_widget_from_last_frame(self: *Self, widget_id: WidgetId) ?*const Widget {
    const widget = self.get_widget(widget_id) orelse return null;
    if (self.last_frame_widgets_map().getPtr(widget.key)) |last_frame_widget_id| {
        return last_frame_widget_id.get();
    } else {
        return null;
    }
}


fn add_fullscreen_root_widget(self: *Self, priority: u32) WidgetId {
    const swapchain_size = engine.get().gfx.swapchain_size();
    const root_widget = Widget {
        .semantic_size = [_]SemanticSize{.{.kind = .None, .value = 0.0, }} ** 2,
        .key = gen_key(.{@src()}),
        .computed_size = .{ @floatFromInt(swapchain_size[0]), @floatFromInt(swapchain_size[1]) },
        .computed_relative_position = .{ 0.0, 0.0 },
        .flags = .{
            .render = false,
            .allows_overflow_x = false,
            .allows_overflow_y = false,
        },
    };
    return self.add_root_widget(root_widget, priority);
}

fn solve_upward_dependant_sizes(self: *Self, widget: *Widget) void {
    const parent = self.get_widget(widget.parent) orelse unreachable;
    for (widget.semantic_size, 0..) |s, axis| {
        switch (s.kind) {
            .ParentPercentage => {
                widget.computed.size[axis] = rect_size(parent.content_rect(), axis) * s.value;
                widget.computed.size[axis] = @max(widget.computed.size[axis], s.minimum_pixel_size);
            },
            else => {},
        }
    }
}

fn solve_downward_dependant_sizes(self: *Self, widget: *Widget) void {
    for (widget.semantic_size, 0..) |s, axis| {
        var total_size: f32 = -widget.children_gap;
        var top_size: f32 = 0.0;
        var child_id = widget.first_child;
        while (child_id != null) {
            const child = self.get_widget(child_id.?).?;

            // if child is floating then it does not contribute to the size of the parent
            if (child.flags.get_floating_flag(@enumFromInt(axis))) {
                child_id = child.next_sibling;
                continue;
            }

            top_size = @max(child.computed.total_size()[axis], top_size);
            total_size += child.computed.total_size()[axis] + widget.children_gap;
            child_id = child.next_sibling;
        }

        widget.computed.children_size[axis] = top_size;
        if (widget.layout_axis) |layout_axis| {
            if (@intFromEnum(layout_axis) == axis) {
                widget.computed.children_size[axis] = @max(total_size, 0.0);
            }
        }

        switch (s.kind) {
            .ChildrenSize => {
                widget.computed.size[axis] = widget.computed.children_size[axis];
                apply_padding(widget, axis);
                apply_border_padding(widget, axis);
                widget.computed.size[axis] = @max(widget.computed.size[axis], s.minimum_pixel_size);
            },
            else => {},
        }
    }
}

fn widget_potential_space(self: *Self, widget_id: WidgetId) [2]f32 {
    const widget = self.get_widget(widget_id) orelse unreachable;
    const parent = self.get_widget(widget.parent) orelse unreachable;
    const parent_c = parent.content_rect();
    var parent_content_sizes = [2]f32{
        @floatFromInt(parent_c.width),
        @floatFromInt(parent_c.height)
    };
    if (parent.layout_axis) |layout_axis| {
        parent_content_sizes[@intFromEnum(layout_axis)] = widget.computed.size[layout_axis];
    }
    return parent_content_sizes;
}

fn compute_widget_relative_positions(self: *Self, widget_id: WidgetId, axis: usize) void {
    const widget = self.get_widget(widget_id) orelse unreachable;

    // widget cannot be its own parent
    if (widget.parent) |widget_parent| {
        std.debug.assert(widget_parent.pointer != widget_id.pointer);
    }

    const parent = self.get_widget(widget.parent orelse return) orelse unreachable;
    const parent_content_rect = parent.content_rect();
    const parent_content_anchor_pos = [2]f32{
        parent_content_rect.left,
        parent_content_rect.top
    };

    // if floating on this axis then the relative position has been manually applied, skip
    if (!widget.flags.get_floating_flag(@enumFromInt(axis))) {

        // look at previous siblings to determine relative position
        if (widget.prev_sibling) |sib_id| {
            var prev = self.get_widget(sib_id) orelse unreachable;

            // skip all previous siblings who are floating on this axis
            while (prev.flags.get_floating_flag(@enumFromInt(axis)) and prev.prev_sibling != null) {
                prev = self.get_widget(prev.prev_sibling.?) orelse unreachable;
            }

            if (parent.layout_axis) |layout_axis| {
                if (@intFromEnum(layout_axis) == axis) {
                    widget.computed_relative_position[axis] = prev.computed_relative_position[axis] + prev.outer_size()[axis] + parent.children_gap;
                } else {
                    widget.computed_relative_position[axis] = prev.computed_relative_position[axis];
                }
            } else {
                widget.computed_relative_position[axis] = parent_content_anchor_pos[axis];
            }
        } else {
            // if no previous siblings then set to parent's relative position
            widget.computed_relative_position[axis] = parent_content_anchor_pos[axis];
        }
    }

    const widget_margin_offset: [2]f32 = .{ widget.margin_px.left, widget.margin_px.top };
    //widget.computed_relative_position[axis] += widget_margin_offset[axis];

    // adjust relative position to account for anchor and pivot
    // find the potential space that the widget can take up according to the layout .
    // This contains a compromise which allows a widget to wiggle a bit inside its allowed space 
    // but overall positioning is still ultimately controlled by the layout.
    const potential_space_size = blk: {
        var p = parent.content_size()[axis];
        if (parent.layout_axis) |layout_axis| {
            if (@intFromEnum(layout_axis) == axis) {
                p = widget.size()[axis];
            }
        }
        break :blk p;
    };
    // apply anchor and pivot.
    // anchor determines the position within the potential space allowed by the layout
    // pivot determines the coordinate on the widget's box that sticks to the anchor
    widget.computed_pixel_offset[axis] = widget_margin_offset[axis]
        - (widget.pivot[axis] * widget.size()[axis]) + (widget.anchor[axis] * potential_space_size);
}

const SizeResolutionErrors = error {
    UnableToGetWidget,
    ChildrenSizeWidgetHasNoChildren,
    ParentPercentageUnderChildSize,
    WidgetHasNoParent,
};

fn resolve_widget_size_violations(self: *Self, widget_id: WidgetId, axis: usize) SizeResolutionErrors!void {
    const widget = self.get_widget(widget_id) orelse return error.UnableToGetWidget;

    var overrun: f32 = 1.0;

    while (overrun > 0.0) {
        var siblings_total_length: f32 = 0.0;

        var child: ?WidgetId = widget.first_child;
        var resizable_children: f32 = 0.0;
        while (child != null) {
            const child_widget = self.get_widget(child.?) orelse return error.UnableToGetWidget;
            defer child = child_widget.next_sibling;

            if (child_widget.semantic_size[axis].shrinkable and (child_widget.computed_size[axis] > child_widget.semantic_size[axis].minimum_pixel_size)) {
                resizable_children += 1.0;
            } else {
                child_widget.semantic_size[axis].shrinkable = false;
            }

            if (child_widget.flags.get_allow_overflow_flag(@enumFromInt(axis))) {
                continue;
            }

            if (widget.layout_axis) |layout_axis| {
                if (@intFromEnum(layout_axis) == axis) {
                    if (siblings_total_length != 0.0) {
                        siblings_total_length += widget.children_gap;
                    }
                    siblings_total_length += child_widget.outer_size()[axis];
                } else {
                    siblings_total_length = @max(siblings_total_length, child_widget.outer_size()[axis]);
                }
            }
        }

        overrun = siblings_total_length - widget.content_size()[axis];

        if (resizable_children <= 0.0 or overrun <= 0.1) {
            break;
        }

        const split = overrun / resizable_children;

        child = widget.first_child;
        while (child != null) {
            const child_widget = self.get_widget(child.?) orelse return error.UnableToGetWidget;
            defer child = child_widget.next_sibling;

            if (child_widget.semantic_size[axis].shrinkable) {
                const largest_resize = @max(child_widget.computed_size[axis] - child_widget.semantic_size[axis].minimum_pixel_size, 0.0);
                child_widget.computed_size[axis] -= @min(largest_resize, split);
            }
        }
    }
}

fn recurse_compute_widget_rect(self: *Self, widget_id: WidgetId) SizeResolutionErrors!void {
    const widget = self.get_widget(widget_id) orelse return error.UnableToGetWidget;

    self.compute_standalone_widget_size(widget);

    for (widget.semantic_size, 0..) |s, axis| {
        // skip if we already have calculated this widget's size on this axis
        if (widget.computed_size[axis] != 0) { continue; }

        switch (s.kind) {
            .ChildrenSize => {
                var total_size: f32 = -widget.children_gap;
                var top_size: f32 = 0.0;
                var total_minimum_size: f32 = -widget.children_gap;
                var top_minimum_size: f32 = 0.0;

                var child: ?WidgetId = widget.first_child;
                while (child != null) {
                    const child_widget = self.get_widget(child.?) orelse return error.UnableToGetWidget;
                    defer child = child_widget.next_sibling;

                    // if child is floating then it does not contribute to the size of the parent
                    if (child_widget.flags.get_floating_flag(@enumFromInt(axis))) {
                        continue;
                    }

                    try self.recurse_compute_widget_rect(child.?);

                    top_size = @max(child_widget.outer_size()[axis], top_size);
                    total_size += child_widget.outer_size()[axis] + widget.children_gap;
                    const child_padding: [2]f32 = .{
                        child_widget.padding_px.left + child_widget.padding_px.right + child_widget.border_width_px.left + child_widget.border_width_px.right + child_widget.margin_px.left + child_widget.margin_px.right,
                        child_widget.padding_px.top + child_widget.padding_px.bottom + child_widget.border_width_px.top + child_widget.border_width_px.bottom + child_widget.margin_px.top + child_widget.margin_px.bottom,
                    };
                    const child_minimum_size_and_padding = child_widget.semantic_size[axis].minimum_pixel_size + child_padding[axis];
                    total_minimum_size += child_minimum_size_and_padding + widget.children_gap;
                    top_minimum_size = @max(top_minimum_size, child_minimum_size_and_padding);
                }

                var children_size = @max(top_size, 0.0);
                var children_minimum_size = @max(top_minimum_size, 0.0);
                if (widget.layout_axis) |layout_axis| {
                    if (@intFromEnum(layout_axis) == axis) {
                        children_size = @max(total_size, 0.0);
                        children_minimum_size = @max(total_minimum_size, 0.0);
                    }
                }

                widget.computed_size[axis] = @max(children_size, s.minimum_pixel_size);
                widget.semantic_size[axis].minimum_pixel_size = @max(children_minimum_size, 0.0);
            },
            .ParentPercentage => {
                const parent = self.get_widget(widget.parent orelse return error.WidgetHasNoParent) orelse return error.UnableToGetWidget;

                const widget_padding: [2]f32 = .{
                    widget.padding_px.left + widget.padding_px.right + widget.border_width_px.left + widget.border_width_px.right + widget.margin_px.left + widget.margin_px.right,
                    widget.padding_px.top + widget.padding_px.bottom + widget.border_width_px.top + widget.border_width_px.bottom + widget.margin_px.top + widget.margin_px.bottom,
                };
                widget.computed_size[axis] = @max((parent.content_size()[axis] * s.value) - widget_padding[axis], s.minimum_pixel_size);
            },
            else => {},
        }
    }

    var child: ?WidgetId = widget.first_child;
    while (child != null) {
        const child_widget = self.get_widget(child.?) orelse return error.UnableToGetWidget;
        defer child = child_widget.next_sibling;

        try self.recurse_compute_widget_rect(child.?);
    }
}

fn recurse_resolve_widget_size_violations(self: *Self, widget_id: WidgetId, axis: usize) void {
    self.resolve_widget_size_violations(widget_id, axis) catch unreachable;
    self.compute_widget_relative_positions(widget_id, axis);

    var maybe_child = widget_id.get().first_child;
    while (maybe_child) |child| {
        self.recurse_resolve_widget_size_violations(child, axis);
        maybe_child = child.get().next_sibling;
    }
}

fn compute_widget_rects(self: *Self) void {
    for (self.root_widgets.items) |root_widget| {
        self.recurse_compute_widget_rect(root_widget.widget) catch unreachable;
    }

    for (self.root_widgets.items) |root_widget| {
        self.recurse_resolve_widget_size_violations(root_widget.widget, 0);
        self.recurse_resolve_widget_size_violations(root_widget.widget, 1);
    }
}

fn render_imui_widget(
    self: *Self, 
    widget: *const Widget,
    z_index: usize,
    scissor_rect: RectPixels,
    render_palette: Palette
) void {
    _ = z_index;
    const z_value = @as(f32, @floatFromInt(self.quad_renderer.frame_quads.items.len)) * 0.0001;

    if (widget.flags.render_quad) {
        const quad_texture_props = blk: { 
            if (widget.texture) |tex_props| {
                break :blk QuadRenderer.QuadPropertiesTexture {
                    .texture_view = tex_props.texture_view,
                    .sampler = tex_props.sampler,
                };
            } else { 
                break :blk null;
            } 
        };

        self.quad_renderer.submit_quad(.{
            .rect = widget.rect(),
            .z_value = z_value,
            .scissor = scissor_rect,
            .colour = render_palette.background,
            .border_colour = 
                // if (widget.key == self.active_item) zm.f32x4(1.0, 0.0, 0.0, 1.0)
                // else if (widget.key == self.hot_item) zm.f32x4(0.0, 1.0, 0.0, 1.0)
                // else 
                    render_palette.border,
            .border_width_px = qr.RectEdges.from_rect_pixels(widget.border_width_px),
            .corner_radii_px = widget.corner_radii_px,
            .texture = quad_texture_props,
        }) catch |err| {
            std.log.warn("Unable to submit quad for rendering: {}", .{err});
        };
    }

    // render text
    if (widget.text_content) |*text| {
        const font_metrics = self.get_font(text.font).font_metrics;
        const rect = widget.rect();
        const x = rect.left;
        const y = rect.top + (font_metrics.ascender * text.size);

        self.get_font(text.font).submit_text_2d(text.text, .{
            .position = .{ .x = x, .y = y, },
            .z_value = z_value + 0.00005,
            .colour = 
                if (text.colour) |colour| colour
                else if (zm.any(render_palette.background < zm.f32x4s(0.5), 3)) render_palette.text_light
                else render_palette.text_dark,
            .pixel_height = text.size,
            .scissor = scissor_rect,
        }) catch |err| {
            std.log.warn("Unable to submit text for rendering: {}", .{err});
        };
    }
}

fn render_imui_recursive(
    self: *Self, 
    widget_id: WidgetId,
    z_index: usize,
    parent_scissor: RectPixels,
    parent_palette: Palette
) void {
    const widget = self.get_widget(widget_id) orelse return;

    const widget_scissor = blk: {
        var widget_scissor = parent_scissor;
        // // clamp widget scissor to parent scissor
        // widget_scissor.left = @max(widget_scissor.left, parent_scissor.left);
        // widget_scissor.top = @max(widget_scissor.top, parent_scissor.top);
        // widget_scissor.width = @min(widget_scissor.left + widget_scissor.width, parent_scissor.left + parent_scissor.width) - widget_scissor.left;
        // widget_scissor.height = @min(widget_scissor.top + widget_scissor.height, parent_scissor.top + parent_scissor.height) - widget_scissor.top;

        // expand scissor if overflow is allowed
        const swapchain_size = engine.get().gfx.swapchain_size();
        if (widget.flags.allows_overflow_x) {
            widget_scissor.right = @floatFromInt(swapchain_size[0]);
            widget_scissor.left = 0;
        }
        if (widget.flags.allows_overflow_y) {
            widget_scissor.bottom = @floatFromInt(swapchain_size[1]);
            widget_scissor.top = 0;
        }

        break :blk widget_scissor;
    };

    const widget_content_scissor = blk: {
        var scissor = widget.content_rect();
        // clamp widget scissor to parent scissor
        scissor.left = @max(scissor.left, parent_scissor.left);
        scissor.top = @max(scissor.top, parent_scissor.top);
        scissor.right = @min(scissor.right, parent_scissor.right);
        scissor.bottom = @min(scissor.bottom, parent_scissor.bottom);

        // expand scissor if overflow is allowed
        const swapchain_size = engine.get().gfx.swapchain_size();
        if (widget.flags.allows_overflow_x) {
            scissor.right = @floatFromInt(swapchain_size[0]);
            scissor.left = 0;
        }
        if (widget.flags.allows_overflow_y) {
            scissor.bottom = @floatFromInt(swapchain_size[1]);
            scissor.top = 0;
        }

        break :blk scissor;
    };

    var widget_palette = parent_palette;
    if (widget.background_colour) |bc| { widget_palette.background = bc; }
    if (widget.border_colour) |bc| { widget_palette.border = bc; }
    if (widget.text_content) |tx| {
        if (tx.colour) |tc| {
            widget_palette.text_light = tc;
            widget_palette.text_dark = tc;
        }
    }

    if (widget.flags.render) {
        var p = widget_palette;

        const __debug_colours = false;
        if (__debug_colours) {
            if (self.hot_item == widget.key) {
                p.background = zm.f32x4(0.0, 0.0, 1.0, 1.0);
            }
            if (self.active_item == widget.key) {
                p.background = zm.f32x4(1.0, 0.0, 0.0, 1.0);
            }
        }

        self.render_imui_widget(widget, z_index, widget_scissor, p);
    }

    if (widget.first_child) |c| {
        self.render_imui_recursive(c, z_index + 1, widget_content_scissor, widget_palette);
    }
    if (widget.next_sibling) |s| {
        self.render_imui_recursive(s, z_index, parent_scissor, parent_palette);
    }
}

fn sort_root_widgets_function(user_data: ?usize, a: RootWidget, b: RootWidget) bool {
    _ = user_data;
    return a.priority < b.priority;
}

pub fn render_imui(self: *Self, cmd: *_gfx.CommandBuffer) !void {
    self.compositor.finish_frame(self);

    // widget rects must be computed before rendering
    self.compute_widget_rects();
    
    const screen_scissor = RectPixels {
        .left = 0.0,
        .top = 0.0,
        .right = @floatFromInt(engine.get().gfx.swapchain_size()[0]),
        .bottom = @floatFromInt(engine.get().gfx.swapchain_size()[1]),
    };
    const render_palette = self.palette();

    std.mem.sort(RootWidget, self.root_widgets.items, @as(?usize, null), sort_root_widgets_function);

    for (self.root_widgets.items) |root_widget| {
        self.render_imui_recursive(root_widget.widget, 0, screen_scissor, render_palette);
    }

    self.quad_renderer.render_quads(cmd) catch |err| {
        std.log.warn("Unable to render quads: {}", .{err});
    };
    for (self.fonts[0..], 0..) |*f, idx| {
        f.render_texts(cmd) catch |err| {
            std.log.warn("Unable to render texts for font '{}': {}", .{ @as(FontEnum, @enumFromInt(idx)), err });
        };
    }
}

pub fn end_frame(self: *Self) void {
    std.debug.assert(self.parent_stack.items.len == 1); // more than just the root widget exists in the parent stack, maybe forgot pop_layout?
    self.parent_stack.clearRetainingCapacity();

    // reset hot and active items
    self.hot_item = if (self.next_hot_item) |ni| self.get_widget(ni).?.key else null;
    self.active_item = if (self.next_active_item) |ni| self.get_widget(ni).?.key else null;

    self.next_hot_item = null;
    self.next_active_item = null;

    // set focus item
    if (self.active_item) |ak| {
        self.focus_item = ak;
    } else if (self.should_clear_focus_next_frame) {
        self.clear_focus_item();
    }
    self.should_clear_focus_next_frame = engine.get().input.get_key_down(self.primary_interact_key);

    // clear old data
    self.last_frame_widgets_map().clearRetainingCapacity();
    self.root_widgets.clearRetainingCapacity();

    // swap arenas
    self.last_frame_index = (self.last_frame_index + 1) % 2;

    // reset arena for the next frame
    if (!self.arena().reset(.retain_capacity)) {
        std.log.err("failed to reset imui arena", .{});
        _ = self.arena().reset(.free_all);
    }

    // add the root widget for the next frame
    _ = self.add_fullscreen_root_widget(0);
}

pub fn generate_widget_signals(self: *Self, widget_id: WidgetId) WidgetSignal(WidgetId) {
    const widget = self.get_widget(widget_id).?;
    var widget_signal = WidgetSignal(WidgetId) {
        .id = widget_id,
    };

    const last_frame_widget = self.get_widget_from_last_frame(widget_id);
    widget_signal.init = (last_frame_widget == null);

    if (last_frame_widget) |lfw| {
        const input = &engine.get().input;

        const lfw_contains_cursor = lfw.rect().contains([2]f32{
            @floatFromInt(input.cursor_position[0]),
            @floatFromInt(input.cursor_position[1]),
        });

        // hover detection
        if (lfw_contains_cursor) {
            if (self.hot_item == widget.key) {
                widget_signal.hover = true;
            }

            var new_next_hot_item = widget_id;
            if (self.next_hot_item) |ni| {
                if (new_next_hot_item.get().priority < ni.get().priority) {
                    new_next_hot_item = ni;
                }
            }
            self.next_hot_item = new_next_hot_item;
        }

        // click or dragged detection
        if (widget.flags.clickable) {
            if (self.active_item == widget.key) {
                if (input.get_key(self.primary_interact_key)) {
                    // dragged
                    widget_signal.dragged = true;
                    self.next_active_item = widget_id;
                }
                if (input.get_key_up(self.primary_interact_key)) {
                    // on up
                }
            } else if (self.hot_item == widget.key) {
                if (input.get_key_down(self.primary_interact_key)) {
                    widget_signal.clicked = true;
                    self.next_active_item = widget_id;
                }
            }
        }
    }

    const time = &engine.get().time;

    if (self.get_widget_from_last_frame(widget_id)) |lw| {
        if (self.hot_item == widget.key) {
            widget.hot_t = @min(lw.hot_t + time.delta_time_unscaled_f32() / widget.hot_t_timescale, 1.0);
        } else {
            widget.hot_t = @max(lw.hot_t - time.delta_time_unscaled_f32() / widget.hot_t_timescale, 0.0);
        }
        if (self.active_item == widget.key) {
            widget.active_t = @min(lw.active_t + time.delta_time_unscaled_f32() / widget.active_t_timescale, 1.0);
        } else {
            widget.active_t = @max(lw.active_t - time.delta_time_unscaled_f32() / widget.active_t_timescale, 0.0);
        }
    }

    return widget_signal;
}

pub fn combine_signals(signals: anytype, id: anytype) WidgetSignal(@TypeOf(id)) {
    var combined = WidgetSignal(@TypeOf(id)) {
        .id = id,
    };

    inline for (signals) |s| {
        combined.init = combined.init or s.init;
        combined.clicked = combined.clicked or s.clicked;
        combined.hover = combined.hover or s.hover;
        combined.dragged = combined.dragged or s.dragged;
        combined.data_changed = combined.data_changed or s.data_changed;
    }

    return combined;
}

pub fn push_pallete(self: *Self, p: Palette) void {
    self.palette_stack.append(self.alloc, p) catch |err| {
        std.log.warn("Unable to push palette: {}", .{err});
    };
}

pub fn pop_pallete(self: *Self) void {
    _ = self.palette_stack.pop();
}

pub fn push_layout_widget_priority(self: *Self, widget: Widget) WidgetId {
    const widget_id = self.add_widget(widget, std.math.maxInt(u32));
    self.parent_stack.append(self.alloc, widget_id) catch unreachable;
    return widget_id;
}

pub fn push_layout_widget(self: *Self, widget: Widget) WidgetId {
    const widget_id = self.add_widget(widget, null);
    self.parent_stack.append(self.alloc, widget_id) catch unreachable;
    return widget_id;
}

pub fn push_layout_id(self: *Self, widget_id: WidgetId) void {
    std.debug.assert(self.get_widget(widget_id) != null);
    self.parent_stack.append(self.alloc, widget_id) catch unreachable;
}

pub fn push_layout(self: *Self, layout_axis: Axis, key: anytype) WidgetId {
    return self.push_layout_widget(Widget {
        .key = gen_key(key),
        .layout_axis = layout_axis,
        .semantic_size = [2]SemanticSize {
            // TODO should these be .ParentPercentage .value = 1.0?
            SemanticSize{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = true, },
            SemanticSize{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = true, },
        },
        .flags = .{
            .render = false,
        },
    });
}

fn floating_layout_widget(layout_axis: Axis, floating_x: f32, floating_y: f32, key: anytype) Widget {
    return Widget {
        .key = gen_key(key),
        .layout_axis = layout_axis,
        .semantic_size = [2]SemanticSize {
            SemanticSize{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = true, },
            SemanticSize{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = true, },
        },
        .computed_relative_position = .{
            floating_x,
            floating_y
        },
        .flags = .{
            .render = false,
            .floating_x = true,
            .floating_y = true,
            .allows_overflow_x = true,
            .allows_overflow_y = true,
        },
    };
}

pub fn push_priority_floating_layout(self: *Self, layout_axis: Axis, floating_x: f32, floating_y: f32, key: anytype) WidgetId {
    const widget = Self.floating_layout_widget(layout_axis, floating_x, floating_y, key);
    const widget_id = self.add_widget(widget, std.math.maxInt(u32));
    self.push_layout_id(widget_id);
    return widget_id;
}

pub fn push_floating_layout(self: *Self, layout_axis: Axis, floating_x: f32, floating_y: f32, key: anytype) WidgetId {
    const widget = Self.floating_layout_widget(layout_axis, floating_x, floating_y, key);
    const widget_id = self.add_widget(widget, null);
    self.push_layout_id(widget_id);
    return widget_id;
}

pub fn push_floating_layout_with_priority(self: *Self, layout_axis: Axis, floating_x: f32, floating_y: f32, priority: u32, key: anytype) WidgetId {
    const widget = Self.floating_layout_widget(layout_axis, floating_x, floating_y, key);
    const widget_id = self.add_widget(widget, priority);
    self.push_layout_id(widget_id);
    return widget_id;
}

pub fn set_floating_layout_position(self: *Self, widget_id: WidgetId, floating_x: f32, floating_y: f32) void {
    const widget = self.get_widget(widget_id) orelse return;
    widget.computed_relative_position = .{ floating_x, floating_y };
}

pub fn push_form_layout_item(self: *Self, key: anytype) WidgetId {
    const form_item_layout = self.push_layout(.X, key ++ .{@src()});
    const form_item_widget = self.get_widget(form_item_layout) orelse unreachable;
    form_item_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, };
    form_item_widget.children_gap = 5;
    form_item_widget.flags.is_form_layout_item = true;
    return form_item_layout;
}

pub fn pop_layout(self: *Self) void {
    // correct sizing for form layouts
    const parent_layout = self.parent_stack.getLast();
    const parent_widget = self.get_widget(parent_layout) orelse unreachable;

    var child = parent_widget.first_child;
    var max_layout_label_width: f32 = -1.0;
    while (child != null) {
        const child_widget = self.get_widget(child.?) orelse unreachable;
        defer child = child_widget.next_sibling;

        if (!child_widget.flags.is_form_layout_item) {
            continue;
        }
        if (child_widget.first_child == null) {
            continue;
        }
        const child_child_widget = self.get_widget(child_widget.first_child.?) orelse unreachable;
        self.compute_standalone_widget_size(child_child_widget);
        max_layout_label_width = @max(max_layout_label_width, child_child_widget.outer_rect().width());
    }

    if (max_layout_label_width > 0.0) {
        child = parent_widget.first_child;
        while (child != null) {
            const child_widget = self.get_widget(child.?) orelse unreachable;
            defer child = child_widget.next_sibling;

            if (!child_widget.flags.is_form_layout_item) {
                continue;
            }
            if (child_widget.first_child == null) {
                continue;
            }
            const child_child_widget = self.get_widget(child_widget.first_child.?) orelse unreachable;
            child_child_widget.semantic_size[0].kind = .Pixels;
            child_child_widget.semantic_size[0].value = max_layout_label_width;
            child_child_widget.semantic_size[0].shrinkable = false;
        }
    }

    _ = self.parent_stack.pop();
}
