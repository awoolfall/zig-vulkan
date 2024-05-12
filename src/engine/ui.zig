const std = @import("std");
const win32 = @import("zwin32");
const d3d11 = win32.d3d11;
const zstbi = @import("zstbi");
const _gfx = @import("../gfx/gfx.zig");
const in = @import("../input/input.zig");
const kc = @import("../input/keycode.zig");
const zm = @import("zmath");
const _font = @import("font.zig");
const path = @import("path.zig");

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

pub const QuadBufferPixelBuffer = packed struct {
    colour: zm.F32x4 = zm.f32x4s(1.0),
};

pub const FontEnum = enum(usize) {
    GeistMono = 0,
    Count
};

pub const UiRenderer = struct {
    _allocator: std.mem.Allocator,
    quad_renderer: QuadRenderer,
    fonts: [@intFromEnum(FontEnum.Count)]_font.Font,

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
            .fonts = [_]_font.Font {
                try _font.Font.init(
                    alloc,
                    path.Path{.ExeRelative = "../../res/GeistMono-Regular.json"},
                    path.Path{.ExeRelative = "../../res/GeistMono-Regular.png"},
                    gfx
                ),
            },
        };
    }

    pub fn get_font(self: *UiRenderer, font_enum: FontEnum) *_font.Font {
        return &self.fonts[@intFromEnum(font_enum)];
    }

    pub fn render_text_2d(
        self: *UiRenderer, 
        font: FontEnum,
        text: []const u8,
        props: _font.Font.FontRenderProperties2D,
        rtv: _gfx.RenderTargetView, 
        gfx: *_gfx.GfxState,
    ) void {
        self.fonts[@intFromEnum(font)].render_text_2d(
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

    pub fn render_text_over_quad(
        self: *UiRenderer,
        font_: FontEnum,
        text: []const u8,
        text_props: _font.Font.FontRenderProperties2D,
        quad_props: QuadRenderer.QuadProperties,
        rtv: _gfx.gfx.RenderTargetView,
        gfx: *_gfx.GfxState,
    ) void {
        self.render_quad(
            self.fonts[@intFromEnum(font_)].text_bounds_2d(text, text_props, rtv.size.width, rtv.size.height),
            quad_props,
            rtv,
            gfx
        );
        self.render_text_2d(
            font_,
            text,
            text_props,
            rtv,
            gfx
        );
    }

};

pub const QuadRenderer = struct {
    sampler: _gfx.Sampler,
    rasterizer_state: _gfx.RasterizationState,
    blend_state: _gfx.BlendState,

    quad_vso: _gfx.VertexShader,
    quad_pso: _gfx.PixelShader,
    quad_buffer_vertex: _gfx.Buffer,
    quad_buffer_pixel: _gfx.Buffer,

    const QUAD_SHADER_HLSL = @embedFile("quad_shader.hlsl");

    pub fn deinit(self: *QuadRenderer) void {
        self.blend_state.deinit();
        self.rasterizer_state.deinit();
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
            .rasterizer_state = undefined,
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

        // create rasterizer state
        ui.rasterizer_state = try _gfx.RasterizationState.init(
            .{ .FillBack = false, .FrontCounterClockwise = true, },
            gfx
        );
        errdefer ui.rasterizer_state.deinit();

        // create blend state
        ui.blend_state = try _gfx.BlendState.init(([_]_gfx.BlendType{.Simple})[0..], gfx);
        errdefer ui.blend_state.deinit();

        // finally return the ui structure
        return ui;
    }

    pub const QuadProperties = struct {
        colour: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
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

            mapped_buffer.data.* = QuadBufferVertexBuffer {
                .quad_bounds = rect_pixels.to_screen_bounds(rtv.size.width, rtv.size.height),
            };
        }
        { // Setup quad pixel info buffer
            const mapped_buffer = self.quad_buffer_pixel.map(QuadBufferPixelBuffer, gfx) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data.* = QuadBufferPixelBuffer {
                .colour = props.colour,
            };
        }

        const viewport = d3d11.VIEWPORT {
            .Width = @floatFromInt(rtv.size.width),
            .Height = @floatFromInt(rtv.size.height),
            .TopLeftX = 0,
            .TopLeftY = 0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        gfx.context.RSSetViewports(1, @ptrCast(&viewport));

        gfx.context.PSSetShader(self.quad_pso.pso, null, 0);

        gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), null);
        gfx.context.OMSetBlendState(@ptrCast(self.blend_state.state), null, 0xffffffff);

        gfx.context.VSSetShader(self.quad_vso.vso, null, 0);
        gfx.context.IASetInputLayout(self.quad_vso.layout);

        gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        gfx.context.RSSetState(self.rasterizer_state.state);

        gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.quad_buffer_vertex.buffer));
        gfx.context.PSSetConstantBuffers(1, 1, @ptrCast(&self.quad_buffer_pixel.buffer));
        gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler.sampler));

        gfx.context.Draw(6, 0);
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
        strictness: f32 = 1.0,
    };

    pub const Key = u64;

    pub const Widget = struct {
        semantic_size: [2]SemanticSize,

        key: Key,

        next_sibling: ?usize = null,
        prev_sibling: ?usize = null,

        first_child: ?usize = null,
        last_child: ?usize = null,
        parent: usize = 0,

        computed: struct {
            relative_position: [2]f32 = .{0.0, 0.0},
            size: [2]f32 = .{0.0, 0.0},
            rect: RectPixels = .{.left = 0, .top = 0, .width = 0, .height = 0,},
        } = .{},

        flags: packed struct(u32) {
            render: bool = true,
            __unused: u31 = 0,
        } = .{},
        text_content: ?[]const u8 = null,
    };

    pub const WidgetSignal = struct {
        clicked: bool = false,
        hover: bool = false,
        dragged: bool = false,
    };

    hot_item: ?Key = null,
    active_item: ?Key = null,

    input: *const in.InputState,
    primary_interact_key: kc.KeyCode = kc.KeyCode.MouseLeft,
    ui: UiRenderer,

    parent_stack: std.ArrayList(usize),

    widgets: std.ArrayList(Widget),
    last_frame_widgets: std.AutoHashMap(Key, Widget),

    pub fn deinit(self: *Self) void {
        self.ui.deinit();

        self.parent_stack.deinit();
        self.widgets.deinit();
        self.last_frame_widgets.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, input: *const in.InputState, gfx: *_gfx.GfxState) !Self {
        var self = Self {
            .input = input,
            .ui = try UiRenderer.init(alloc, gfx),
            .parent_stack = std.ArrayList(usize).init(alloc),
            .widgets = std.ArrayList(Widget).init(alloc),
            .last_frame_widgets = std.AutoHashMap(Key, Widget).init(alloc),
        };
        self.add_root_widget(gfx);
        return self;
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
    }

    fn compute_standalone_widget_size(self: *Self, widget_id: usize) void {
        const widget = &self.widgets.items[widget_id];
        for (widget.semantic_size, 0..) |s, axis| {
            switch (s.kind) {
                .Pixels => {
                    widget.computed.size[axis] = s.value;
                },
                .TextContent => {
                    const text_bounds = self.ui.fonts[@intFromEnum(FontEnum.GeistMono)].text_bounds_2d_pixels(
                        widget.text_content.?,
                        20,
                    );
                    switch (axis) {
                        0 => widget.computed.size[0] = @floatFromInt(text_bounds.width),
                        1 => widget.computed.size[1] = @floatFromInt(text_bounds.height),
                        else => {unreachable;}
                    }
                },
                else => {},
            }
        }
    }

    fn add_widget(self: *Self, widget: Widget) void {
        const widget_id = self.widgets.items.len;
        self.widgets.append(widget) catch unreachable;

        const parent_id = self.parent_stack.getLast();

        self.add_heirarchy_links(parent_id, widget_id);
        self.compute_standalone_widget_size(widget_id);
    }

    fn add_root_widget(self: *Self, gfx: *const _gfx.GfxState) void {
        std.debug.assert(self.widgets.items.len == 0);
        self.widgets.append(Widget {
            .semantic_size = [_]SemanticSize{.{.kind = .None, .value = 0.0, }} ** 2,
            .key = 0,
            .computed = .{
                .relative_position = .{0.0, 0.0},
                .size = .{
                    @floatFromInt(gfx.swapchain_size.width), 
                    @floatFromInt(gfx.swapchain_size.height)
                },
                .rect = RectPixels {
                    .left = 0,
                    .top = 0,
                    .width = gfx.swapchain_size.width,
                    .height = gfx.swapchain_size.height,
                },
            },
            .flags = .{
                .render = false,
            },
        }) catch unreachable;
        self.parent_stack.append(0) catch unreachable;
    }

    fn solve_upward_dependant_sizes(self: *Self, widget: *Widget) void {
        const parent = &self.widgets.items[widget.parent];
        for (widget.semantic_size, 0..) |s, axis| {
            switch (s.kind) {
                .ParentPercentage => {
                    widget.computed.size[axis] = parent.computed.size[axis] * s.value;
                },
                else => {},
            }
        }
    }

    fn solve_downward_dependant_sizes(self: *Self, widget: *Widget) void {
        for (widget.semantic_size, 0..) |s, axis| {
            switch (s.kind) {
                .ChildrenSize => {
                    var size: f32 = 0.0;
                    var child_id = widget.first_child;
                    while (child_id != null) {
                        const child = &self.widgets.items[child_id.?];
                        size += child.computed.size[axis];
                        child_id = child.next_sibling;
                    }
                    widget.computed.size[axis] = size;
                },
                else => {},
            }
        }
    }

    pub fn compute_widget_rects(self: *Self) void {
        for (self.widgets.items, 0..) |*widget, widget_id| {
            std.debug.assert(widget.parent <= widget_id);
            self.solve_upward_dependant_sizes(widget);
        }
        for (0..self.widgets.items.len) |inv_id| {
            const id = self.widgets.items.len - inv_id - 1;
            const widget = &self.widgets.items[id];
            self.solve_downward_dependant_sizes(widget);
        }
        for (self.widgets.items, 0..) |*widget, widget_id| {
            if (widget.parent == widget_id) {continue;}
            if (widget.prev_sibling) |sib_id| {
                const prev = &self.widgets.items[sib_id];
                widget.computed.relative_position = .{
                    prev.computed.relative_position[0] + prev.computed.size[0],
                    prev.computed.relative_position[1] + prev.computed.size[1]
                };
            } else {
                const parent = &self.widgets.items[widget.parent];
                widget.computed.relative_position = .{
                    parent.computed.relative_position[0],
                    parent.computed.relative_position[1]
                };
            }
            widget.computed.rect = .{
                .left = @intFromFloat(widget.computed.relative_position[0]),
                .top = @intFromFloat(widget.computed.relative_position[1]),
                .width = @intFromFloat(widget.computed.size[0]),
                .height = @intFromFloat(widget.computed.size[1])
            };
        }
    }

    pub fn render_imui(self: *Self, rtv: *_gfx.RenderTargetView, gfx: *_gfx.GfxState) void {
        for (self.widgets.items) |*widget| {
            if (widget.flags.render == false) { continue; }

            if (self.active_item != null and self.active_item.? == widget.key) {
                self.ui.render_quad(
                    widget.computed.rect,
                    .{ .colour = zm.f32x4s(0.5), },
                    rtv.*,
                    gfx
                );
            } else if (self.hot_item != null and self.hot_item.? == widget.key) {
                self.ui.render_quad(
                    widget.computed.rect,
                    .{ .colour = zm.f32x4s(1.0), },
                    rtv.*,
                    gfx
                );
            } else {
                self.ui.render_quad(
                    widget.computed.rect,
                    .{ .colour = zm.f32x4s(0.8), },
                    rtv.*,
                    gfx
                );
            }
            if (widget.text_content) |text| {
                self.ui.render_text_2d(
                    FontEnum.GeistMono,
                    text,
                    .{
                        .position = .{ 
                            .x = widget.computed.rect.left, 
                            .y = widget.computed.rect.top + @as(i32, @intFromFloat(self.ui.get_font(FontEnum.GeistMono).font_metrics.ascender * 20.0)),
                        },
                        .colour = zm.f32x4(0.0, 0.0, 0.0, 1.0),
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
            self.last_frame_widgets.put(w.key, w) catch unreachable;
        }
        self.widgets.clearRetainingCapacity();
        self.parent_stack.clearRetainingCapacity();

        self.add_root_widget(gfx);
    }

    fn generate_widget_signals(self: *Self, widget: *const Widget) WidgetSignal {
        var widget_signal = WidgetSignal {};
        const last_frame_widget = self.last_frame_widgets.getPtr(widget.key);

        if (last_frame_widget) |lfw| {
            const lfw_contains_cursor = lfw.computed.rect.contains(self.input.cursor_position);
            if (lfw_contains_cursor) {
                widget_signal.hover = true;
                if (self.hot_item == widget.key) {
                    // continue hover
                    if (self.active_item == widget.key) {
                        // dragged
                        widget_signal.dragged = true;
                    }
                } else {
                    // start hover
                    self.hot_item = widget.key;
                }
            } else {
                if (self.hot_item == widget.key) {
                    // end hover
                    self.hot_item = null;
                    if (self.active_item == widget.key) {
                        self.active_item = null;
                    }
                } else {

                }
            }

            if (self.active_item == widget.key) {
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

        return widget_signal;
    }

    pub fn button(self: *Self, text: []const u8, key: Key) WidgetSignal {
        const widget = Widget {
            .key = key,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, },
            },
            .text_content = text,
        };
        self.add_widget(widget);

        return self.generate_widget_signals(&widget);
    }
};
