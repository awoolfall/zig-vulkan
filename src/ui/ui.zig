const std = @import("std");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const engine = @import("../root.zig");
const _gfx = engine.gfx;
const tm = engine.time;
const in = engine.input;
const es = engine.easings;
const platform = engine.platform;
const path = engine.path;

pub const font = @import("font.zig");
pub const qr = @import("quad_renderer.zig");
const QuadRenderer = qr.QuadRenderer;

// pixels, top left of screen is 0, 0. moving down and right increases
pub const RectPixels = struct {
    left: i32,
    top: i32,
    width: i32,
    height: i32,

    pub inline fn translate(self: *const RectPixels, x: i32, y: i32) RectPixels {
        return RectPixels {
            .left = self.left + x,
            .top = self.top + y,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn contains(self: *const RectPixels, coord: [2]i32) bool {
        return  coord[0] >= self.left and
                coord[0] <= self.left + self.width and
                coord[1] >= self.top and
                coord[1] <= self.top + self.height;
    }
};

pub const FontEnum = enum(usize) {
    GeistMono = 0,
    Geist,
    Count,

    fn font_paths(font_enum: FontEnum) struct {json: path.Path, png: path.Path} {
        switch (font_enum) {
            FontEnum.GeistMono => return .{
                .json = path.Path{.ExeRelative = "../../res/GeistMono-Regular.json"},
                .png = path.Path{.ExeRelative = "../../res/GeistMono-Regular.png"},
            },
            FontEnum.Geist => return .{
                .json = path.Path{.ExeRelative = "../../res/Geist-Regular.json"},
                .png = path.Path{.ExeRelative = "../../res/Geist-Regular.png"},
            },
            FontEnum.Count => unreachable,
        }
    }
};

pub fn position_pixels_to_screen_space(x: i32, y: i32, max_width: u32, max_height: u32) [2]f32 {
    const x_f32: f32 = @floatFromInt(x);
    const y_f32: f32 = @floatFromInt(y);
    const max_width_f32: f32 = @floatFromInt(max_width);
    const max_height_f32: f32 = @floatFromInt(max_height);
    return [2]f32{
        ((x_f32 / max_width_f32) * 2.0) - 1.0,
        -(((y_f32 / max_height_f32) * 2.0) - 1.0)
    };
}

pub const Imui = struct {
    const Self = @This();

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

    fn gen_key(key_input: anytype) Key {
        var hasher = std.hash.XxHash64.init(0);
        const len = std.meta.fields(@TypeOf(key_input)).len;
        inline for (0..len) |i| {
            hasher.update(&std.mem.toBytes(key_input[i]));
        }
        return hasher.final();
    }

    pub const WidgetFlags = packed struct(u32) {
        render: bool = true,
        hover_effect: bool = true,

        allows_overflow_x: bool = false,
        allows_overflow_y: bool = false,

        floating_x: bool = false,
        floating_y: bool = false,

        clickable: bool = false,

        __unused: u25 = 0,

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

        computed: struct {
            relative_position: [2]f32 = .{0.0, 0.0},
            offset_position: [2]f32 = .{0.0, 0.0},
            size: [2]f32 = .{0.0, 0.0},
            children_size: [2]f32 = .{0.0, 0.0},
            pub fn rect(self: *const @This()) RectPixels {
                return RectPixels {
                    .left = @intFromFloat(self.offset_position[0]),
                    .top = @intFromFloat(self.offset_position[1]),
                    .width = @intFromFloat(self.size[0]),
                    .height = @intFromFloat(self.size[1])
                };
            }
        } = .{},

        active_t: f32 = 0.0,
        active_t_timescale: f32 = 0.1,
        hot_t: f32 = 0.0,
        hot_t_timescale: f32 = 0.1,

        flags: WidgetFlags = .{},

        text_content: ?struct {
            font: FontEnum = FontEnum.GeistMono,
            text: []const u8,
            size: u16 = 13,
            colour: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
        } = null,
        background_colour: ?zm.F32x4 = null,
        border_colour: ?zm.F32x4 = null,
        border_width_px: u16 = 0,
        corner_radii_px: qr.CornerRadiiPx = .{},
        texture: ?struct {
            texture_view: _gfx.TextureView2D,
            sampler: _gfx.Sampler,
        } = null,
        padding_px: struct {
            left: u16 = 0,
            right: u16 = 0,
            top: u16 = 0,
            bottom: u16 = 0,
        } = .{},
        // anchor determines the position within the potential space allowed by the layout
        anchor: [2]f32 = .{0.0, 0.0},
        // pivot determines the coordinate on the widget's box that sticks to the anchor
        pivot: [2]f32 = .{0.0, 0.0},
        pixel_offset: [2]f32 = .{0.0, 0.0},
        children_gap: f32 = 0.0,

        pub fn content_rect(self: *const Widget) RectPixels {
            const rect = self.computed.rect();
            return RectPixels {
                .left = rect.left + self.padding_px.left,
                .top = rect.top + self.padding_px.top,
                .width = rect.width - self.padding_px.left - self.padding_px.right,
                .height = rect.height - self.padding_px.top - self.padding_px.bottom,
            };
        }
    };

    pub fn WidgetSignal(comptime T: type) type {
        return struct {
            clicked: bool = false,
            hover: bool = false,
            dragged: bool = false,
            data_changed: bool = false,
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

        pub fn slate() Palette {
            @setEvalBranchQuota(10000);
            return Palette {
               .text_light = zm.srgbToRgb(zm.f32x4(248.0/255.0, 250.0/255.0, 252.0/255.0, 1.0)), 
               .text_dark = zm.srgbToRgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, 1.0)),
               .primary = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(222.2/360.0, 0.474, 0.112, 1.0))),
               .border = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(214.3/360.0, 0.318, 0.914, 1.0))),
               .background = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(0.0/360.0, 0.0, 1.0, 1.0))),
               .foreground = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(222.2/360.0, 0.84, 0.049, 1.0))),
               .muted = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(210.0/360.0, 0.4, 0.961, 1.0))),
               .secondary = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(210.0/360.0, 0.4, 0.961, 1.0))),
               .accent = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(210.0/360.0, 0.4, 0.961, 1.0))),
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

    const LabelKey: Key = std.hash.XxHash64.hash(0, "Imuilabel");

    const WidgetLocation = enum(u1) {
        Standard,
        Priority,
    };
    const WidgetId = packed struct(u32) {
        location: WidgetLocation,
        index: u31,
    };

    // hot and active items for the current frame
    hot_item: ?Key = null,
    active_item: ?Key = null,

    // hot and active items for the next frame
    // these are modified during widget creation and set to the current values at render time
    next_hot_item: ?WidgetId = null,
    next_active_item: ?WidgetId = null,

    input: *const in.InputState,
    time: *const tm.TimeState,
    window: *const platform.Window,

    primary_interact_key: in.KeyCode = in.KeyCode.MouseLeft,
    quad_renderer: QuadRenderer,
    fonts: [@intFromEnum(FontEnum.Count)]font.Font,

    parent_stack: std.ArrayList(WidgetId),
    palette_stack: std.ArrayList(Palette),

    widgets: std.ArrayList(Widget),
    // widgets within the priority array will always be rendered on top of standard widgets and will
    // demand interactions over standard widgets. This is useful for things like dropdown or context menus.
    priority_widgets: std.ArrayList(Widget),
    last_frame_widgets: std.AutoHashMap(Key, Widget),

    last_frame_arena: u8,
    arenas: [2]std.heap.ArenaAllocator,

    scuffed_x_checkbox_image: _gfx.TextureView2D,
    image_sampler: _gfx.Sampler,

    pub fn deinit(self: *Self) void {
        for (&self.fonts) |*f| {
            f.deinit();
        }
        self.quad_renderer.deinit();

        self.palette_stack.deinit();
        self.parent_stack.deinit();
        self.widgets.deinit();
        self.priority_widgets.deinit();
        self.last_frame_widgets.deinit();

        self.scuffed_x_checkbox_image.deinit();
        self.image_sampler.deinit();

        for (self.arenas) |a| {
            a.deinit();
        }
    }

    pub fn init(alloc: std.mem.Allocator, input: *const in.InputState, time: *const tm.TimeState, window: *const platform.Window, gfx: *_gfx.GfxState) !Self {
        var scuffed_x_image = try zstbi.Image.loadFromFile("res/scuffed_x.png", 4);
        defer scuffed_x_image.deinit();

        var scuffed_x_checkbox_image = try _gfx.Texture2D.init(
            .{
                .width = scuffed_x_image.width,
                .height = scuffed_x_image.height,
                .format = _gfx.TextureFormat.Rgba8_Unorm_Srgb,
            },
            .{ .ShaderResource = true, },
            .{},
            scuffed_x_image.data,
            gfx
        );
        defer scuffed_x_checkbox_image.deinit();
        
        var scuffed_x_checkbox_image_view = try _gfx.TextureView2D.init_from_texture2d(
            &scuffed_x_checkbox_image,
            gfx
        );
        errdefer scuffed_x_checkbox_image_view.deinit();

        // Initialize fonts
        var fonts: [@intFromEnum(FontEnum.Count)]font.Font = [_]font.Font{undefined} ** @intFromEnum(FontEnum.Count);
        for (0..@intFromEnum(FontEnum.Count)) |idx| {
            const font_enum = @as(FontEnum, @enumFromInt(idx));
            const font_paths = font_enum.font_paths();
            const font_obj = try font.Font.init(
                alloc,
                font_paths.json,
                font_paths.png,
                gfx
            );
            fonts[idx] = font_obj;
        }

        var self = Self {
            .input = input,
            .time = time,
            .window = window,
            .parent_stack = std.ArrayList(WidgetId).init(alloc),
            .palette_stack = std.ArrayList(Palette).init(alloc),
            .widgets = std.ArrayList(Widget).init(alloc),
            .priority_widgets = std.ArrayList(Widget).init(alloc),
            .last_frame_widgets = std.AutoHashMap(Key, Widget).init(alloc),
            .scuffed_x_checkbox_image = scuffed_x_checkbox_image_view,
            .image_sampler = try _gfx.Sampler.init(.{}, gfx),
            .last_frame_arena = 0,
            .arenas = [_]std.heap.ArenaAllocator{
                std.heap.ArenaAllocator.init(alloc),
                std.heap.ArenaAllocator.init(alloc),
            },
            .quad_renderer = try QuadRenderer.init(gfx),
            .fonts = fonts,
        };
        self.add_root_widget(gfx);
        return self;
    }

    pub fn get_font(self: *const Self, font_enum: FontEnum) *const font.Font {
        return &self.fonts[@intFromEnum(font_enum)];
    }

    pub fn render_text(
        self: *const Self,
        font_enum: FontEnum,
        text: []const u8,
        props: font.Font.FontRenderProperties2D,
        rtv: _gfx.RenderTargetView, 
        gfx: *_gfx.GfxState,
    ) void {
        self.get_font(font_enum).render_text_2d(
            text, props, rtv, gfx
        );
    }

    fn arena(self: *Self) *std.heap.ArenaAllocator {
        return &self.arenas[(@as(usize, @intCast(self.last_frame_arena)) + 1) % 2];
    }

    pub fn palette(self: *const Self) Palette {
        return self.palette_stack.getLastOrNull() orelse Palette.default_palette;
    }

    fn add_heirarchy_links(self: *Self, parent_id: WidgetId, widget_id: WidgetId) !void {
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

    fn apply_padding(widget: *Widget, axis: usize) void {
        switch (axis) {
            0 => widget.computed.size[0] += @floatFromInt(widget.padding_px.left + widget.padding_px.right),
            1 => widget.computed.size[1] += @floatFromInt(widget.padding_px.top + widget.padding_px.bottom),
            else => {}
        }
    }

    fn compute_standalone_widget_size(self: *Self, widget: *Widget) void {
        for (widget.semantic_size, 0..) |s, axis| {
            switch (s.kind) {
                .Pixels => {
                    widget.computed.size[axis] = s.value;
                    apply_padding(widget, axis);
                    widget.computed.size[axis] = @max(widget.computed.size[axis], s.minimum_pixel_size);
                },
                .TextContent => {
                    if (widget.text_content) |*text| {
                        const text_bounds = self.get_font(text.font).text_bounds_2d_pixels(
                            text.text,
                            text.size
                        );
                        switch (axis) {
                            0 => widget.computed.size[0] = @floatFromInt(text_bounds.width),
                            1 => widget.computed.size[1] = @as(f32,@floatFromInt(text_bounds.height)) - self.get_font(text.font).font_metrics.descender,
                            else => {unreachable;}
                        }
                    } else {
                        std.log.warn("widget with size kind \"Text Content\" does not have any text content.", .{});
                    }
                    apply_padding(widget, axis);
                    widget.computed.size[axis] = @max(widget.computed.size[axis], s.minimum_pixel_size);
                },
                else => {},
            }
        }
    }

    pub fn add_widget_priority(self: *Self, widget: Widget) WidgetId {
        var widget_to_add = widget;
        // we need to own the text content so duplicate it using this frame's arena before adding the widget
        if (widget_to_add.text_content) |*text| {
            text.text = self.arena().allocator().dupe(u8, text.text) catch unreachable;
        }

        const parent_id = self.parent_stack.getLast();

        const widget_index = self.priority_widgets.items.len;
        self.priority_widgets.append(widget_to_add) catch unreachable;
        const widget_id = WidgetId {
            .location = .Priority,
            .index = @truncate(widget_index),
        };

        self.add_heirarchy_links(parent_id, widget_id) catch unreachable;
        return widget_id;
    }

    pub fn add_widget(self: *Self, widget: Widget) WidgetId {
        var widget_to_add = widget;
        // we need to own the text content so duplicate it using this frame's arena before adding the widget
        if (widget_to_add.text_content) |*text| {
            text.text = self.arena().allocator().dupe(u8, text.text) catch unreachable;
        }

        const parent_id = self.parent_stack.getLast();

        const widget_id = blk: {
            switch (parent_id.location) {
                .Standard => {
                    @branchHint(.likely);
                    const widget_index = self.widgets.items.len;
                    self.widgets.append(widget_to_add) catch unreachable;
                    break :blk WidgetId {
                        .location = .Standard,
                        .index = @truncate(widget_index),
                    };
                },
                .Priority => {
                    @branchHint(.unlikely);
                    const widget_index = self.priority_widgets.items.len;
                    self.priority_widgets.append(widget_to_add) catch unreachable;
                    break :blk WidgetId {
                        .location = .Priority,
                        .index = @truncate(widget_index),
                    };
                },
            }
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

    pub fn has_focus(self: *const Self) bool {
        return self.hot_item != null or self.active_item != null;
    }

    pub fn get_widget(self: *Self, widget_id: WidgetId) ?*Widget {
        switch (widget_id.location) {
            .Standard => {
                @branchHint(.likely);
                if (widget_id.index >= self.widgets.items.len) { return null; }
                return &self.widgets.items[widget_id.index];
            },
            .Priority => {
                @branchHint(.unlikely);
                if (widget_id.index >= self.priority_widgets.items.len) { return null; }
                return &self.priority_widgets.items[widget_id.index];
            },
        }
    }

    pub fn get_widget_from_last_frame(self: *Self, widget_id: WidgetId) ?*const Widget {
        const widget = self.get_widget(widget_id) orelse return null;
        return self.last_frame_widgets.getPtr(widget.key);
    }

    fn add_root_widget(self: *Self, gfx: *const _gfx.GfxState) void {
        std.debug.assert(self.widgets.items.len == 0);
        self.widgets.append(Widget {
            .semantic_size = [_]SemanticSize{.{.kind = .None, .value = 0.0, }} ** 2,
            .key = gen_key(.{@src()}),
            .computed = .{
                .relative_position = .{0.0, 0.0},
                .size = .{
                    @floatFromInt(gfx.swapchain_size.width), 
                    @floatFromInt(gfx.swapchain_size.height)
                },
            },
            .flags = .{
                .render = false,
                .allows_overflow_x = false,
                .allows_overflow_y = false,
            },
        }) catch unreachable;
        self.parent_stack.append(.{ .location = .Standard, .index = 0 }) catch unreachable;
    }

    fn solve_upward_dependant_sizes(self: *Self, widget: *Widget) void {
        const parent = self.get_widget(widget.parent) orelse unreachable;
        for (widget.semantic_size, 0..) |s, axis| {
            switch (s.kind) {
                .ParentPercentage => {
                    switch (axis) {
                        @intFromEnum(Axis.X) => widget.computed.size[axis] = @as(f32, @floatFromInt(parent.content_rect().width)) * s.value,
                        @intFromEnum(Axis.Y) => widget.computed.size[axis] = @as(f32, @floatFromInt(parent.content_rect().height)) * s.value,
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

                top_size = @max(child.computed.size[axis], top_size);
                total_size += child.computed.size[axis] + widget.children_gap;
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
            const parent_content_size = [2]f32{@floatFromInt(parent_content_rect.width), @floatFromInt(parent_content_rect.height)};
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
            @floatFromInt(parent_content_rect.left),
            @floatFromInt(parent_content_rect.top)
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
                            widget.computed.relative_position[axis] = prev.computed.relative_position[axis] + prev.computed.size[axis] + parent.children_gap;
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
                @floatFromInt(parent_content_rect.width),
                @floatFromInt(parent_content_rect.height)
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
            widget.computed.offset_position[axis] = widget.computed.relative_position[axis] 
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
        for (0..self.widgets.items.len) |inv_id| {
            const id = self.widgets.items.len - inv_id - 1;
            const widget = &self.widgets.items[id];
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
        for (self.widgets.items, 0..) |*widget, widget_id| {
            std.debug.assert(widget.parent.index <= widget_id);
            self.solve_upward_dependant_sizes(widget);
        }
        for (self.priority_widgets.items, 0..) |*widget, widget_id| {
            std.debug.assert(widget.parent.location == .Standard or widget.parent.index <= widget_id);
            self.solve_upward_dependant_sizes(widget);
        }

        // downward solve again to resolve any ParentPercentage under ChildrenSize
        for (0..self.widgets.items.len) |inv_id| {
            const id = self.widgets.items.len - inv_id - 1;
            const widget = &self.widgets.items[id];
            self.solve_downward_dependant_sizes(widget);
        }
        for (0..self.priority_widgets.items.len) |inv_id| {
            const id = self.priority_widgets.items.len - inv_id - 1;
            const widget = &self.priority_widgets.items[id];
            self.solve_downward_dependant_sizes(widget);
        }

        self.recurse_resolve_violations(.{ .location = .Standard, .index = 0 });
    }

    fn render_imui_widget(self: *Self, rtv: *_gfx.RenderTargetView, widget: *const Widget, scissor_rect: RectPixels) void {
        // render rect
        const render_rect = 
            widget.background_colour != null or
            widget.border_colour != null or
            widget.texture != null;
        
        const scissor = _gfx.RectPixels {
            .left = scissor_rect.left,
            .width = scissor_rect.width,
            .top = scissor_rect.top,
            .height = scissor_rect.height,
        };
        engine.engine().gfx.cmd_set_scissor_rect(scissor);
        defer engine.engine().gfx.cmd_set_scissor_rect(null);

        if (render_rect) {
            var background_colour = zm.f32x4s(1.0);
            if (widget.background_colour) |bc| {
                background_colour = bc;
            }

            var border_colour = zm.f32x4s(1.0);
            if (widget.border_colour) |bc| {
                border_colour = bc;
            }

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

            var colour = blk: { 
                const debug_colours = false;
                if (debug_colours) {
                    if (self.active_item) |ai| { 
                        if (ai == widget.key) {
                            break :blk zm.f32x4(1.0, 0.0, 0.0, 1.0);
                        }
                    } 
                    if (self.hot_item) |hi| {
                        if (hi == widget.key) {
                            break :blk zm.f32x4(0.0, 1.0, 0.0, 1.0);
                        }
                    }
                }
                break :blk background_colour;
            };

            if (widget.flags.hover_effect) {
                // TODO: find a better way of doing hover colouring
                if (background_colour[3] == 0.0) {
                    colour = background_colour;
                    colour[3] = es.ease_out_expo(widget.hot_t) * 0.2;
                } else {
                    colour += zm.f32x4(0.2, 0.2, 0.2, 0.0) * zm.f32x4s(es.ease_out_expo(widget.hot_t)) * if (background_colour[0] > 0.5) zm.f32x4s(-1.0) else zm.f32x4s(1.0);
                }
            }

            self.quad_renderer.render_quad(
                widget.computed.rect(),
                .{
                    .colour = colour,
                    .border_colour = border_colour,
                    .border_width_px = widget.border_width_px,
                    .corner_radii_px = widget.corner_radii_px,
                    .texture = quad_texture_props,
                },
                rtv.*,
                &engine.engine().gfx
            );
        }

        // render text
        if (widget.text_content) |*text| {
            const text_size_f32: f32 = @floatFromInt(text.size);
            const font_metrics = self.get_font(text.font).font_metrics;
            const x: i32 = @intFromFloat(widget.computed.offset_position[0]);
            const top: i32 = @as(i32, @intFromFloat(widget.computed.offset_position[1] + (font_metrics.ascender * text_size_f32)));
            const y: i32 = top;
            self.render_text(
                text.font,
                text.text,
                .{
                    .position = .{ .x = x, .y = y, },
                    .colour = text.colour,
                    .pixel_height = text.size,
                },
                rtv.*,
                &engine.engine().gfx
            );
        }
    }

    fn render_imui_recursive(self: *Self, rtv: *_gfx.RenderTargetView, widget_id: WidgetId, parent_scissor: RectPixels) void {
        const widget = self.get_widget(widget_id).?;

        const widget_scissor = blk: {
            var widget_scissor = parent_scissor;
            // // clamp widget scissor to parent scissor
            // widget_scissor.left = @max(widget_scissor.left, parent_scissor.left);
            // widget_scissor.top = @max(widget_scissor.top, parent_scissor.top);
            // widget_scissor.width = @min(widget_scissor.left + widget_scissor.width, parent_scissor.left + parent_scissor.width) - widget_scissor.left;
            // widget_scissor.height = @min(widget_scissor.top + widget_scissor.height, parent_scissor.top + parent_scissor.height) - widget_scissor.top;

            // expand scissor if overflow is allowed
            const swapchain_size = engine.engine().gfx.swapchain_size;
            if (widget.flags.allows_overflow_x) {
                widget_scissor.width = swapchain_size.width;
                widget_scissor.left = 0;
            }
            if (widget.flags.allows_overflow_y) {
                widget_scissor.height = swapchain_size.height;
                widget_scissor.top = 0;
            }

            break :blk widget_scissor;
        };

        const widget_content_scissor = blk: {
            var scissor = widget.content_rect();
            // clamp widget scissor to parent scissor
            scissor.left = @max(scissor.left, parent_scissor.left);
            scissor.top = @max(scissor.top, parent_scissor.top);
            scissor.width = @min(scissor.left + scissor.width, parent_scissor.left + parent_scissor.width) - scissor.left;
            scissor.height = @min(scissor.top + scissor.height, parent_scissor.top + parent_scissor.height) - scissor.top;

            // expand scissor if overflow is allowed
            const swapchain_size = engine.engine().gfx.swapchain_size;
            if (widget.flags.allows_overflow_x) {
                scissor.width = swapchain_size.width;
                scissor.left = 0;
            }
            if (widget.flags.allows_overflow_y) {
                scissor.height = swapchain_size.height;
                scissor.top = 0;
            }

            break :blk scissor;
        };

        if (widget.flags.render) {
            self.render_imui_widget(rtv, widget, widget_scissor);
        }

        // // debug wireframe
        // self.quad_renderer.render_quad(
        //     widget.computed.rect(),
        //     .{
        //         .colour = zm.f32x4(0.0, 0.0, 1.0, 1.0),
        //         .wireframe = true,
        //     },
        //     rtv.*,
        //     &engine.engine().gfx
        // );

        if (widget.first_child) |c| {
            self.render_imui_recursive(rtv, c, widget_content_scissor);
        }
        if (widget.next_sibling) |s| {
            self.render_imui_recursive(rtv, s, parent_scissor);
        }
    }

    pub fn render_imui(self: *Self, rtv: *_gfx.RenderTargetView, gfx: *_gfx.GfxState) void {
        // widget rects must be computed before rendering
        self.compute_widget_rects();
        
        _ = gfx;
        const screen_scissor = RectPixels {
            .left = 0,
            .top = 0,
            .width = engine.engine().gfx.swapchain_size.width,
            .height = engine.engine().gfx.swapchain_size.height,
        };
        self.render_imui_recursive(rtv, .{ .location = .Standard, .index = 0 }, screen_scissor);
        if (self.priority_widgets.items.len > 0) {
            self.render_imui_recursive(rtv, .{ .location = .Priority, .index = 0 }, screen_scissor);
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

        // fill last frame widgets with widgets from current frame
        self.last_frame_widgets.clearRetainingCapacity();
        for (self.widgets.items) |w| {
            if (w.key != Self.LabelKey) {
                std.debug.assert(!self.last_frame_widgets.contains(w.key)); // widget key is getting squashed. This may mean two or more widgets have the same key.
                self.last_frame_widgets.put(w.key, w) catch unreachable;
            }
        }
        self.widgets.clearRetainingCapacity();
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

        if (last_frame_widget) |lfw| {
            const lfw_contains_cursor = lfw.computed.rect().contains(self.input.cursor_position);

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
            combined.clicked = combined.clicked or s.clicked;
            combined.hover = combined.hover or s.hover;
            combined.dragged = combined.dragged or s.dragged;
            combined.data_changed = combined.data_changed or s.data_changed;
        }

        return combined;
    }

    pub fn push_pallete(self: *Self, p: Palette) void {
        self.palette_stack.append(p);
    }

    pub fn pop_pallete(self: *Self) void {
        _ = self.palette_stack.pop();
    }

    pub fn push_layout_widget_priority(self: *Self, widget: Widget) WidgetId {
        const widget_id = self.add_widget_priority(widget);
        self.parent_stack.append(widget_id) catch unreachable;
        return widget_id;
    }

    pub fn push_layout_widget(self: *Self, widget: Widget) WidgetId {
        const widget_id = self.add_widget(widget);
        self.parent_stack.append(widget_id) catch unreachable;
        return widget_id;
    }

    pub fn push_layout_id(self: *Self, widget_id: WidgetId) void {
        std.debug.assert(self.get_widget(widget_id) != null);
        self.parent_stack.append(widget_id) catch unreachable;
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
        const widget_id = self.add_widget_priority(widget);
        self.push_layout_id(widget_id);
        return widget_id;
    }

    pub fn push_floating_layout(self: *Self, layout_axis: Axis, floating_x: f32, floating_y: f32, key: anytype) WidgetId {
        const widget = Self.floating_layout_widget(layout_axis, floating_x, floating_y, key);
        const widget_id = self.add_widget(widget);
        self.push_layout_id(widget_id);
        return widget_id;
    }

    pub fn pop_layout(self: *Self) void {
        _ = self.parent_stack.pop();
    }

    pub fn label(self: *Self, text: []const u8) WidgetSignal(WidgetId) {
        const widget = Widget {
            .key = Self.LabelKey,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 0.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = text,
                .colour = self.palette().text_dark,
            },
            .background_colour = zm.f32x4s(0.0),
            .border_colour = zm.f32x4s(0.0),
            .anchor = .{ 0.0, 0.5 },
            .pivot = .{ 0.0, 0.5 },
        };

        const widget_id = self.add_widget(widget);
        return self.generate_widget_signals(widget_id);
    }

    pub const ButtonId = struct {
        box: WidgetId,
        text: WidgetId,
    };

    pub fn button(self: *Self, text: []const u8, key: anytype) WidgetSignal(ButtonId) {
        const box_layout = self.push_layout(.X, key ++ .{@src().line});
        defer self.pop_layout();

        if (self.get_widget(box_layout)) |w| {
            w.layout_axis = null;
            w.background_colour = self.palette().primary;
            w.border_colour = self.palette().border;
            w.border_width_px = 1;
            w.padding_px = .{
                .left = 16,
                .right = 16,
                .top = 8,
                .bottom = 8,
            };
            w.corner_radii_px = .{
                .top_left = 6,
                .top_right = 6,
                .bottom_left = 6,
                .bottom_right = 6,
            };
            w.flags.clickable = true;
            w.flags.render = true;
        }

        const label_id = self.label(text);
        if (self.get_widget(label_id.id)) |text_widget| {
            text_widget.text_content.?.colour = self.palette().text_light;
            text_widget.anchor = .{0.5, 0.5};
            text_widget.pivot = .{0.5, 0.5};
        }

        return combine_signals(
            .{
                self.generate_widget_signals(box_layout),
                label_id,
            },
            ButtonId{ .box = box_layout, .text = label_id.id, }
        );
    }

    pub fn badge(self: *Self, text: []const u8, key: anytype) WidgetSignal(ButtonId) {
        const button_sig = self.button(text, key);
        if (self.get_widget(button_sig.id.box)) |w| {
            w.padding_px = .{
                .left = 10,
                .right = 10,
                .top = 2,
                .bottom = 2,
            };
        }
        return button_sig;
    }

    pub const CheckboxId = struct {
        box: WidgetId, 
        text: WidgetId,
    };

    pub fn checkbox(self: *Self, checked: *bool, text: []const u8, key: anytype) WidgetSignal(CheckboxId) {
        const l = self.push_layout(.X, key ++ .{@src().line});
        if (self.get_widget(l)) |lw| {
            lw.children_gap = 8;
        }

        const box_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .Pixels , .value = 16.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            },
            .background_colour = blk: {if (checked.*) { break :blk self.palette().primary; } else { break :blk zm.f32x4s(0.0); }},
            .border_colour = self.palette().primary,
            .border_width_px = 1,
            .corner_radii_px = .{
                .top_left = 4,
                .top_right = 4,
                .bottom_left = 4,
                .bottom_right = 4,
            },
            .texture = blk: { 
                if (checked.*) { 
                    break :blk .{
                        .texture_view = self.scuffed_x_checkbox_image,
                        .sampler = self.image_sampler,
                    };
                } else {
                    break :blk null;
                }
            },
            .flags = .{
                .clickable = true,
            },
        };
        const box_widget_id = self.add_widget(box_widget);
        const box_widget_signals = self.generate_widget_signals(box_widget_id);

        const text_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = text,
                .colour = self.palette().text_dark,
            },
            .background_colour = zm.f32x4s(0.0),
            .border_colour = zm.f32x4s(0.0),
            .flags = .{ 
                .clickable = true, 
            },
            .anchor = .{ 0.0, 0.5 },
            .pivot = .{ 0.0, 0.5 },
        };
        const text_widget_id = self.add_widget(text_widget);
        const text_widget_signals = self.generate_widget_signals(text_widget_id);

        self.pop_layout();

        var combined_signals = combine_signals(
            .{
                box_widget_signals, 
                text_widget_signals, 
            },
            CheckboxId{ .box = box_widget_id, .text = text_widget_id, }
        );

        // checkbox behaviour
        if (combined_signals.clicked) {
            checked.* = !checked.*;
            combined_signals.data_changed = true;
        }

        return combined_signals;
    }

    pub fn collapsible(self: *Self, is_open: *bool, text: []const u8, key: anytype) WidgetSignal(WidgetId) {
        const l = self.push_layout(.X, key ++ .{@src()});
        if (self.get_widget(l)) |lw| {
            lw.semantic_size[0].kind = .ParentPercentage;
            lw.semantic_size[0].value = 1.0;
            lw.children_gap = 8;
            lw.flags.clickable = true;
            lw.flags.render = true;
        }
        var l_interaction = self.generate_widget_signals(l);

        _ = self.label(if (is_open.*) "▼" else "▶");
        _ = self.label(text);
        _ = self.add_widget(Widget {
            .key = Self.LabelKey,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .Pixels, .value = 1.0, .shrinkable_percent = 0.0, },
            },
            .background_colour = self.palette().border,
            .flags = .{
                .render = true,
            },
            .anchor = .{0.0, 0.5},
            .pivot = .{0.0, 0.5},
        });

        self.pop_layout();

        // behaviour
        if (l_interaction.clicked) {
            is_open.* = !is_open.*;
            l_interaction.data_changed = true;
        }

        return l_interaction;
    }

    pub const SliderId = struct {
        filled_bar: WidgetId, 
        background_bar: WidgetId,
        middle_dot: WidgetId,
    };

    pub const SliderOptions = struct {
        min: f32 = 0.0,
        max: f32 = 1.0,
        step: f32 = 1.0,
    };

    pub fn slider(self: *Self, value: *f32, options: SliderOptions, key: anytype) WidgetSignal(SliderId) {
        const complete_percent = std.math.clamp((value.* - options.min) / (options.max - options.min), 0.0, 1.0);
        const box = self.push_layout(.X, key ++ .{@src().line});
        if (self.get_widget(box)) |bw| {
            bw.semantic_size[0].kind = .ParentPercentage;
            bw.semantic_size[0].value = 1.0;
            bw.semantic_size[1].kind = .Pixels;
            bw.semantic_size[1].value = 16.0;
            bw.flags.render = false;
            bw.anchor = .{ 0.0, 0.0 };
            bw.pivot = .{ 0.0, 0.0 };
        }

        const filled_bar_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .ParentPercentage, .value = complete_percent, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 8.0, .shrinkable_percent = 0.0, },
            },
            .background_colour = self.palette().primary,
            .border_colour = self.palette().primary,
            .border_width_px = 1,
            .corner_radii_px = .{
                .top_left = 4,
                .top_right = 4,
                .bottom_left = 4,
                .bottom_right = 4,
            },
            .flags = .{
                .clickable = true,
                .hover_effect = false,
            },
            .anchor = .{0.0, 0.5},
            .pivot = .{0.0, 0.5},
        };
        const filled_bar_widget_id = self.add_widget(filled_bar_widget);

        const l1 = self.push_layout(.X, key ++ .{@src().line});
        if (self.get_widget(l1)) |lw| {
            lw.semantic_size[0].kind = .ParentPercentage;
            lw.semantic_size[0].value = (1.0 - complete_percent);
            lw.semantic_size[1].kind = .ParentPercentage;
            lw.semantic_size[1].value = 1.0;
            lw.flags.render = false;
            lw.layout_axis = null;
        }

        const empty_bar_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 8.0, .shrinkable_percent = 0.0, },
            },
            .flags = .{
                .render = true,
                .hover_effect = false,
                .clickable = true,
            },
            .background_colour = self.palette().primary * zm.f32x4(1.0, 1.0, 1.0, 0.2),
            .border_colour = self.palette().border,
            .border_width_px = 1,
            .corner_radii_px = .{
                .top_left = 4,
                .top_right = 4,
                .bottom_left = 4,
                .bottom_right = 4,
            },
            .anchor = .{0.0, 0.5},
            .pivot = .{0.0, 0.5},
        };
        const empty_bar_widget_id = self.add_widget(empty_bar_widget);

        const middle_dot_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            },
            .flags = .{
                .render = true,
                .clickable = true,
                .allows_overflow_x = true,
                .allows_overflow_y = true,
            },
            .background_colour = self.palette().background,
            .border_colour = self.palette().primary,
            .border_width_px = 1,
            .corner_radii_px = .{
                .top_left = 8,
                .top_right = 8,
                .bottom_left = 8,
                .bottom_right = 8,
            },
            .anchor = .{0.0, 0.5},
            .pivot = .{0.5, 0.5},
        };
        const middle_dot_widget_id = self.add_widget(middle_dot_widget);

        self.pop_layout(); // l1
        self.pop_layout();

        var signals = combine_signals(
            .{
                self.generate_widget_signals(filled_bar_widget_id),
                self.generate_widget_signals(empty_bar_widget_id),
                self.generate_widget_signals(middle_dot_widget_id),
            },
            SliderId{ .filled_bar = filled_bar_widget_id, .background_bar = box, .middle_dot = middle_dot_widget_id, }
        );

        if (signals.dragged) {
            if (self.get_widget_from_last_frame(signals.id.background_bar)) |b| {
                const pixel_width: f32 = @floatFromInt(b.content_rect().width);
                const percent = @as(f32, @floatFromInt(self.input.cursor_position[0] - b.computed.rect().left)) / pixel_width;
                const a = std.math.round((1.0 / options.step) * percent * (options.max - options.min)) * options.step;
                value.* = std.math.clamp(a + options.min, options.min, options.max);
                signals.data_changed = true;
            }
        }

        return signals;
    }

    pub const TextInputState = struct {
        cursor: usize = 0,
        mark: usize = 0,
        text: std.ArrayList(u8),

        pub fn deinit(self: *TextInputState) void {
            self.text.deinit();
        }

        pub fn init(allocator: std.mem.Allocator) TextInputState {
            return TextInputState {
                .text = std.ArrayList(u8).init(allocator),
            };
        }
    };

    pub const TextInputId = struct {
        box: WidgetId,
        text: WidgetId,
    };

    fn character_advance_at_cursor(self: *Self, text_input_widget: *const Widget, text_input_state: *const TextInputState) i32 {
        if (text_input_state.cursor == 0) { return 0; }
        const f = self.get_font(text_input_widget.text_content.?.font);
        return @intFromFloat(
            f.character_map.get(text_input_state.text.items[text_input_state.cursor - @intFromBool(text_input_state.cursor > 0)]).?.advance *  // TODO handle error
            @as(f32, @floatFromInt(text_input_widget.text_content.?.size))
        );
    }

    pub fn line_edit(self: *Self, state: *TextInputState, key: anytype) WidgetSignal(TextInputId) {
        const font_to_use = FontEnum.GeistMono;

        // Background box, stack children
        const l = self.push_layout(.X, key ++ .{@src()});
        if (self.get_widget(l)) |lw| {
            lw.flags.render = true;
            lw.flags.clickable = true;
            lw.flags.hover_effect = false;
            lw.semantic_size[0].kind = .ParentPercentage;
            lw.semantic_size[0].value = 1.0;
            lw.semantic_size[0].shrinkable_percent = 1.0;
            lw.semantic_size[1].kind = .Pixels;
            lw.semantic_size[1].value = 16.0;
            lw.background_colour = self.palette().secondary;
            lw.border_colour = self.palette().border;
            lw.border_width_px = 1;
            lw.padding_px = .{
                .left = 4,
                .right = 4,
                .top = 4,
                .bottom = 4,
            };
            lw.corner_radii_px = .{
                .top_left = 4,
                .top_right = 4,
                .bottom_left = 4,
                .bottom_right = 4,
            };
        }

        const content_box = self.push_layout(.X, key ++ .{@src()});
        if (self.get_widget(content_box)) |content_box_widget| {
            content_box_widget.layout_axis = null;

            content_box_widget.semantic_size[0].kind = .ParentPercentage;
            content_box_widget.semantic_size[0].value = 1.0;
            content_box_widget.semantic_size[1].kind = .ParentPercentage;
            content_box_widget.semantic_size[1].value = 1.0;
        }

        // Text to render
        const text_input_widget = Widget {
            .key = gen_key(key ++ .{@src()}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 1.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .TextContent, .value = 1.0, .shrinkable_percent = 0.0, },
            },
            .text_content = .{
                .font = font_to_use,
                .text = state.text.items,
                .colour = self.palette().text_dark,
            },
            .background_colour = zm.f32x4s(0.0),
            .border_colour = zm.f32x4s(0.0),
            .border_width_px = 1,
            .corner_radii_px = .{
                .top_left = 4,
                .top_right = 4,
                .bottom_left = 4,
                .bottom_right = 4,
            },
            .flags = .{
                .clickable = true,
            },
        };
        const text_input_widget_id = self.add_widget(text_input_widget);

        // ensure data is in a valid state
        state.cursor = @min(state.cursor, state.text.items.len);
        state.mark = @min(state.mark, state.text.items.len);

        // Generate signals
        const box_signals = self.generate_widget_signals(l);
        const text_signals = self.generate_widget_signals(text_input_widget_id);

        const line_edit_is_hot_widget = self.any_of_widgets_is_hot(&.{ 
            self.get_widget(box_signals.id).?.key, 
            self.get_widget(text_signals.id).?.key
        });

        var l_sel = @min(state.cursor, state.mark);
        const r_sel = @max(state.cursor, state.mark);
        const f = self.get_font(text_input_widget.text_content.?.font);

        // Cursor (and selection box)
        // Push invisible spacer box to until start of selection
        _ = self.push_layout(.X, key ++ .{@src()});
        var phantom_text = text_input_widget;
        phantom_text.key = gen_key(key ++ .{@src()});
        phantom_text.flags.render = false;
        phantom_text.text_content.?.text = state.text.items[0..l_sel];
        _ = self.add_widget(phantom_text);

        // render cursor and selection box
        const selection_bounds = f.text_bounds_2d_pixels(
            state.text.items[l_sel..r_sel],
            text_input_widget.text_content.?.size
        );
        const cursor_min_width = 1.0;
        const cursor = Widget {
            .key = gen_key(key ++ .{@src()}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .Pixels, .value = @as(f32, @floatFromInt(selection_bounds.width)) + cursor_min_width, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = @as(f32, @floatFromInt(selection_bounds.height)), .shrinkable_percent = 0.0, },
            },
            .background_colour = self.palette().primary * zm.f32x4(1.0, 1.0, 1.0, 0.4 + 0.4 * 
                (std.math.sin(2.0 * std.math.pi * @as(f32, @floatFromInt(@mod(std.time.milliTimestamp(), 1000))) / @as(f32, @floatFromInt(std.time.ms_per_s))) + 1.0) * 0.5),
            .border_colour = zm.f32x4s(0.0),
            .flags = .{
                .render = (line_edit_is_hot_widget or state.cursor != state.mark),
            },
        };
        _ = self.add_widget(cursor);
        self.pop_layout(); // phantom and cursor

        self.pop_layout(); // content box
        self.pop_layout(); // background box

        var data_has_changed = false;

        // Handle mouse input, click and drag
        if (box_signals.dragged or text_signals.dragged or box_signals.clicked or text_signals.clicked) {
            const cursor_pos = [2]i32{self.input.cursor_position[0], self.input.cursor_position[1]};
            const text_rel_pos = self.get_widget_from_last_frame(text_input_widget_id).?.computed.relative_position;
            const cursor_in_box_pos = [2]i32 {
                cursor_pos[0] - @as(i32, @intFromFloat(text_rel_pos[0])),
                cursor_pos[1] - @as(i32, @intFromFloat(text_rel_pos[1]))
            };

            // Set cursor to closest character to mouse position
            // by shifting state cursor back and forth
            while (f.text_bounds_2d_pixels(
                state.text.items[0..state.cursor],
                text_input_widget.text_content.?.size
            ).width - @divTrunc(self.character_advance_at_cursor(&text_input_widget, state), 2) < cursor_in_box_pos[0]) {
                if (state.cursor == state.text.items.len) {
                    break;
                }
                state.cursor += 1;
            }
            while (self.get_font(text_input_widget.text_content.?.font).text_bounds_2d_pixels(
                state.text.items[0..state.cursor],
                text_input_widget.text_content.?.size
            ).width - @divTrunc(self.character_advance_at_cursor(&text_input_widget, state), 2) > cursor_in_box_pos[0]) {
                if (state.cursor == 0) {
                    break;
                }
                state.cursor -= 1;
            }
        }
        // if clicked then we set mark to equal cursor instead of manipulating selection
        if (box_signals.clicked or text_signals.clicked) {
            state.mark = state.cursor;
        }

        // Handle keyboard input if hovering
        // @TODO: handle keyboard input if _focused_, not hovering
        if (line_edit_is_hot_widget) {
            for (self.input.char_events) |c| {
                if (c != null) {
                    switch (c.?[0]) {
                        // Backspace (word or character)
                        8, 127 => {
                            data_has_changed = true;
                            if (state.text.items.len > 0) {
                                if (l_sel == r_sel) {
                                    if (c.?[0] == 127) {
                                        // word backspace
                                        l_sel = std.mem.lastIndexOfAny(u8, state.text.items[0..(r_sel-1)], "\n\t ") orelse 0;
                                        if (l_sel != 0) {
                                            l_sel = @min(l_sel + 1, state.text.items.len);
                                        }
                                    } else {
                                        // single char backspace
                                        if (l_sel != 0) { l_sel -= 1; }
                                    }
                                }
                                for (l_sel..r_sel) |_| {
                                    _ = state.text.orderedRemove(l_sel);
                                }
                                state.cursor = l_sel;
                                state.mark = state.cursor;
                            }
                        },
                        // Enter
                        13 => {
                            // single line input so ignore newline
                            // state.text.append('\n') catch {};
                        },
                        // Characters
                        32...126 => {
                            data_has_changed = true;
                            if (c.?[1] == 0) {
                                state.text.insert(state.cursor, c.?[0]) catch {};
                                state.cursor += 1;
                                state.mark = state.cursor;
                            } else {
                                state.text.insertSlice(state.cursor, c.?[0..2]) catch {};
                                state.cursor += 2;
                                state.mark = state.cursor;
                            }
                        },
                        else => {},
                    }
                }
            }

            // Remove selection if escape pressed
            if (self.input.get_key_down(in.KeyCode.Escape)) {
                state.mark = state.cursor;
            }

            // Handle arrow keys
            if (self.input.get_key_down_repeat(in.KeyCode.ArrowLeft)) {
                if (state.cursor > 0) {
                    state.cursor = state.cursor - 1;
                }
                if (!self.input.get_key(in.KeyCode.Shift)) {
                    state.cursor = @min(state.cursor, state.mark);
                    state.mark = state.cursor;
                }
            }
            if (self.input.get_key_down_repeat(in.KeyCode.ArrowRight)) {
                if (state.cursor < state.text.items.len) {
                    state.cursor = state.cursor + 1;
                }
                if (!self.input.get_key(in.KeyCode.Shift)) {
                    state.cursor = @max(state.cursor, state.mark);
                    state.mark = state.cursor;
                }
            }

            // Handle copy
            if (self.input.get_key_down(in.KeyCode.C) and self.input.get_key(in.KeyCode.Control)) {
                if (state.cursor != state.mark) {
                    self.window.copy_string_to_clipboard(state.text.items[@min(state.mark, state.cursor)..@max(state.mark, state.cursor)])
                        catch |err| std.log.err("Failed to copy string to clipboard: {}", .{err});
                }
            }
            // Handle paste
            if (self.input.get_key_down(in.KeyCode.V) and self.input.get_key(in.KeyCode.Control)) {
                if (self.window.get_string_from_clipboard(std.heap.page_allocator)) |clipboard_str| {
                    defer std.heap.page_allocator.free(clipboard_str);

                    // sanitize incoming clipboard string
                    var sanitized = std.heap.page_allocator.dupe(u8, clipboard_str) catch unreachable;
                    defer std.heap.page_allocator.free(sanitized);

                    var sanitized_cursor: usize = 0;
                    for (clipboard_str) |c| {
                        // only allow ascii printable characters
                        if (c >= 32 and c < 127) {
                            sanitized[sanitized_cursor] = c;
                            sanitized_cursor += 1;
                        }
                    }

                    std.log.info("clipboard string: {s}", .{clipboard_str});
                    std.log.info("sanitized string: {s}", .{sanitized});

                    // insert sanitized string into text input
                    state.text.insertSlice(state.cursor, sanitized[0..sanitized_cursor]) catch {};
                    data_has_changed = true;
                    state.cursor += sanitized_cursor;
                    state.mark = state.cursor;
                } else |err| {
                    std.log.err("Failed to get clipboard string {}", .{err});
                }
            }
        }

        // Handle text overflow
        // TODO: SPEED: only do this if data or cursor has changed in the line edit
        blk: {
            const background_widget = self.get_widget_from_last_frame(l) orelse break :blk;
            const content_box_widget = self.get_widget(content_box) orelse break :blk;
            const text_widget = self.get_widget_from_last_frame(text_input_widget_id) orelse break :blk;

            // apply same pixel offset as last frame
            if (self.get_widget_from_last_frame(content_box)) |lfw| {
                content_box_widget.pixel_offset = lfw.pixel_offset;
            }

            // find the cursor position in pixels
            // TODO: SPEED: iterate throgh text a little less
            const cursor_pixel_position = @as(f32, @floatFromInt(f.text_bounds_2d_pixels(
                        state.text.items[0..state.cursor],
                        text_input_widget.text_content.?.size
            ).width + text_widget.computed.rect().left)) + cursor_min_width;

            const background_content = background_widget.content_rect();
            const background_left: f32 = @floatFromInt(background_content.left);
            const background_right: f32 = @floatFromInt(background_content.left + background_content.width);

            const cursor_right: f32 = cursor_pixel_position;
            // shift content box to the left if the cursor is to the left of the background
            if (cursor_right < background_left) {
                content_box_widget.pixel_offset[0] -= cursor_right - background_left;
            }
            // shift content box to the right if the cursor is to the right of the background
            if (cursor_right > background_right) {
                content_box_widget.pixel_offset[0] -= (cursor_right - background_right);
            }

            // clamp so that the last character is always at the right edge of the background 
            // if text is long enough to exceed the background
            const text_width = @as(f32, @floatFromInt(text_widget.computed.rect().width)) + cursor_min_width;
            const offset_min = @min(-(text_width - @as(f32, @floatFromInt(background_content.width))), 0.0);
            content_box_widget.pixel_offset[0] = std.math.clamp(content_box_widget.pixel_offset[0], offset_min, 0.0);
        }

        var signals = combine_signals(
            .{
                box_signals,
                text_signals,
            },
            TextInputId{ .text = text_input_widget_id, .box = l, }
        );
        signals.data_changed = data_has_changed;
        return signals;
    }

    pub fn image(self: *Self, texture_view: _gfx.TextureView2D, sampler: _gfx.Sampler, key: anytype) WidgetSignal(WidgetId) {
        var image_widget = Widget {
            .key = gen_key(key ++ .{@src()}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0, },
            },
            .texture =  .{
                .texture_view = texture_view,
                .sampler = sampler,
            },
            //.background_colour = zm.f32x4(1.0, 0.0, 0.0, 1.0),
            .flags = .{
                .render = true,
            },
        };

        // set size based on parent layout. Fill parent layout axis and keep image aspect ratio.
        if (self.get_widget_from_last_frame(self.parent_stack.getLast())) |parent| {
            if (texture_view.desc.width != 0 and texture_view.desc.height != 0) {
                const aspect_ratio = @as(f32, @floatFromInt(texture_view.desc.width)) / @as(f32, @floatFromInt(texture_view.desc.height));
                if (parent.layout_axis) |layout_axis| {
                    switch (layout_axis) {
                        .X => {
                            image_widget.semantic_size[0].kind = .Pixels;
                            image_widget.semantic_size[0].value = @as(f32, @floatFromInt(parent.content_rect().height)) * aspect_ratio;
                            image_widget.semantic_size[1].kind = .ParentPercentage;
                            image_widget.semantic_size[1].value = 1.0;
                        },
                        .Y => {
                            image_widget.semantic_size[0].kind = .ParentPercentage;
                            image_widget.semantic_size[0].value = 1.0;
                            image_widget.semantic_size[1].kind = .Pixels;
                            image_widget.semantic_size[1].value = @as(f32, @floatFromInt(parent.content_rect().width)) / aspect_ratio;
                        },
                    }
                }
            }
        }

        const image_widget_id = self.add_widget(image_widget);
        return self.generate_widget_signals(image_widget_id);
    }

    pub const ComboBoxData = struct {
        default_text: []const u8,
        can_be_default: bool = true,
        options: []const []const u8,
        selected_index: ?usize = null,
        dropdown_is_open: bool = false,
    };

    fn set_combobox_background_layout(self: *const Self, widget: *Widget) void {
        widget.semantic_size[0] = .{
            .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
        };
        widget.flags.render = true;
        widget.background_colour = self.palette().background;
        widget.border_colour = self.palette().border;
        widget.border_width_px = 1;
        widget.padding_px = .{
            .left = 4,
            .right = 4,
            .top = 4,
            .bottom = 4,
        };
        widget.children_gap = 2;
        widget.corner_radii_px = .{
            .top_left = 4,
            .top_right = 4,
            .bottom_left = 4,
            .bottom_right = 4,
        };
    }

    pub fn combobox(self: *Self, data: *ComboBoxData, key: anytype) WidgetSignal(WidgetId) {
        // ensure data elements are valid
        if (data.selected_index) |*si| { si.* = @min(si.*, data.options.len - 1); }
        if (!data.can_be_default and data.selected_index == null) { data.selected_index = 0; }

        // push the container layout
        const container_layout = self.push_layout(.Y, key ++ .{@src()});
        if (self.get_widget(container_layout)) |container_widget| {
            container_widget.semantic_size[0] = .{
                .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0,
            };
        }
        
        // push the background layout of the primary combobox
        const background = self.push_layout(.X, key ++ .{@src()});
        if (self.get_widget(background)) |background_widget| {
            self.set_combobox_background_layout(background_widget);
            background_widget.flags.clickable = true;
        }

        // check wether the combo box was clicked on, record this
        // so we dont immediately close dropdown options
        var clicked_on_widget: bool = false;
        const background_s = self.generate_widget_signals(background);
        if (background_s.clicked) {
            data.dropdown_is_open = !data.dropdown_is_open;
            clicked_on_widget = true;
        }

        // print the selected label
        {
            const label_layout = self.push_layout(.X, key ++ .{@src()});
            defer self.pop_layout();
            if (self.get_widget(label_layout)) |label_widget| {
                label_widget.layout_axis = null;
                label_widget.semantic_size[0] = .{
                    .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
                };
            }

            const selected_label = if (data.selected_index) |si| data.options[si] else data.default_text;
            _ = self.label(selected_label);
            const arrow_label = self.label("▽");
            if (self.get_widget(arrow_label.id)) |arrow_label_widget| {
                arrow_label_widget.anchor = .{1.0, 0.5};
                arrow_label_widget.pivot = .{1.0, 0.5};
            }
        }
        self.pop_layout(); // background layout

        var new_option_selected = false;

        // if the dropdown should be shown then render it
        dropdown_is_open: { if (data.dropdown_is_open) {
            // determine the position of the dropdown options based on the primary combobox rect
            const dropdown_pos = if (self.get_widget_from_last_frame(background)) |b| 
                .{ b.computed.rect().left, b.computed.rect().top + b.computed.rect().height + 4 }
             else break :dropdown_is_open;

            // push the options background layout
            const options_background = self.push_priority_floating_layout(.Y, @floatFromInt(dropdown_pos[0]), @floatFromInt(dropdown_pos[1]), key ++ .{@src()});
            if (self.get_widget(options_background)) |options_background_widget| {
                self.set_combobox_background_layout(options_background_widget);
                options_background_widget.semantic_size[0] = .{
                    .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
                };
            }

            // push each of the options into the dropdown menu
            for (data.options, 0..) |option, i| {
                const option_background = self.push_layout(.X, key ++ .{@src(), i});
                defer self.pop_layout();

                // give the option a hover effect
                if (self.get_widget(option_background)) |option_background_widget| {
                    option_background_widget.semantic_size[0] = .{
                        .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
                    };
                    option_background_widget.flags.clickable = true;
                    option_background_widget.flags.render = true;
                    option_background_widget.background_colour = self.palette().background;
                    option_background_widget.padding_px = .{
                        .left = 4,
                        .right = 4,
                        .top = 4,
                        .bottom = 4,
                    };
                    option_background_widget.corner_radii_px = .{
                        .top_left = 4,
                        .top_right = 4,
                        .bottom_left = 4,
                        .bottom_right = 4,
                    };
                }

                // if the option is clicked then set the data selected index
                if (self.generate_widget_signals(option_background).clicked) {
                    if (data.selected_index == i) {
                        if (data.can_be_default) {
                            data.selected_index = null;
                        }
                    } else {
                        data.selected_index = i;
                    }
                    new_option_selected = true;
                }
                
                // print the option label with a selected indicator
                if (data.selected_index) |si| {
                    if (i == si) {
                        _ = self.label("▶ ");
                    }
                }
                _ = self.label(option);
            }

            self.pop_layout(); // options background layout
        } }

        self.pop_layout(); // container layout

        // close the dropdown if the mouse is clicked anywhere
        // unless the primary combobox was clicked
        if (!clicked_on_widget and engine.engine().input.get_key_down(engine.input.KeyCode.MouseLeft)) {
            data.dropdown_is_open = false;
        }

        return WidgetSignal(WidgetId) {
            .id = container_layout,
            .data_changed = new_option_selected,
            .hover = false, // TODO
            .clicked = false, // TODO
            .dragged = false, // TODO
        };
    }

    pub const NumberSliderSettings = struct {
        scale: f32 = 0.01,
    };

    pub fn number_slider(self: *Self, value: *f32, settings: NumberSliderSettings, key: anytype) WidgetSignal(WidgetId) {
        const background = self.push_layout(.X, key ++ .{@src()});
        defer self.pop_layout();
        if (self.get_widget(background)) |background_widget| {
            background_widget.semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            };
            background_widget.flags.render = true;
            background_widget.flags.hover_effect = false;
            background_widget.flags.clickable = true;
            background_widget.background_colour = self.palette().muted;
            background_widget.border_colour = self.palette().border;
            background_widget.border_width_px = 1;
            background_widget.corner_radii_px = .{
                .top_left = 4,
                .top_right = 4,
                .bottom_left = 4,
                .bottom_right = 4,
            };
            background_widget.padding_px = .{
                .left = 4,
                .right = 4,
                .top = 4,
                .bottom = 4,
            };
        }
        
        var text_buffer: [32]u8 = undefined;
        const text = self.label(std.fmt.bufPrint(&text_buffer, "{d:.2}", .{value.*}) catch unreachable);
        if (self.get_widget(text.id)) |text_widget| {
            _ = text_widget;
        }

        var background_signals = self.generate_widget_signals(background);
        if (background_signals.dragged) {
            value.* += engine.engine().input.mouse_delta[0] * settings.scale;
            background_signals.data_changed = true;
        }

        return background_signals;
    }
};
