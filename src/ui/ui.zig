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

pub const font = @import("font.zig");
pub const qr = @import("quad_renderer.zig");
const QuadRenderer = qr.QuadRenderer;
const RectPixels = engine.Rect;

pub const widgets = @import("widgets.zig");

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
    shrinkable_percent: f32 = 1.0,
    minimum_pixel_size: f32 = 0.0,
};

pub const Axis = enum(usize) {
    X = 0,
    Y = 1,
};
pub const AxisCount = 2;

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

    __unused: u24 = 0,

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

pub const WidgetComputedValues = struct {
    relative_position: [2]f32 = .{0.0, 0.0},
    pixel_offset: [2]f32 = .{0.0, 0.0},
    left_top_margin: [2]f32 = .{0.0, 0.0},
    right_bottom_margin: [2]f32 = .{0.0, 0.0},
    size: [2]f32 = .{0.0, 0.0},
    children_size: [2]f32 = .{0.0, 0.0},

    pub inline fn total_size(self: *const @This()) [2]f32 {
        return .{
            self.size[0] + self.left_top_margin[0] + self.right_bottom_margin[0],
            self.size[1] + self.left_top_margin[1] + self.right_bottom_margin[1],
        };
    }

    pub fn rect(self: *const @This()) RectPixels {
        const left = self.relative_position[0] + self.left_top_margin[0] + self.pixel_offset[0];
        const top = self.relative_position[1] + self.left_top_margin[1] + self.pixel_offset[1];
        return RectPixels {
            .left = left,
            .top = top,
            .right = left + self.size[0],
            .bottom = top + self.size[1]
        };
    }

    pub fn total_rect(self: *const @This()) RectPixels {
        const left = self.relative_position[0] + self.pixel_offset[0];
        const top = self.relative_position[1] + self.pixel_offset[1];
        return RectPixels {
            .left = left,
            .top = top,
            .right = left + self.size[0] + self.left_top_margin[0] + self.right_bottom_margin[0],
            .bottom = top + self.size[1] + self.left_top_margin[1] + self.right_bottom_margin[1]
        };
    }
};

