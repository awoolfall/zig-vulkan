const std = @import("std");
const zstbi = @import("zstbi");
const _gfx = @import("../gfx/gfx.zig");
const tm = @import("../engine/time.zig");
const in = @import("../input/input.zig");
const kc = @import("../input/keycode.zig");
const es = @import("../easings.zig");
const zm = @import("zmath");
const path = @import("path.zig");

pub const font = @import("font.zig");

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

    pub fn to_screen_bounds(self: *const RectPixels, max_width: u32, max_height: u32) Bounds {
        const top_left = position_pixels_to_screen_space(self.left, self.top, max_width, max_height);
        const bottom_right = position_pixels_to_screen_space(self.left + self.width, self.top + self.height, max_width, max_height);
        return Bounds {
            .left = top_left[0],
            .top = top_left[1],
            .right = bottom_right[0],
            .bottom = bottom_right[1],
        };
    }
};

pub inline fn position_pixels_to_screen_space(x: i32, y: i32, max_width: u32, max_height: u32) [2]f32 {
    const x_f32: f32 = @floatFromInt(x);
    const y_f32: f32 = @floatFromInt(y);
    const max_width_f32: f32 = @floatFromInt(max_width);
    const max_height_f32: f32 = @floatFromInt(max_height);
    return [2]f32{
        ((x_f32 / max_width_f32) * 2.0) - 1.0,
        -(((y_f32 / max_height_f32) * 2.0) - 1.0)
    };
}

pub const Size = union(enum) {
    Pixels: i32, // 0 -> image width/height
    Screen: f32, // 0.0 (bottom, left) -> 1.0 (top, right)
};

// -1.0 to 1.0, left and bottom of screen is -1.0, right and top is 1.0
pub const Bounds = extern struct {
    left: f32 = 0.0,
    bottom: f32 = 0.0,
    right: f32 = 0.0,
    top: f32 = 0.0,
};

pub const QuadBufferVertexBuffer = extern struct {
    quad_bounds: Bounds = Bounds {},
};

pub const QuadBufferFlags = packed struct(u32) {
    has_texture: bool = false,
    __unused: u31 = 0,
};

pub const CornerRadiiPx = packed struct {
    top_left: u8 = 0,
    top_right: u8 = 0,
    bottom_left: u8 = 0,
    bottom_right: u8 = 0,
};

pub const QuadBufferPixelBuffer = packed struct {
    bg_colour: zm.F32x4,
    border_colour: zm.F32x4,
    
    quad_width_pixels: f32,
    quad_height_pixels: f32,
    corner_radii: CornerRadiiPx,
    border_width_px: f32,

    flags: u32,
    __padding0: u32 = 0,
    __padding1: u32 = 0,
    __padding2: u32 = 0,
    //__padding3: u32 = 0,
};

pub const FontEnum = enum(usize) {
    GeistMono = 0,
    Geist,
    Count,
};

pub const UiRenderer = struct {
    _allocator: std.mem.Allocator,
    quad_renderer: QuadRenderer,
    fonts: [@intFromEnum(FontEnum.Count)]font.Font,

    pub fn deinit(self: *UiRenderer) void {
        self.quad_renderer.deinit();
        for (&self.fonts) |*f| {
            f.deinit();
        }
    }

    pub fn init(alloc: std.mem.Allocator, gfx: *_gfx.GfxState) !UiRenderer {
        // construct ui object
        return UiRenderer {
            ._allocator = alloc,
            .quad_renderer = try QuadRenderer.init(gfx),
            .fonts = [_]font.Font {
                try font.Font.init(
                    alloc,
                    path.Path{.ExeRelative = "../../res/GeistMono-Regular.json"},
                    path.Path{.ExeRelative = "../../res/GeistMono-Regular.png"},
                    gfx
                ),
                try font.Font.init(
                    alloc,
                    path.Path{.ExeRelative = "../../res/Geist-Regular.json"},
                    path.Path{.ExeRelative = "../../res/Geist-Regular.png"},
                    gfx
                ),
            },
        };
    }

    pub fn get_font(self: *UiRenderer, font_enum: FontEnum) *font.Font {
        return &self.fonts[@intFromEnum(font_enum)];
    }

    pub fn render_text_2d(
        self: *UiRenderer, 
        font_enum: FontEnum,
        text: []const u8,
        props: font.Font.FontRenderProperties2D,
        rtv: _gfx.RenderTargetView, 
        gfx: *_gfx.GfxState,
    ) void {
        self.fonts[@intFromEnum(font_enum)].render_text_2d(
            text, props, rtv, gfx
        );
    }

    pub fn render_quad(
        self: *UiRenderer,
        rect_pixels: RectPixels,
        props: QuadRenderer.QuadProperties,
        rtv: _gfx.RenderTargetView, 
        gfx: *_gfx.GfxState,
    ) void {
        self.quad_renderer.render_quad(
            rect_pixels, props, rtv, gfx
        );
    }
};

