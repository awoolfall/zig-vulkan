const std = @import("std");
const win32 = @import("zwin32");
const d3d11 = win32.d3d11;
const zstbi = @import("zstbi");
const _gfx = @import("../gfx/gfx.zig");
const tm = @import("../engine/time.zig");
const in = @import("../input/input.zig");
const kc = @import("../input/keycode.zig");
const es = @import("../easings.zig");
const zm = @import("zmath");
const _font = @import("font.zig");
const path = @import("path.zig");

inline fn srgb_to_rgb(srgb: zm.F32x4) zm.F32x4 {
    return zm.f32x4(
        std.math.pow(f32, srgb[0], 2.2), 
        std.math.pow(f32, srgb[1], 2.2), 
        std.math.pow(f32, srgb[2], 2.2), 
        srgb[3]
    );
}

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
    __unused: u32 = 0,
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
                try _font.Font.init(
                    alloc,
                    path.Path{.ExeRelative = "../../res/Geist-Regular.json"},
                    path.Path{.ExeRelative = "../../res/Geist-Regular.png"},
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
        border_colour: zm.F32x4 = zm.f32x4s(0.0),
        border_width_px: u32 = 0,
        corner_radii_px: CornerRadiiPx,
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
                .bg_colour = props.colour,
                .border_colour = props.border_colour,
                .border_width_px = @floatFromInt(props.border_width_px),
                .quad_width_pixels = @floatFromInt(rect_pixels.width),
                .quad_height_pixels = @floatFromInt(rect_pixels.height),
                .corner_radii = props.corner_radii_px,
                .flags = @bitCast(QuadBufferFlags{}),
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
        shrinkable_percent: f32 = 0.0,
    };

    pub const Axis = enum(usize) {
        X = 0,
        Y = 1,
    };
    pub const AxisCount = 2;

    pub const Key = u64;

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

    pub const Widget = struct {
        semantic_size: [AxisCount]SemanticSize,

        key: Key,

        // sibling data
        next_sibling: ?usize = null,
        prev_sibling: ?usize = null,
        parent: usize = 0,

        // parent data
        layout_axis: Axis = .Y,
        first_child: ?usize = null,
        last_child: ?usize = null,
        num_children: usize = 0,

        computed: struct {
            relative_position: [2]f32 = .{0.0, 0.0},
            size: [2]f32 = .{0.0, 0.0},
            rect: RectPixels = .{.left = 0, .top = 0, .width = 0, .height = 0,},
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
        padding_px: struct {
            left: u16 = 0,
            right: u16 = 0,
            top: u16 = 0,
            bottom: u16 = 0,
        } = .{},
        children_gap: f32 = 0.0,

        fn content_rect(self: *const Widget) RectPixels {
            return RectPixels {
                .left = self.computed.rect.left + self.padding_px.left,
                .top = self.computed.rect.top + self.padding_px.top,
                .width = self.computed.rect.width - self.padding_px.left - self.padding_px.right,
                .height = self.computed.rect.height - self.padding_px.top - self.padding_px.bottom,
            };
        }
    };

    pub const WidgetSignal = struct {
        clicked: bool = false,
        hover: bool = false,
        dragged: bool = false,
        widget_id: usize = 0,
    };

    hot_item: ?Key = null,
    active_item: ?Key = null,

    input: *const in.InputState,
    time: *const tm.TimeState,

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

    pub fn init(alloc: std.mem.Allocator, input: *const in.InputState, time: *const tm.TimeState, gfx: *_gfx.GfxState) !Self {
        var self = Self {
            .input = input,
            .time = time,
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
        const widget_id = self.widgets.items.len;
        self.widgets.append(widget) catch unreachable;

        const parent_id = self.parent_stack.getLast();

        self.add_heirarchy_links(parent_id, widget_id);
        return widget_id;
    }

    pub fn get_widget(self: *Self, widget_id: usize) ?*Widget {
        if (widget_id >= self.widgets.items.len) { return null; }
        return &self.widgets.items[widget_id];
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
                    if (@intFromEnum(widget.layout_axis) == axis) {
                        var size: f32 = -widget.children_gap;
                        var child_id = widget.first_child;
                        while (child_id != null) {
                            const child = &self.widgets.items[child_id.?];
                            size += child.computed.size[axis] + widget.children_gap;
                            child_id = child.next_sibling;
                        }
                        widget.computed.size[axis] = @max(size, 0.0);
                    } else {
                        var max_size: f32 = 0.0;
                        var child_id = widget.first_child;
                        while (child_id != null) {
                            const child = &self.widgets.items[child_id.?];
                            max_size = @max(child.computed.size[axis], max_size);
                            child_id = child.next_sibling;
                        }
                        widget.computed.size[axis] = max_size;
                    }
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

        // calculate relative positions and rects
        // step through all widgets top down, if violations occur then we 
        // re-calculate relative positions from parent
        var widget_id: usize = 0;
        while (widget_id < self.widgets.items.len) {
            const widget = &self.widgets.items[widget_id];

            if (widget.parent == widget_id) { widget_id += 1; continue;}
            const parent = &self.widgets.items[widget.parent];
            const parent_content_rect = parent.content_rect();
            const parent_content_rel_pos = [2]f32{
                @floatFromInt(parent_content_rect.left), 
                @floatFromInt(parent_content_rect.top)
            };

            // calculate relative position of widget on each axis
            for (0..AxisCount) |axis| {
                // if floating on this axis then the relative position has been manually applied, skip
                if (widget.flags.get_floating_flag(@enumFromInt(axis))) {
                    continue;
                }

                // look at previous siblings to determine relative position
                if (widget.prev_sibling) |sib_id| {
                    var prev = &self.widgets.items[sib_id];

                    // skip all previous siblings who are floating on this axis
                    while (prev.flags.get_floating_flag(@enumFromInt(axis)) and prev.prev_sibling != null) {
                        prev = &self.widgets.items[prev.prev_sibling.?];
                    }

                    if (@intFromEnum(parent.layout_axis) == axis) {
                        widget.computed.relative_position[axis] = prev.computed.relative_position[axis] + prev.computed.size[axis] + parent.children_gap;
                    } else {
                        widget.computed.relative_position[axis] = prev.computed.relative_position[axis];
                    }
                } else {
                    // if no previous siblings then set to parent's relative position
                    widget.computed.relative_position[axis] = parent_content_rel_pos[axis];
                }
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

            // store found rect in widget
            widget.computed.rect = .{
                .left = @intFromFloat(widget.computed.relative_position[0]),
                .top = @intFromFloat(widget.computed.relative_position[1]),
                .width = @intFromFloat(widget.computed.size[0]),
                .height = @intFromFloat(widget.computed.size[1])
            };

            // go to next widget
            widget_id += 1;
        }
    }

    pub fn render_imui(self: *Self, rtv: *_gfx.RenderTargetView, gfx: *_gfx.GfxState) void {
        for (self.widgets.items) |*widget| {
            if (widget.flags.render == false) { continue; }

            const render_rect = 
                widget.background_colour != null or
                widget.border_colour != null;

            if (render_rect) {
                var background_colour = zm.f32x4s(0.0);
                if (widget.background_colour) |bc| {
                    background_colour = bc;
                }

                var border_colour = zm.f32x4s(0.0);
                if (widget.border_colour) |bc| {
                    border_colour = bc;
                }

                self.ui.render_quad(
                    widget.computed.rect,
                    .{
                        .colour = background_colour + zm.f32x4(0.2, 0.2, 0.2, 0.0) * zm.f32x4s(es.ease_out_expo(widget.hot_t)),
                        .border_colour = border_colour,
                        .border_width_px = widget.border_width_px,
                        .corner_radii_px = widget.corner_radii_px,
                    },
                    rtv.*,
                    gfx
                );
            }
            
            const widget_content_rect = widget.content_rect();

            // render text
            if (widget.text_content) |*text| {
                self.ui.render_text_2d(
                    text.font,
                    text.text,
                    .{
                        .position = .{ 
                            .x = widget_content_rect.left, 
                            .y = widget_content_rect.top +
                                @as(i32, @intFromFloat(self.ui.get_font(text.font).font_metrics.ascender * @as(f32, @floatFromInt(text.size)))),
                        },
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
            self.last_frame_widgets.put(w.key, w) catch unreachable;
        }
        self.widgets.clearRetainingCapacity();
        self.parent_stack.clearRetainingCapacity();

        self.add_root_widget(gfx);
    }

    fn generate_widget_signals(self: *Self, widget: *Widget) WidgetSignal {
        var widget_signal = WidgetSignal {};
        const last_frame_widget = self.last_frame_widgets.getPtr(widget.key);

        if (last_frame_widget) |lfw| {
            const lfw_contains_cursor = lfw.computed.rect.contains(self.input.cursor_position);
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

    pub fn push_layout_id(self: *Self, widget_id: usize) void {
        std.debug.assert(widget_id < self.widgets.items.len);
        self.parent_stack.append(widget_id) catch unreachable;
    }

    pub fn push_layout_widget(self: *Self, widget: Widget) usize {
        const widget_id = self.add_widget(widget);
        self.parent_stack.append(widget_id) catch unreachable;
        return widget_id;
    }

    pub fn push_layout(self: *Self, layout_axis: Axis) usize {
        return self.push_layout_widget(Widget {
            .key = 0,
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

    pub fn push_floating_layout(self: *Self, layout_axis: Axis, floating_x: i32, floating_y: i32) usize {
        return self.push_layout_widget(Widget {
            .key = 0,
            .layout_axis = layout_axis,
            .semantic_size = [2]SemanticSize {
                SemanticSize{ .kind = .ChildrenSize, .value = 0.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .ChildrenSize, .value = 0.0, .shrinkable_percent = 0.0, },
            },
            .computed = .{
                .relative_position = .{
                    @floatFromInt(floating_x),
                    @floatFromInt(floating_y)
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

    pub fn label(self: *Self, text: []const u8) WidgetSignal {
        var widget = Widget {
            .key = 0,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = text,
            },
            .background_colour = zm.f32x4s(0.0),
            .border_colour = zm.f32x4s(0.0),
        };

        var signals = self.generate_widget_signals(&widget);
        signals.widget_id = self.add_widget(widget);

        return signals;
    }

    pub fn button(self: *Self, text: []const u8, key: Key) WidgetSignal {
        var widget = Widget {
            .key = key,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = text,
                .colour = srgb_to_rgb(zm.f32x4(248.0/255.0, 250.0/255.0, 252.0/255.0, 1.0)),
            },
            .background_colour = srgb_to_rgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, 1.0)),
            .border_colour = srgb_to_rgb(zm.f32x4(228.0/255.0, 228.0/255.0, 231.0/255.0, 1.0)),
            .border_width_px = 1,
            .padding_px = .{
                .left = 16,
                .right = 16,
                .top = 8,
                .bottom = 8,
            },
            .corner_radii_px = .{
                .top_left = 6,
                .top_right = 6,
                .bottom_left = 6,
                .bottom_right = 6,
            },
            .flags = .{
                .clickable = true,
            },
        };

        var signals = self.generate_widget_signals(&widget);
        signals.widget_id = self.add_widget(widget);

        return signals;
    }

    pub fn badge(self: *Self, text: []const u8, key: Key) WidgetSignal {
        var widget = Widget {
            .key = key,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = text,
                .colour = srgb_to_rgb(zm.f32x4(248.0/255.0, 250.0/255.0, 252.0/255.0, 1.0)),
            },
            .background_colour = srgb_to_rgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, 1.0)),
            .border_colour = srgb_to_rgb(zm.f32x4(228.0/255.0, 228.0/255.0, 231.0/255.0, 1.0)),
            .border_width_px = 1,
            .padding_px = .{
                .left = 10,
                .right = 10,
                .top = 2,
                .bottom = 2,
            },
            .corner_radii_px = .{
                .top_left = 6,
                .top_right = 6,
                .bottom_left = 6,
                .bottom_right = 6,
            },
            .flags = .{
                .clickable = true,
            },
        };

        var signals = self.generate_widget_signals(&widget);
        signals.widget_id = self.add_widget(widget);

        return signals;
    }

    pub fn checkbox(self: *Self, checked: bool, text: []const u8, key0: Key, key1: Key) WidgetSignal {
        _ = self.push_layout(.X);
        var box = Widget {
            .key = key0,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .Pixels , .value = 16.0, .shrinkable_percent = 0.0, },
                SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            },
            .text_content = .{
                .font = .GeistMono,
                .text = blk: { if (checked) { break :blk "x"; } else { break :blk " "; } },
                .colour = srgb_to_rgb(zm.f32x4(248.0/255.0, 250.0/255.0, 252.0/255.0, 1.0)),
            },
            .background_colour = srgb_to_rgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, blk: { if (checked) { break :blk 1.0; } else { break :blk 0.0; } })),
            .border_colour = srgb_to_rgb(zm.f32x4(15.0/255.0, 23.0/255.0, 42.0/255.0, 1.0)),
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
        var box_signals = self.generate_widget_signals(&box);
        box_signals.widget_id = self.add_widget(box);

        var text_w = Widget {
            .key = key1,
            .semantic_size = [2]SemanticSize{
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
                SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
            },
            .text_content = .{
                .font = .Geist,
                .text = text,
            },
            .background_colour = zm.f32x4s(0.0),
            .border_colour = zm.f32x4s(0.0),
            .padding_px = .{
                .left = 8,
            },
            .flags = .{ 
                .clickable = true, 
            },
        };
        var text_signals = self.generate_widget_signals(&text_w);
        text_signals.widget_id = self.add_widget(text_w);

        self.pop_layout();

        return WidgetSignal {
            .clicked = box_signals.clicked or text_signals.clicked,
            .hover = box_signals.hover or text_signals.hover,
            .dragged = box_signals.dragged or text_signals.dragged,
            .widget_id = box_signals.widget_id,
        };
    }
};