pub const Widget = struct {
    semantic_size: [AxisCount]SemanticSize,

    key: Key,

    // sibling data
    next_sibling: ?WidgetId = null,
    prev_sibling: ?WidgetId = null,
    parent: WidgetId = WidgetId { .location = .Standard, .index = 0 },

    // parent data
    layout_axis: ?Axis = null,
    first_child: ?WidgetId = null,
    last_child: ?WidgetId = null,
    num_children: usize = 0,
    children_gap: f32 = 0.0,

    computed: WidgetComputedValues = .{},

    active_t: f32 = 0.0,
    active_t_timescale: f32 = 0.1,
    hot_t: f32 = 0.0,
    hot_t_timescale: f32 = 0.1,

    flags: WidgetFlags = .{},

    text_content: ?struct {
        font: FontEnum = FontEnum.GeistMono,
        text: []const u8,
        size: f32 = 13.0,
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
    pixel_offset: [2]f32 = .{0.0, 0.0},

    widget_data: ?*anyopaque = null,

    pub fn content_rect(self: *const Widget) RectPixels {
        const rect = self.computed.rect();
        return RectPixels {
            .left = rect.left + self.padding_px.left + self.border_width_px.left,
            .top = rect.top + self.padding_px.top + self.border_width_px.top,
            .right = rect.right - self.padding_px.right - self.border_width_px.right,
            .bottom = rect.bottom - self.padding_px.bottom - self.border_width_px.bottom,
        };
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

pub const Palette = struct {
    pub const default_palette = slate();

    background: zm.F32x4,
    foreground: zm.F32x4,
    primary: zm.F32x4,
    secondary: zm.F32x4,
    accent: zm.F32x4,
    text_dark: zm.F32x4,
    text_light: zm.F32x4,
    border: zm.F32x4,
    muted: zm.F32x4,

    fn hsl(str: []const u8) !zm.F32x4 {
        var tokens = std.mem.tokenizeScalar(u8, str, ' ');

        const hue_str = tokens.next() orelse return error.InvalidString;
        const hue = (try std.fmt.parseFloat(f32, hue_str)) / 360.0;

        var sat_str = tokens.next() orelse return error.InvalidString;
        var sat_scale = 1.0;
        if (sat_str[sat_str.len - 1] == '%') {
            sat_str = sat_str[0..(sat_str.len-1)];
            sat_scale = 100.0;
        }
        const saturation = (try std.fmt.parseFloat(f32, sat_str)) / sat_scale;

        var val_str = tokens.next() orelse return error.InvalidString;
        var val_scale = 1.0;
        if (val_str[val_str.len - 1] == '%') {
            val_str = val_str[0..(val_str.len-1)];
            val_scale = 100.0;
        }
        const value = (try std.fmt.parseFloat(f32, val_str)) / val_scale;

        return zm.srgbToRgb(zm.hslToRgb(zm.f32x4(hue, saturation, value, 1.0)));
    }

    pub fn slate() Palette {
        @setEvalBranchQuota(10000);
        return Palette {
            .text_light = zm.srgbToRgb(zm.f32x4(248.0/255.0, 250.0/255.0, 252.0/255.0, 1.0)), 
            .text_dark = zm.srgbToRgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, 1.0)),
            .primary = hsl("222.2 47.4% 11.2%") catch unreachable,
            .border = hsl("214.3 31.8% 91.4%") catch unreachable,
            .background = hsl("0 0% 100%") catch unreachable,
            .foreground = hsl("222.2 84% 4.9%") catch unreachable,
            .muted = hsl("210 40% 96.1%") catch unreachable,
            .secondary = hsl("210 40% 96.1%") catch unreachable,
            .accent = hsl("210 40% 96.1%") catch unreachable,
        };
        // .theme-slate {
        //     --background:0 0% 100%;
        //     --foreground:222.2 84% 4.9%;
        //     --muted:210 40% 96.1%;
        //     --muted-foreground:215.4 16.3% 46.9%;
        //     --popover:0 0% 100%;
        //     --popover-foreground:222.2 84% 4.9%;
        //     --card:0 0% 100%;
        //     --card-foreground:222.2 84% 4.9%;
        //     --border:214.3 31.8% 91.4%;
        //     --input:214.3 31.8% 91.4%;
        //     --primary:222.2 47.4% 11.2%;
        //     --primary-foreground:210 40% 98%;
        //     --secondary:210 40% 96.1%;
        //     --secondary-foreground:222.2 47.4% 11.2%;
        //     --accent:210 40% 96.1%;
        //     --accent-foreground:222.2 47.4% 11.2%;
        //     --destructive:0 84.2% 60.2%;
        //     --destructive-foreground:210 40% 98%;
        //     --ring:222.2 84% 4.9%;
        //     --radius:0.5rem
        // }
    }
};

pub const LabelKey: Key = std.hash.XxHash64.hash(0, "Imuilabel");

pub const WidgetLocation = enum(u1) {
    Standard,
    Priority,
};

pub const WidgetId = packed struct(u32) {
    location: WidgetLocation,
    index: u31,

    const InvalidIndex = std.math.maxInt(u31);

    pub const invalid = WidgetId {
        .location = .Standard,
        .index = InvalidIndex,
    };

    pub fn is_valid(self: *const WidgetId) bool {
        return self.index != InvalidIndex;
    }
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

input: *const in.InputState,
time: *const tm.TimeState,
window: *const platform.Window,

primary_interact_key: in.KeyCode = in.KeyCode.MouseLeft,
quad_renderer: QuadRenderer,
fonts: [@intFromEnum(FontEnum.Count)]font.Font,

parent_stack: std.ArrayList(WidgetId),
palette_stack: std.ArrayList(Palette),

standard_widgets: std.ArrayList(Widget),
// widgets within the priority array will always be rendered on top of standard widgets and will
// demand interactions over standard widgets. This is useful for things like dropdown or context menus.
priority_widgets: std.ArrayList(Widget),
last_frame_widgets: std.AutoHashMap(Key, Widget),

last_frame_arena: u8,
arenas: [2]std.heap.ArenaAllocator,

scuffed_x_checkbox_image: _gfx.Image.Ref,
scuffed_x_checkbox_image_view: _gfx.ImageView.Ref,
image_sampler: _gfx.Sampler.Ref,

pub fn deinit(self: *Self) void {
    for (&self.fonts) |*f| {
        f.deinit();
    }
    self.quad_renderer.deinit();

    self.palette_stack.deinit(self.alloc);
    self.parent_stack.deinit(self.alloc);
    self.standard_widgets.deinit(self.alloc);
    self.priority_widgets.deinit(self.alloc);
    self.last_frame_widgets.deinit();

    self.scuffed_x_checkbox_image_view.deinit();
    self.scuffed_x_checkbox_image.deinit();
    self.image_sampler.deinit();

    for (self.arenas) |a| {
        a.deinit();
    }
}

pub fn init(
    alloc: std.mem.Allocator,
    input: *const in.InputState,
    time: *const tm.TimeState,
    window: *const platform.Window,
    gfx: *_gfx.GfxState
) !Self {
    var scuffed_x_image = try zstbi.Image.loadFromFile("res/scuffed_x.png", 4);
    defer scuffed_x_image.deinit();

    var scuffed_x_checkbox_image = try _gfx.Image.init(
        .{
            .width = scuffed_x_image.width,
            .height = scuffed_x_image.height,
            .format = _gfx.ImageFormat.Rgba8_Unorm_Srgb,

            .usage_flags = .{ .ShaderResource = true, },
            .access_flags = .{},
            .dst_layout = .ShaderReadOnlyOptimal,
        },
        scuffed_x_image.data,
    );
    errdefer scuffed_x_checkbox_image.deinit();
    
    var scuffed_x_checkbox_image_view = try _gfx.ImageView.init(.{
        .image = scuffed_x_checkbox_image,
        .view_type = .ImageView2D,
    });
    errdefer scuffed_x_checkbox_image_view.deinit();

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

    var self = Self {
        .alloc = alloc,
        .input = input,
        .time = time,
        .window = window,
        .parent_stack = std.ArrayList(WidgetId).empty,
        .palette_stack = std.ArrayList(Palette).empty,
        .standard_widgets = std.ArrayList(Widget).empty,
        .priority_widgets = std.ArrayList(Widget).empty,
        .last_frame_widgets = std.AutoHashMap(Key, Widget).init(alloc),
        .scuffed_x_checkbox_image = scuffed_x_checkbox_image,
        .scuffed_x_checkbox_image_view = scuffed_x_checkbox_image_view,
        .image_sampler = try _gfx.Sampler.init(.{}),
        .last_frame_arena = 0,
        .arenas = [_]std.heap.ArenaAllocator{
            std.heap.ArenaAllocator.init(alloc),
            std.heap.ArenaAllocator.init(alloc),
        },
        .quad_renderer = try QuadRenderer.init(alloc),
        .fonts = fonts,
    };
    self.add_root_widget(gfx);
    return self;
}

pub inline fn root_widget_id(location: WidgetLocation) WidgetId {
    return WidgetId {
        .location = location,
        .index = 0,
    };
}

pub fn get_font(self: *Self, font_enum: FontEnum) *font.Font {
    return &self.fonts[@intFromEnum(font_enum)];
}

fn arena(self: *Self) *std.heap.ArenaAllocator {
    return &self.arenas[(@as(usize, @intCast(self.last_frame_arena)) + 1) % 2];
}

pub fn widget_allocator(self: *const Self) std.mem.Allocator {
    return @constCast(self).arena().allocator();
}

pub fn palette(self: *const Self) Palette {
    return self.palette_stack.getLastOrNull() orelse Palette.default_palette;
}

fn add_heirarchy_links(self: *Self, parent_id: WidgetId, widget_id: WidgetId) !void {
    std.debug.assert(parent_id != widget_id);

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
                widget.computed.size[axis] = s.value;
                apply_padding(widget, axis);
                apply_border_padding(widget, axis);
                widget.computed.size[axis] = @max(widget.computed.size[axis], s.minimum_pixel_size);
            },
            .TextContent => {
                if (widget.text_content) |*text| {
                    const text_bounds = self.get_font(text.font).text_bounds_2d_pixels(
                        text.text,
                        text.size
                    );
                    switch (axis) {
                        0 => widget.computed.size[0] = text_bounds.width(),
                        1 => widget.computed.size[1] = text_bounds.height() - self.get_font(text.font).font_metrics.descender,
                        else => {unreachable;}
                    }
                } else {
                    std.log.warn("widget with size kind \"Text Content\" does not have any text content.", .{});
                }
                apply_padding(widget, axis);
                apply_border_padding(widget, axis);
                widget.computed.size[axis] = @max(widget.computed.size[axis], s.minimum_pixel_size);
            },
            else => {},
        }
    }
}