pub const QuadRenderer = struct {
    sampler: _gfx.Sampler,
    blend_state: _gfx.BlendState,

    quad_vso: _gfx.VertexShader,
    quad_pso: _gfx.PixelShader,
    quad_buffer_vertex: _gfx.Buffer,
    quad_buffer_pixel: _gfx.Buffer,

    const QUAD_SHADER_HLSL = @embedFile("quad_shader.hlsl");

    pub fn deinit(self: *QuadRenderer) void {
        self.blend_state.deinit();
        self.sampler.deinit();

        self.quad_vso.deinit();
        self.quad_pso.deinit();
        self.quad_buffer_vertex.deinit();
        self.quad_buffer_pixel.deinit();
    }

    pub fn init(gfx: *_gfx.GfxState) !QuadRenderer {
        // construct ui object
        var ui = QuadRenderer {
            .sampler = undefined,
            .blend_state = undefined,

            .quad_vso = undefined,
            .quad_pso = undefined,
            .quad_buffer_vertex = undefined,
            .quad_buffer_pixel = undefined,
        };

        // create the quad shaders
        ui.quad_vso = try _gfx.VertexShader.init_buffer(
            QUAD_SHADER_HLSL,
            "vs_main",
            ([_]_gfx.VertexInputLayoutEntry {})[0..],
            gfx
        );
        errdefer ui.quad_vso.deinit();

        ui.quad_pso = try _gfx.PixelShader.init_buffer(
            QUAD_SHADER_HLSL,
            "ps_main",
            gfx
        );
        errdefer ui.quad_pso.deinit();

        // create quad constant buffers
        ui.quad_buffer_vertex = try _gfx.Buffer.init(
            @sizeOf(QuadBufferVertexBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        errdefer ui.quad_buffer_vertex.deinit();

        ui.quad_buffer_pixel = try _gfx.Buffer.init(
            @sizeOf(QuadBufferPixelBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        errdefer ui.quad_buffer_pixel.deinit();

        // create sampler
        ui.sampler = try _gfx.Sampler.init(
            .{
                .filter_min_mag = .Linear,
                .filter_mip = .Point,
                .border_mode = .Wrap,
            },
            gfx
        );
        errdefer ui.sampler.deinit();

        // create blend state
        ui.blend_state = try _gfx.BlendState.init(([_]_gfx.BlendType{.Simple})[0..], gfx);
        errdefer ui.blend_state.deinit();

        // finally return the ui structure
        return ui;
    }

    pub const QuadPropertiesTexture = struct {
        texture_view: _gfx.TextureView2D,
        sampler: _gfx.Sampler,
    };

    pub const QuadProperties = struct {
        colour: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
        border_colour: zm.F32x4 = zm.f32x4s(0.0),
        border_width_px: u32 = 0,
        corner_radii_px: CornerRadiiPx = .{},
        texture: ?QuadPropertiesTexture = null,
    };

    pub fn render_quad(
        self: *QuadRenderer,
        rect_pixels: RectPixels,
        props: QuadProperties,
        rtv: _gfx.RenderTargetView, 
        gfx: *_gfx.GfxState,
    ) void {
        { // Setup quad vertex info buffer
            const mapped_buffer = self.quad_buffer_vertex.map(QuadBufferVertexBuffer, gfx) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data().* = QuadBufferVertexBuffer {
                .quad_bounds = rect_pixels.to_screen_bounds(rtv.size.width, rtv.size.height),
            };
        }
        { // Setup quad pixel info buffer
            const mapped_buffer = self.quad_buffer_pixel.map(QuadBufferPixelBuffer, gfx) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data().* = QuadBufferPixelBuffer {
                .bg_colour = props.colour,
                .border_colour = props.border_colour,
                .border_width_px = @floatFromInt(props.border_width_px),
                .quad_width_pixels = @floatFromInt(rect_pixels.width),
                .quad_height_pixels = @floatFromInt(rect_pixels.height),
                .corner_radii = props.corner_radii_px,
                .flags = @bitCast(QuadBufferFlags{
                    .has_texture = (props.texture != null),
                }),
            };
        }

        const viewport = _gfx.Viewport {
            .width = @floatFromInt(rtv.size.width),
            .height = @floatFromInt(rtv.size.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
            .top_left_x = 0,
            .top_left_y = 0,
        };
        gfx.cmd_set_viewport(viewport);

        gfx.cmd_set_pixel_shader(&self.quad_pso);

        gfx.cmd_set_render_target(&rtv, null);
        gfx.cmd_set_blend_state(&self.blend_state);

        gfx.cmd_set_vertex_shader(&self.quad_vso);

        gfx.cmd_set_topology(.TriangleList);
        gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });

        gfx.cmd_set_constant_buffers(.Vertex, 0, &.{&self.quad_buffer_vertex});
        gfx.cmd_set_constant_buffers(.Pixel, 1, &.{&self.quad_buffer_pixel});

        if (props.texture) |texture_props| {
            gfx.cmd_set_samplers(.Pixel, 0, &.{&texture_props.sampler});
            gfx.cmd_set_shader_resources(.Pixel, 0, &.{&texture_props.texture_view});
        } else {
            gfx.cmd_set_samplers(.Pixel, 0, &.{&gfx.default.sampler});
            gfx.cmd_set_shader_resources(.Pixel, 0, &.{&gfx.default.diffuse});
        }

        gfx.cmd_draw(6, 0);
    }
};

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
        shrinkable_percent: f32 = 0.0,
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

        allows_overflow_x: bool = false,
        allows_overflow_y: bool = false,

        floating_x: bool = false,
        floating_y: bool = false,

        clickable: bool = false,

        __unused: u26 = 0,

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
        next_sibling: ?usize = null,
        prev_sibling: ?usize = null,
        parent: usize = 0,

        // parent data
        layout_axis: ?Axis = null,
        first_child: ?usize = null,
        last_child: ?usize = null,
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
            size: u16 = 15,
            colour: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
        } = null,
        background_colour: ?zm.F32x4 = null,
        border_colour: ?zm.F32x4 = null,
        border_width_px: u16 = 0,
        corner_radii_px: CornerRadiiPx = .{},
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

        pub fn slate() Palette {
            @setEvalBranchQuota(10000);
            return Palette {
               .text_light = zm.srgbToRgb(zm.f32x4(248.0/255.0, 250.0/255.0, 252.0/255.0, 1.0)), 
               .text_dark = zm.srgbToRgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, 1.0)),
               .primary = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(222.2/360.0, 0.474, 0.112, 1.0))),
               .border = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(214.3/360.0, 0.318, 0.914, 1.0))),
               .background = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(0.0/360.0, 0.0, 1.0, 1.0))),
               .foreground = zm.srgbToRgb(zm.hslToRgb(zm.f32x4(222.2/360.0, 0.84, 0.049, 1.0))),
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

    hot_item: ?Key = null,
    active_item: ?Key = null,

    input: *const in.InputState,
    time: *const tm.TimeState,

    primary_interact_key: kc.KeyCode = kc.KeyCode.MouseLeft,
    ui: UiRenderer,

    parent_stack: std.ArrayList(usize),
    palette_stack: std.ArrayList(Palette),

    widgets: std.ArrayList(Widget),
    last_frame_widgets: std.AutoHashMap(Key, Widget),

    last_frame_arena: u8,
    arenas: [2]std.heap.ArenaAllocator,

    scuffed_x_checkbox_image: _gfx.TextureView2D,
    image_sampler: _gfx.Sampler,

    pub fn deinit(self: *Self) void {
        self.ui.deinit();

        self.palette_stack.deinit();
        self.parent_stack.deinit();
        self.widgets.deinit();
        self.last_frame_widgets.deinit();

        self.scuffed_x_checkbox_image.deinit();
        self.image_sampler.deinit();

        for (self.arenas) |a| {
            a.deinit();
        }
    }

    pub fn init(alloc: std.mem.Allocator, input: *const in.InputState, time: *const tm.TimeState, gfx: *_gfx.GfxState) !Self {
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

        var self = Self {
            .input = input,
            .time = time,
            .ui = try UiRenderer.init(alloc, gfx),
            .parent_stack = std.ArrayList(usize).init(alloc),
            .palette_stack = std.ArrayList(Palette).init(alloc),
            .widgets = std.ArrayList(Widget).init(alloc),
            .last_frame_widgets = std.AutoHashMap(Key, Widget).init(alloc),
            .scuffed_x_checkbox_image = scuffed_x_checkbox_image_view,
            .image_sampler = try _gfx.Sampler.init(.{}, gfx),
            .last_frame_arena = 0,
            .arenas = [_]std.heap.ArenaAllocator{
                std.heap.ArenaAllocator.init(alloc),
                std.heap.ArenaAllocator.init(alloc),
            },
        };
        self.add_root_widget(gfx);
        return self;
    }

    fn arena(self: *Self) *std.heap.ArenaAllocator {
        return &self.arenas[(@as(usize, @intCast(self.last_frame_arena)) + 1) % 2];
    }

    pub fn palette(self: *const Self) Palette {
        return self.palette_stack.getLastOrNull() orelse Palette.default_palette;
    }

    fn add_heirarchy_links(self: *Self, parent_id: usize, widget_id: usize) void {
        const parent = &self.widgets.items[parent_id];
        const widget = &self.widgets.items[widget_id];

        widget.parent = parent_id;

        if (parent.first_child == null) {
            parent.first_child = widget_id;
            parent.last_child = widget_id;
        } else {
            std.debug.assert(parent.last_child != null);
            const sibling_id = parent.last_child.?;
            const sibling = &self.widgets.items[parent.last_child.?];
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
                },
                .TextContent => {
                    if (widget.text_content) |*text| {
                        const text_bounds = self.ui.fonts[@intFromEnum(text.font)].text_bounds_2d_pixels(
                            text.text,
                            text.size
                        );
                        switch (axis) {
                            0 => widget.computed.size[0] = @floatFromInt(text_bounds.width),
                            1 => widget.computed.size[1] = @as(f32,@floatFromInt(text_bounds.height)) - self.ui.get_font(text.font).font_metrics.descender,
                            else => {unreachable;}
                        }
                    } else {
                        std.log.warn("widget with size kind \"Text Content\" does not have any text content.", .{});
                    }
                    apply_padding(widget, axis);
                },
                else => {},
            }
        }
    }

    pub fn add_widget(self: *Self, widget: Widget) usize {
        var widget_to_add = widget;
        // we need to own the text content so duplicate it using this frame's arena before adding the widget
        if (widget_to_add.text_content) |*text| {
            text.text = self.arena().allocator().dupe(u8, text.text) catch unreachable;
        }

        const widget_id = self.widgets.items.len;
        self.widgets.append(widget_to_add) catch unreachable;

        const parent_id = self.parent_stack.getLast();

        self.add_heirarchy_links(parent_id, widget_id);
        return widget_id;
    }

    pub fn get_widget(self: *Self, widget_id: usize) ?*Widget {
        if (widget_id >= self.widgets.items.len) { return null; }
        return &self.widgets.items[widget_id];
    }

    pub fn get_widget_from_last_frame(self: *Self, widget_id: usize) ?*const Widget {
        if (widget_id >= self.widgets.items.len) { return null; }
        return self.last_frame_widgets.getPtr(self.widgets.items[widget_id].key);
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
        self.parent_stack.append(0) catch unreachable;
    }

    fn solve_upward_dependant_sizes(self: *Self, widget: *Widget) void {
        const parent = &self.widgets.items[widget.parent];
        for (widget.semantic_size, 0..) |s, axis| {
            switch (s.kind) {
                .ParentPercentage => {
                    switch (axis) {
                        @intFromEnum(Axis.X) => widget.computed.size[axis] = @as(f32, @floatFromInt(parent.content_rect().width)) * s.value,
                        @intFromEnum(Axis.Y) => widget.computed.size[axis] = @as(f32, @floatFromInt(parent.content_rect().height)) * s.value,
                        else => {unreachable;},
                    }
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
                const child = &self.widgets.items[child_id.?];
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
                },
                else => {},
            }
        }
    }

    fn solve_size_violations_in_children(self: *Self, parent_id: usize) bool {
        const parent = &self.widgets.items[parent_id];
        if (parent.num_children == 0) { return false; }
        var violation_found = false;
        
        for (0..parent.semantic_size.len) |axis| {
            if (parent.flags.get_allow_overflow_flag(@enumFromInt(axis))) { continue; }

            var children_in_split: usize = parent.num_children;
            // violation in this axis
            const last_child = &self.widgets.items[parent.last_child.?];
            var overrun = last_child.computed.relative_position[axis] + last_child.computed.size[axis] - parent.computed.size[axis];
            var last_overrun: f32 = overrun + 1.0;
            while (overrun > 0.0) {
                violation_found = true;
                // break if we find ourselves in infinite loop
                if (@abs(overrun - last_overrun) < 0.05) {
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
                var child: ?*Widget = &self.widgets.items[parent.first_child.?];
                while (child != null) {
                    // determine how much this child may shink
                    const amount_can_shrink = child.?.semantic_size[axis].shrinkable_percent * child.?.computed.size[axis];
                    if (amount_can_shrink >= split) {
                        // if it can shrink the full amount, do so.
                        overrun -= split;
                        child.?.computed.size[axis] -= split;
                        child.?.semantic_size[axis].shrinkable_percent -= (split / amount_can_shrink) * child.?.semantic_size[axis].shrinkable_percent;
                    } else { 
                        // if it cannot shrink the full amount, then shink as much as possible 
                        // and remove this child from the split count
                        overrun -= amount_can_shrink;
                        // disable further shinking on this child
                        child.?.computed.size[axis] -= amount_can_shrink;
                        child.?.semantic_size[axis].shrinkable_percent = 0.0;
                        children_in_split -= 1;
                    }

                    // go to next child
                    if (child.?.next_sibling == null) {
                        child = null;
                    } else {
                        child = &self.widgets.items[child.?.next_sibling.?];
                    }
                }
            }
        }

        return violation_found;
    }

    pub fn compute_widget_rects(self: *Self) void {
        // downward solve
        for (0..self.widgets.items.len) |inv_id| {
            const id = self.widgets.items.len - inv_id - 1;
            const widget = &self.widgets.items[id];
            self.compute_standalone_widget_size(widget);
            self.solve_downward_dependant_sizes(widget);
        }

        // upward solve
        for (self.widgets.items, 0..) |*widget, widget_id| {
            std.debug.assert(widget.parent <= widget_id);
            self.solve_upward_dependant_sizes(widget);
        }

        // downward solve again to resolve any ParentPercentage under ChildrenSize
        for (0..self.widgets.items.len) |inv_id| {
            const id = self.widgets.items.len - inv_id - 1;
            const widget = &self.widgets.items[id];
            self.solve_downward_dependant_sizes(widget);
        }

        // calculate relative positions and rects
        // step through all widgets top down, if violations occur then we 
        // re-calculate relative positions from parent
        var widget_id: usize = 0;
        while (widget_id < self.widgets.items.len) {
            const widget = &self.widgets.items[widget_id];

            if (widget.parent == widget_id) { widget_id += 1; continue;}
            const parent = &self.widgets.items[widget.parent];
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
                        var prev = &self.widgets.items[sib_id];

                        // skip all previous siblings who are floating on this axis
                        while (prev.flags.get_floating_flag(@enumFromInt(axis)) and prev.prev_sibling != null) {
                            prev = &self.widgets.items[prev.prev_sibling.?];
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
                    + (widget.anchor[axis] * potential_space_size);
            }

            // solve violations in parent if this is the last sibling
            if (widget.next_sibling == null) {
                // const violation_found = self.solve_size_violations_in_children(widget.parent);
                //
                // // if we found a size violation we need to recalculate relative positions from parent id
                // if (violation_found) {
                //     widget_id = widget.parent;
                //     continue;
                // }
            }

            // go to next widget
            widget_id += 1;
        }
    }

    pub fn render_imui(self: *Self, rtv: *_gfx.RenderTargetView, gfx: *_gfx.GfxState) void {
        for (self.widgets.items) |*widget| {
            if (widget.flags.render == false) { continue; }

            // render rect
            const render_rect = 
                widget.background_colour != null or
                widget.border_colour != null or
                widget.texture != null;

            if (render_rect) {
                var background_colour = zm.f32x4s(0.0);
                if (widget.background_colour) |bc| {
                    background_colour = bc;
                }

                var border_colour = zm.f32x4s(0.0);
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

                self.ui.render_quad(
                    widget.computed.rect(),
                    .{
                        .colour = background_colour + zm.f32x4(0.2, 0.2, 0.2, 0.0) * zm.f32x4s(es.ease_out_expo(widget.hot_t)),
                        .border_colour = border_colour,
                        .border_width_px = widget.border_width_px,
                        .corner_radii_px = widget.corner_radii_px,
                        .texture = quad_texture_props,
                    },
                    rtv.*,
                    gfx
                );
            }
            
            // render text
            if (widget.text_content) |*text| {
                const text_size_f32: f32 = @floatFromInt(text.size);
                const font_metrics = self.ui.get_font(text.font).font_metrics;
                const x: i32 = @intFromFloat(widget.computed.offset_position[0]);
                const top: i32 = @as(i32, @intFromFloat(widget.computed.offset_position[1] + (font_metrics.ascender * text_size_f32)));
                const y: i32 = top;
                self.ui.render_text_2d(
                    text.font,
                    text.text,
                    .{
                        .position = .{ .x = x, .y = y, },
                        .colour = text.colour,
                        .pixel_height = text.size,
                    },
                    rtv.*,
                    gfx
                );
            }
        }
    }

    pub fn end_frame(self: *Self, gfx: *const _gfx.GfxState) void {
        self.last_frame_widgets.clearRetainingCapacity();
        for (self.widgets.items) |w| {
            if (w.key != Self.LabelKey) {
                std.debug.assert(!self.last_frame_widgets.contains(w.key));
            }
            self.last_frame_widgets.put(w.key, w) catch unreachable;
        }
        self.widgets.clearRetainingCapacity();
        self.parent_stack.clearRetainingCapacity();

        self.last_frame_arena = (self.last_frame_arena + 1) % 2;
        _ = self.arena().reset(.free_all);

        self.add_root_widget(gfx);
    }

    fn generate_widget_signals(self: *Self, widget_id: usize) WidgetSignal(usize) {
        const widget = self.get_widget(widget_id).?;
        var widget_signal = WidgetSignal(usize) {.id = widget_id,};
        const last_frame_widget = self.last_frame_widgets.getPtr(widget.key);

        if (last_frame_widget) |lfw| {
            const lfw_contains_cursor = lfw.computed.rect().contains(self.input.cursor_position);
            if (lfw_contains_cursor) {
                widget_signal.hover = true;
                if (self.hot_item == widget.key) {
                    // continue hover
                } else {
                    // start hover
                    self.hot_item = widget.key;
                }
            } else {
                if (self.hot_item == widget.key) {
                    // end hover
                    self.hot_item = null;
                    // if (self.active_item == widget.key) {
                    //     self.active_item = null;
                    // }
                } else {

                }
            }

            if (widget.flags.clickable) {
                if (self.active_item == widget.key) {
                    if (self.input.get_key(self.primary_interact_key)) {
                        // dragged
                        widget_signal.dragged = true;
                    }
                    if (self.input.get_key_up(self.primary_interact_key)) {
                        self.active_item = null;
                    }
                } else if (self.hot_item == widget.key) {
                    if (self.input.get_key_down(self.primary_interact_key)) {
                        widget_signal.clicked = true;
                        self.active_item = widget.key;
                    }
                }
            }
        }

        if (self.last_frame_widgets.getPtr(widget.key)) |lw| {
            if (self.hot_item == widget.key) {
                widget.hot_t = @min(lw.hot_t + self.time.delta_time_f32() / widget.hot_t_timescale, 1.0);
            } else {
                widget.hot_t = @max(lw.hot_t - self.time.delta_time_f32() / widget.hot_t_timescale, 0.0);
            }
            if (self.active_item == widget.key) {
                widget.active_t = @min(lw.active_t + self.time.delta_time_f32() / widget.active_t_timescale, 1.0);
            } else {
                widget.active_t = @max(lw.active_t - self.time.delta_time_f32() / widget.active_t_timescale, 0.0);
            }
        }

        return widget_signal;
    }

    pub fn combine_signals(signals_1: anytype, signals_2: anytype, id: anytype) WidgetSignal(@TypeOf(id)) {
        return WidgetSignal(@TypeOf(id)) {
            .clicked = signals_1.clicked or signals_2.clicked,
            .hover = signals_1.hover or signals_2.hover,
            .dragged = signals_1.dragged or signals_2.dragged,
            .id = id,
        };
    }

    pub fn push_pallete(self: *Self, p: Palette) void {
        self.palette_stack.append(p);
    }

    pub fn pop_pallete(self: *Self) void {
        _ = self.palette_stack.pop();
    }

    pub fn push_layout_id(self: *Self, widget_id: usize) void {
        std.debug.assert(widget_id < self.widgets.items.len);
        self.parent_stack.append(widget_id) catch unreachable;
    }

    pub fn push_layout_widget(self: *Self, widget: Widget) usize {
        const widget_id = self.add_widget(widget);
        self.parent_stack.append(widget_id) catch unreachable;
        return widget_id;
    }

    pub fn push_layout(self: *Self, layout_axis: Axis, key: anytype) usize {
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

    pub fn push_floating_layout(self: *Self, layout_axis: Axis, floating_x: f32, floating_y: f32, key: anytype) usize {
        return self.push_layout_widget(Widget {
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
            },
        });
    }

    pub fn pop_layout(self: *Self) void {
        _ = self.parent_stack.pop();
    }

    pub fn label(self: *Self, text: []const u8) WidgetSignal(usize) {
        const widget = Widget {
            .key = Self.LabelKey,
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
        };

        const widget_id = self.add_widget(widget);
        return self.generate_widget_signals(widget_id);
    }

    pub const ButtonId = struct {
        box: usize,
        text: usize,
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

        const text_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = text,
                .colour = self.palette().text_light,
            },
            .anchor = .{ 0.5, 0.5 },
            .pivot = .{ 0.5, 0.5 },
            .flags = .{
                .clickable = true,
            },
        };

        const text_widget_id = self.add_widget(text_widget);
        return combine_signals(
            self.generate_widget_signals(box_layout),
            self.generate_widget_signals(text_widget_id),
            ButtonId{ .box = box_layout, .text = text_widget_id, }
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
        box:usize, text:usize
    };

    pub fn checkbox(self: *Self, checked: bool, text: []const u8, key: anytype) WidgetSignal(CheckboxId) {
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
            .background_colour = blk: {if (checked) { break :blk self.palette().primary; } else { break :blk zm.f32x4s(0.0); }},
            .border_colour = self.palette().primary,
            .border_width_px = 1,
            .corner_radii_px = .{
                .top_left = 4,
                .top_right = 4,
                .bottom_left = 4,
                .bottom_right = 4,
            },
            .texture = blk: { 
                if (checked) { 
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
        };
        const text_widget_id = self.add_widget(text_widget);
        const text_widget_signals = self.generate_widget_signals(text_widget_id);

        self.pop_layout();

        return combine_signals(
            box_widget_signals, 
            text_widget_signals, 
            CheckboxId{ .box = box_widget_id, .text = text_widget_id, }
        );
    }

    pub const SliderId = struct {
        filled_bar:usize, 
        background_bar:usize
    };

    pub fn slider(self: *Self, value: f32, min: f32, max: f32, key: anytype) WidgetSignal(SliderId) {
        const complete_percent = std.math.clamp((value - min) / (max - min), 0.0, 1.0);
        const box = self.push_layout(.X, key ++ .{@src().line});
        self.get_widget(box).?.semantic_size[0].kind = .ParentPercentage;
        self.get_widget(box).?.semantic_size[0].value = 1.0;
        self.get_widget(box).?.flags.render = true;
        self.get_widget(box).?.background_colour = self.palette().secondary;
        self.get_widget(box).?.border_colour = self.palette().border;
        self.get_widget(box).?.border_width_px = 1;
        self.get_widget(box).?.corner_radii_px = .{
            .top_left = 4,
            .top_right = 4,
            .bottom_left = 4,
            .bottom_right = 4,
        };

        const filled_bar_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .ParentPercentage, .value = complete_percent, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            },
            .background_colour = self.palette().primary,
            .border_colour = self.palette().border,
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
        const filled_bar_widget_id = self.add_widget(filled_bar_widget);
        const filled_bar_widget_signals = self.generate_widget_signals(filled_bar_widget_id);

        const empty_bar_widget = Widget {
            .key = gen_key(key ++ .{@src().line}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .ParentPercentage, .value = (1.0 - complete_percent), .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            },
            .flags = .{
                .render = false,
                .clickable = true,
            },
        };
        const empty_bar_widget_id = self.add_widget(empty_bar_widget);
        const empty_bar_widget_signals = self.generate_widget_signals(empty_bar_widget_id);

        self.pop_layout();

        return combine_signals(
            filled_bar_widget_signals, 
            empty_bar_widget_signals, 
            SliderId{ .filled_bar = filled_bar_widget_id, .background_bar = box, }
        );
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
        box: usize,
        text: usize,
    };

    pub fn text_input(self: *Self, state: *TextInputState, input: *const in.InputState, key: anytype) WidgetSignal(TextInputId) {
        const l = self.push_layout(.X, key ++ .{@src()});
        if (self.get_widget(l)) |lw| {
            lw.flags.render = true;
            lw.flags.clickable = true;
            lw.layout_axis = null;
            lw.semantic_size[0].kind = .ParentPercentage;
            lw.semantic_size[0].value = 1.0;
            lw.semantic_size[1].kind = .Pixels;
            lw.semantic_size[1].value = 16.0;
            lw.background_colour = self.palette().primary;
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
        const text_input_widget = Widget {
            .key = gen_key(key ++ .{@src()}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 1.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .TextContent, .value = 1.0, .shrinkable_percent = 0.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = state.text.items,
                .colour = self.palette().text_light,
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

        _ = self.push_layout(.X, key ++ .{@src()});
        var l_sel = @min(state.cursor, state.mark);
        const r_sel = @max(state.cursor, state.mark);
        var phantom_text = text_input_widget;
        phantom_text.key = gen_key(key ++ .{@src()});
        phantom_text.flags.render = false;
        phantom_text.text_content.?.text = state.text.items[0..l_sel];
        _ = self.add_widget(phantom_text);

        const bounds = self.ui.get_font(text_input_widget.text_content.?.font).text_bounds_2d_pixels(
            state.text.items[l_sel..r_sel],
            text_input_widget.text_content.?.size
        );
        const cursor = Widget {
            .key = gen_key(key ++ .{@src()}),
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .Pixels, .value = @as(f32, @floatFromInt(bounds.width)) + 1.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            },
            .background_colour = zm.f32x4(1.0, 0.0, 0.0, 0.4 + 0.4 * 
                (std.math.sin(2.0 * std.math.pi * @as(f32, @floatFromInt(@mod(std.time.milliTimestamp(), 1000))) / @as(f32, @floatFromInt(std.time.ms_per_s))) + 1.0) * 0.5),
            .border_colour = zm.f32x4s(0.0),
            .anchor = .{ 0.0, 0.5 },
            .pivot = .{ 0.0, 0.5 },
            .flags = .{
                .render = true,
            },
        };
        _ = self.add_widget(cursor);
        self.pop_layout();

        self.pop_layout();

        const box_signals = self.generate_widget_signals(l);
        const text_signals = self.generate_widget_signals(text_input_widget_id);

        if (self.hot_item == self.get_widget(l).?.key or self.hot_item == text_input_widget.key) {
            for (input.char_events) |c| {
                if (c != null) {
                    switch (c.?[0]) {
                        8 => {
                            if (state.text.items.len > 0) {
                                if (l_sel == r_sel) {
                                    if (input.get_key(kc.KeyCode.Shift)) {
                                        l_sel = std.mem.lastIndexOfAny(u8, state.text.items[0..l_sel], "\n\t ") orelse 0;
                                    } else {
                                        l_sel -= 1;
                                    }
                                }
                                for (l_sel..r_sel) |_| {
                                    _ = state.text.orderedRemove(l_sel);
                                }
                                state.cursor = l_sel;
                                state.mark = state.cursor;
                            }
                        },
                        13 => {
                            // single line input so ignore newline
                            // state.text.append('\n') catch {};
                        },
                        32...126 => {
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

            if (input.get_key_down(kc.KeyCode.Escape)) {
                state.mark = state.cursor;
            }
            if (input.get_key_down_repeat(kc.KeyCode.ArrowLeft)) {
                if (state.cursor > 0) {
                    state.cursor = state.cursor - 1;
                }
                if (!input.get_key(kc.KeyCode.Shift)) {
                    state.mark = state.cursor;
                }
            }
            if (input.get_key_down_repeat(kc.KeyCode.ArrowRight)) {
                if (state.cursor < state.text.items.len) {
                    state.cursor = state.cursor + 1;
                }
                if (!input.get_key(kc.KeyCode.Shift)) {
                    state.mark = state.cursor;
                }
            }
        }

        return combine_signals(
            box_signals,
            text_signals,
            TextInputId{ .text = text_input_widget_id, .box = l, }
        );
    }
};