pub const AddWidgetOptions = struct {
    destination: union(enum) {
        Auto: void,
        Manual: WidgetLocation,
    } = .Auto,
};

pub fn add_widget(self: *Self, widget: Widget, opt: AddWidgetOptions) WidgetId {
    var widget_to_add = widget;
    // we need to own the text content so duplicate it using this frame's arena before adding the widget
    if (widget_to_add.text_content) |*text| {
        text.text = self.arena().allocator().dupe(u8, text.text) catch unreachable;
    }

    const parent_id = self.parent_stack.getLast();

    const widget_id = blk: {
        const destination = switch (opt.destination) {
            .Auto => parent_id.location,
            .Manual => |manual_location| manual_location,
        };
        const destination_array = switch (destination) {
            .Priority => &self.priority_widgets,
            .Standard => &self.standard_widgets,
        };

        const widget_index = destination_array.items.len;
        destination_array.append(self.alloc, widget_to_add) catch unreachable;
        break :blk WidgetId {
            .location = destination,
            .index = @truncate(widget_index),
        };
    };

    self.add_heirarchy_links(parent_id, widget_id) catch unreachable;
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

pub fn get_widget(self: *Self, widget_id: WidgetId) ?*Widget {
    switch (widget_id.location) {
        .Standard => {
            if (widget_id.index >= self.standard_widgets.items.len) { return null; }
            return &self.standard_widgets.items[widget_id.index];
        },
        .Priority => {
            if (widget_id.index >= self.priority_widgets.items.len) { return null; }
            return &self.priority_widgets.items[widget_id.index];
        },
    }
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
    return self.last_frame_widgets.getPtr(widget.key);
}

fn add_root_widget(self: *Self, gfx: *const _gfx.GfxState) void {
    std.debug.assert(self.standard_widgets.items.len == 0);

    const root_widget = Widget {
        .semantic_size = [_]SemanticSize{.{.kind = .None, .value = 0.0, }} ** 2,
        .key = gen_key(.{@src()}),
        .computed = .{
            .relative_position = .{0.0, 0.0},
            .size = .{
                @floatFromInt(gfx.swapchain_size()[0]), 
                @floatFromInt(gfx.swapchain_size()[1])
            },
        },
        .flags = .{
            .render = false,
            .allows_overflow_x = false,
            .allows_overflow_y = false,
        },
    };
    self.standard_widgets.append(self.alloc, root_widget) catch unreachable;

    self.parent_stack.append(self.alloc, .{ .location = .Standard, .index = 0 }) catch unreachable;
}

fn solve_upward_dependant_sizes(self: *Self, widget: *Widget) void {
    const parent = self.get_widget(widget.parent) orelse unreachable;
    for (widget.semantic_size, 0..) |s, axis| {
        switch (s.kind) {
            .ParentPercentage => {
                switch (axis) {
                    @intFromEnum(Axis.X) => widget.computed.size[axis] = parent.content_rect().width() * s.value,
                    @intFromEnum(Axis.Y) => widget.computed.size[axis] = parent.content_rect().height() * s.value,
                    else => {unreachable;},
                }
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

fn solve_size_violations_in_children(self: *Self, parent_id: WidgetId) bool {
    const parent = self.get_widget(parent_id) orelse return false;
    if (parent.num_children == 0) { return false; }
    var violation_found = false;

    for (0..parent.semantic_size.len) |axis| {
        if (parent.flags.get_allow_overflow_flag(@enumFromInt(axis))) { continue; }

        var iteration: u64 = 0;

        var children_in_split: usize = parent.num_children;
        // violation in this axis
        const last_child = self.get_widget(parent.last_child.?).?;
        const parent_content_rect = parent.content_rect();
        const parent_content_size = [2]f32{parent_content_rect.width(), parent_content_rect.height()};
        var overrun = last_child.computed.relative_position[axis] + last_child.computed.size[axis] - (parent.computed.relative_position[axis] + parent_content_size[axis]);
        var last_overrun: f32 = overrun + 2.0;
        while (overrun >= 1.0 and children_in_split > 0) {
            iteration += 1;
            violation_found = true;
            // break if we find ourselves in infinite loop
            if (@abs(overrun - last_overrun) <= 1.0) {
                std.log.warn("widgets ran out of shrinkable space!", .{});
                violation_found = false;
                break;
            }
            last_overrun = overrun;

            // find the split between remaining children
            const split = overrun / @as(f32, @floatFromInt(children_in_split));
            // reset children in split count, this is rediscovered each loop
            children_in_split = parent.num_children;

            // iterate through all children attempting to shrink by the split amount
            var child_id = parent.first_child;
            while (child_id != null) {
                const child = self.get_widget(child_id.?).?;

                // determine how much this child may shink
                const amount_can_shrink = child.semantic_size[axis].shrinkable_percent * child.computed.size[axis];
                const minimum_size = child.computed.size[axis] - amount_can_shrink;
                if (amount_can_shrink >= split) {
                    // if it can shrink the full amount, do so.
                    overrun -= split;
                    child.computed.size[axis] -= split;
                    child.semantic_size[axis].shrinkable_percent = (1.0 - (minimum_size / child.computed.size[axis]));
                } else { 
                    // if it cannot shrink the full amount, then shink as much as possible 
                    // and remove this child from the split count
                    overrun -= amount_can_shrink;
                    // disable further shinking on this child
                    child.computed.size[axis] -= amount_can_shrink;
                    child.semantic_size[axis].shrinkable_percent = 0.0;
                    children_in_split -= 1;
                }

                // recompute the relative positions of the children
                self.compute_widget_relative_positions(child_id.?);

                // go to next child
                child_id = child.next_sibling;
            }
        }
    }

    return violation_found;
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

fn compute_widget_relative_positions(self: *Self, widget_id: WidgetId) void {
    const widget = self.get_widget(widget_id) orelse unreachable;
    if (widget.parent == widget_id) { return; }

    const parent = self.get_widget(widget.parent) orelse unreachable;
    const parent_content_rect = parent.content_rect();
    const parent_content_anchor_pos = [2]f32{
        parent_content_rect.left,
        parent_content_rect.top
    };

    // calculate relative position of widget on each axis
    for (0..AxisCount) |axis| {
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
                        widget.computed.relative_position[axis] = prev.computed.relative_position[axis] + prev.computed.total_size()[axis] + parent.children_gap;
                    } else {
                        widget.computed.relative_position[axis] = prev.computed.relative_position[axis];
                    }
                } else {
                    widget.computed.relative_position[axis] = parent_content_anchor_pos[axis];
                }
            } else {
                // if no previous siblings then set to parent's relative position
                widget.computed.relative_position[axis] = parent_content_anchor_pos[axis];
            }
        }

        // adjust relative position to account for anchor and pivot
        const parent_content_size = [2]f32{
            parent_content_rect.width(),
            parent_content_rect.height()
        };
        // find the potential space that the widget can take up according to the layout .
        // This contains a compromise which allows a widget to wiggle a bit inside its allowed space 
        // but overall positioning is still ultimately controlled by the layout.
        const potential_space_size = blk: {
            var p = parent_content_size[axis];
            if (parent.layout_axis) |layout_axis| {
                if (@intFromEnum(layout_axis) == axis) {
                    p = widget.computed.size[axis];
                }
            }
            break :blk p;
        };
        // apply anchor and pivot.
        // anchor determines the position within the potential space allowed by the layout
        // pivot determines the coordinate on the widget's box that sticks to the anchor
        widget.computed.pixel_offset[axis] =
            - (widget.pivot[axis] * widget.computed.size[axis]) 
            + (widget.anchor[axis] * potential_space_size)
            + widget.pixel_offset[axis];
    }
}

fn recurse_resolve_violations(self: *Self, widget_id: WidgetId) void {
    var c = self.get_widget(widget_id).?.first_child;
    while (c != null) {
        self.solve_upward_dependant_sizes(self.get_widget(c.?).?);
        c = self.get_widget(c.?).?.next_sibling;
    }
    c = self.get_widget(widget_id).?.first_child;
    while (c != null) {
        self.compute_widget_relative_positions(c.?);
        c = self.get_widget(c.?).?.next_sibling;
    }
    _ = self.solve_size_violations_in_children(widget_id);

    if (self.get_widget(widget_id).?.next_sibling) |ns| {
        self.recurse_resolve_violations(ns);
    }
    if (self.get_widget(widget_id).?.first_child) |fc| {
        self.recurse_resolve_violations(fc);
    }
}

fn compute_widget_rects(self: *Self) void {
    // downward solve
    for (0..self.standard_widgets.items.len) |inv_id| {
        const id = self.standard_widgets.items.len - inv_id - 1;
        const widget = &self.standard_widgets.items[id];

        widget.computed.left_top_margin[0] += widget.margin_px.left;
        widget.computed.left_top_margin[1] += widget.margin_px.top;
        widget.computed.right_bottom_margin[0] = widget.margin_px.right;
        widget.computed.right_bottom_margin[1] = widget.margin_px.bottom;

        self.compute_standalone_widget_size(widget);
        self.solve_downward_dependant_sizes(widget);
    }
    for (0..self.priority_widgets.items.len) |inv_id| {
        const id = self.priority_widgets.items.len - inv_id - 1;
        const widget = &self.priority_widgets.items[id];
        self.compute_standalone_widget_size(widget);
        self.solve_downward_dependant_sizes(widget);
    }

    // upward solve
    for (self.standard_widgets.items, 0..) |*widget, widget_id| {
        std.debug.assert(widget.parent.index <= widget_id);
        self.solve_upward_dependant_sizes(widget);
    }
    for (self.priority_widgets.items, 0..) |*widget, widget_id| {
        std.debug.assert(widget.parent.location == .Standard or widget.parent.index <= widget_id);
        self.solve_upward_dependant_sizes(widget);
    }

    // downward solve again to resolve any ParentPercentage under ChildrenSize
    for (0..self.standard_widgets.items.len) |inv_id| {
        const id = self.standard_widgets.items.len - inv_id - 1;
        const widget = &self.standard_widgets.items[id];
        self.solve_downward_dependant_sizes(widget);
    }
    for (0..self.priority_widgets.items.len) |inv_id| {
        const id = self.priority_widgets.items.len - inv_id - 1;
        const widget = &self.priority_widgets.items[id];
        self.solve_downward_dependant_sizes(widget);
    }

    self.recurse_resolve_violations(.{ .location = .Standard, .index = 0 });
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
            .rect = widget.computed.rect(),
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
        const rect = widget.computed.rect();
        const x = rect.left;
        const y = rect.top + (font_metrics.ascender * text.size);

        self.get_font(text.font).submit_text_2d(text.text, .{
            .position = .{ .x = x, .y = y, },
            .z_value = z_value + 0.00005,
            .colour = 
                if (zm.any(render_palette.background < zm.f32x4s(0.5), 3)) render_palette.text_light
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

pub fn render_imui(self: *Self, cmd: *_gfx.CommandBuffer) !void {
    // widget rects must be computed before rendering
    self.compute_widget_rects();
    
    const screen_scissor = RectPixels {
        .left = 0.0,
        .top = 0.0,
        .right = @floatFromInt(engine.get().gfx.swapchain_size()[0]),
        .bottom = @floatFromInt(engine.get().gfx.swapchain_size()[1]),
    };
    const render_palette = self.palette();

    self.render_imui_recursive(.{ .location = .Standard, .index = 0 }, 0, screen_scissor, render_palette);
    self.render_imui_recursive(.{ .location = .Priority, .index = 0 }, 0, screen_scissor, render_palette);

    self.quad_renderer.render_quads(cmd) catch |err| {
        std.log.warn("Unable to render quads: {}", .{err});
    };
    for (self.fonts[0..], 0..) |*f, idx| {
        f.render_texts(cmd) catch |err| {
            std.log.warn("Unable to render texts for font '{}': {}", .{ @as(FontEnum, @enumFromInt(idx)), err });
        };
    }
}

pub fn end_frame(self: *Self, gfx: *const _gfx.GfxState) void {
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

    // fill last frame widgets with widgets from current frame
    self.last_frame_widgets.clearRetainingCapacity();
    for (self.standard_widgets.items) |w| {
        if (w.key != Self.LabelKey) {
            std.debug.assert(!self.last_frame_widgets.contains(w.key)); // widget key is getting squashed. This may mean two or more widgets have the same key.
            self.last_frame_widgets.put(w.key, w) catch unreachable;
        }
    }
    self.standard_widgets.clearRetainingCapacity();
    for (self.priority_widgets.items) |w| {
        if (w.key != Self.LabelKey) {
            std.debug.assert(!self.last_frame_widgets.contains(w.key)); // widget key is getting squashed. This may mean two or more widgets have the same key.
            self.last_frame_widgets.put(w.key, w) catch unreachable;
        }
    }
    self.priority_widgets.clearRetainingCapacity();

    // swap arenas
    self.last_frame_arena = (self.last_frame_arena + 1) % 2;

    // reset arena for the next frame
    if (!self.arena().reset(.retain_capacity)) {
        std.log.err("failed to reset imui arena", .{});
        _ = self.arena().reset(.free_all);
    }

    // add the root widget for the next frame
    self.add_root_widget(gfx);
}

pub fn generate_widget_signals(self: *Self, widget_id: WidgetId) WidgetSignal(WidgetId) {
    const widget = self.get_widget(widget_id).?;
    var widget_signal = WidgetSignal(WidgetId) {
        .id = widget_id,
    };
    const last_frame_widget = self.last_frame_widgets.getPtr(widget.key);
    widget_signal.init = (last_frame_widget == null);

    if (last_frame_widget) |lfw| {
        const lfw_contains_cursor = lfw.computed.total_rect().contains([2]f32{
            @floatFromInt(self.input.cursor_position[0]),
            @floatFromInt(self.input.cursor_position[1]),
        });

        // hover detection
        if (lfw_contains_cursor) {
            if (self.hot_item == widget.key) {
                widget_signal.hover = true;
            }

            var new_next_hot_item = widget_id;
            if (self.next_hot_item) |ni| {
                if (ni.location == .Priority and widget_id.location == .Standard) {
                    new_next_hot_item = ni;
                }
            }
            self.next_hot_item = new_next_hot_item;
        }

        // click or dragged detection
        if (widget.flags.clickable) {
            if (self.active_item == widget.key) {
                if (self.input.get_key(self.primary_interact_key)) {
                    // dragged
                    widget_signal.dragged = true;
                    self.next_active_item = widget_id;
                }
                if (self.input.get_key_up(self.primary_interact_key)) {
                    // on up
                }
            } else if (self.hot_item == widget.key) {
                if (self.input.get_key_down(self.primary_interact_key)) {
                    widget_signal.clicked = true;
                    self.next_active_item = widget_id;
                }
            }
        }
    }

    if (self.last_frame_widgets.getPtr(widget.key)) |lw| {
        if (self.hot_item == widget.key) {
            widget.hot_t = @min(lw.hot_t + self.time.delta_time_unscaled_f32() / widget.hot_t_timescale, 1.0);
        } else {
            widget.hot_t = @max(lw.hot_t - self.time.delta_time_unscaled_f32() / widget.hot_t_timescale, 0.0);
        }
        if (self.active_item == widget.key) {
            widget.active_t = @min(lw.active_t + self.time.delta_time_unscaled_f32() / widget.active_t_timescale, 1.0);
        } else {
            widget.active_t = @max(lw.active_t - self.time.delta_time_unscaled_f32() / widget.active_t_timescale, 0.0);
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
    self.palette_stack.append(self.alloc, p);
}

pub fn pop_pallete(self: *Self) void {
    _ = self.palette_stack.pop();
}

pub fn push_layout_widget_priority(self: *Self, widget: Widget) WidgetId {
    const widget_id = self.add_widget(widget, .{ .destination = .{ .Manual = .Priority } });
    self.parent_stack.append(self.alloc, widget_id) catch unreachable;
    return widget_id;
}

pub fn push_layout_widget(self: *Self, widget: Widget) WidgetId {
    const widget_id = self.add_widget(widget, .{});
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
            SemanticSize{ .kind = .ChildrenSize, .value = 0.0, .shrinkable_percent = 0.0, },
            SemanticSize{ .kind = .ChildrenSize, .value = 0.0, .shrinkable_percent = 0.0, },
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
            SemanticSize{ .kind = .ChildrenSize, .value = 0.0, .shrinkable_percent = 0.0, },
            SemanticSize{ .kind = .ChildrenSize, .value = 0.0, .shrinkable_percent = 0.0, },
        },
        .computed = .{
            .relative_position = .{
                floating_x,
                floating_y
            },
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
    const widget_id = self.add_widget(widget, .{ 
        .destination = .{ .Manual = .Priority },
    });
    self.push_layout_id(widget_id);
    return widget_id;
}

pub fn push_floating_layout(self: *Self, layout_axis: Axis, floating_x: f32, floating_y: f32, key: anytype) WidgetId {
    const widget = Self.floating_layout_widget(layout_axis, floating_x, floating_y, key);
    const widget_id = self.add_widget(widget, .{});
    self.push_layout_id(widget_id);
    return widget_id;
}

pub fn set_floating_layout_position(self: *Self, widget_id: WidgetId, floating_x: f32, floating_y: f32) void {
    const widget = self.get_widget(widget_id) orelse return;
    widget.computed.relative_position = [2]f32 { floating_x, floating_y };
}

pub fn pop_layout(self: *Self) void {
    _ = self.parent_stack.pop();
}
