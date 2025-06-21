const std = @import("std");
const zm = @import("zmath");
const engine = @import("../root.zig");
const _gfx = engine.gfx;
const ui = @import("ui.zig");
const RectPixels = @import("../root.zig").Rect;

pub const RectEdges = packed struct {
    left: f32 = 0.0,
    right: f32 = 0.0,
    bottom: f32 = 0.0,
    top: f32 = 0.0,

    pub inline fn all(value: f32) RectEdges {
        return RectEdges { .left = value, .right = value, .top = value, .bottom = value, };
    }

    pub inline fn lr_tb(left_right: f32, top_bottom: f32) RectEdges {
        return RectEdges { .left = left_right, .right = left_right, .top = top_bottom, .bottom = top_bottom, };
    }

    pub inline fn from_rect_pixels(rp: RectPixels) RectEdges {
        return .{ 
            .left = @floatCast(rp.left),
            .right = @floatCast(rp.right),
            .top = @floatCast(rp.top),
            .bottom = @floatCast(rp.bottom),
        };
    }
};

pub const CornerRadiiPx = packed struct {
    bottom_left: f32 = 0.0,
    bottom_right: f32 = 0.0,
    top_left: f32 = 0.0,
    top_right: f32 = 0.0,

    pub inline fn all(value: f32) CornerRadiiPx {
        return .{ .top_left = value, .top_right = value, .bottom_left = value, .bottom_right = value, };
    }
};


// -1.0 to 1.0, left and bottom of screen is -1.0, right and top is 1.0
pub const Bounds = extern struct {
    left: f32 = 0.0,
    bottom: f32 = 0.0,
    right: f32 = 0.0,
    top: f32 = 0.0,

    pub fn from_rect(rect: RectPixels, max_width: f32, max_height: f32) Bounds {
        const top_left = ui.position_pixels_to_screen_space(rect.left, rect.top, max_width, max_height);
        const bottom_right = ui.position_pixels_to_screen_space(rect.right, rect.bottom, max_width, max_height);
        return Bounds {
            .left = top_left[0],
            .top = top_left[1],
            .right = bottom_right[0],
            .bottom = bottom_right[1],
        };
    }
};

pub const QuadBufferPixelBuffer = packed struct {
    bg_colour: zm.F32x4,
    border_colour: zm.F32x4,

    corner_radii: CornerRadiiPx,
    border_width_px: RectEdges,

    quad_width_pixels: f32,
    quad_height_pixels: f32,
    flags: u32,
    __padding0: u32 = 0,
};

pub const QuadBufferVertexBuffer = extern struct {
    quad_bounds: Bounds = Bounds {},
};

pub const QuadBufferFlags = packed struct(u32) {
    has_texture: bool = false,
    __unused: u31 = 0,
};

pub const QuadRenderer = struct {
    sampler: _gfx.Sampler.Ref,

    quad_vso: _gfx.VertexShader,
    quad_pso: _gfx.PixelShader,
    quad_buffer_vertex: _gfx.Buffer.Ref,
    quad_buffer_pixel: _gfx.Buffer.Ref,

    const QUAD_SHADER_HLSL = @embedFile("quad_shader.slang");

    pub fn deinit(self: *QuadRenderer) void {
        self.sampler.deinit();

        self.quad_vso.deinit();
        self.quad_pso.deinit();
        self.quad_buffer_vertex.deinit();
        self.quad_buffer_pixel.deinit();
    }

    pub fn init() !QuadRenderer {
        // construct ui object
        var quad_renderer = QuadRenderer {
            .sampler = undefined,

            .quad_vso = undefined,
            .quad_pso = undefined,
            .quad_buffer_vertex = undefined,
            .quad_buffer_pixel = undefined,
        };

        // create the quad shaders
        quad_renderer.quad_vso = try _gfx.VertexShader.init_buffer(
            QUAD_SHADER_HLSL,
            "vs_main",
            ([_]_gfx.VertexInputLayoutEntry {})[0..],
            .{},
        );
        errdefer quad_renderer.quad_vso.deinit();

        quad_renderer.quad_pso = try _gfx.PixelShader.init_buffer(
            QUAD_SHADER_HLSL,
            "ps_main",
            .{},
        );
        errdefer quad_renderer.quad_pso.deinit();

        // create quad constant buffers
        quad_renderer.quad_buffer_vertex = try _gfx.Buffer.init(
            @sizeOf(QuadBufferVertexBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer quad_renderer.quad_buffer_vertex.deinit();

        quad_renderer.quad_buffer_pixel = try _gfx.Buffer.init(
            @sizeOf(QuadBufferPixelBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer quad_renderer.quad_buffer_pixel.deinit();

        // create sampler
        quad_renderer.sampler = try _gfx.Sampler.init(
            .{
                .filter_min_mag = .Linear,
                .filter_mip = .Point,
                .border_mode = .Wrap,
            },
        );
        errdefer quad_renderer.sampler.deinit();

        // create blend state
        // quad_renderer.blend_state = try _gfx.BlendState.init(([_]_gfx.BlendType{.PremultipliedAlpha})[0..], gfx);
        // errdefer quad_renderer.blend_state.deinit();

        // finally return the ui structure
        return quad_renderer;
    }

    pub const QuadPropertiesTexture = struct {
        texture_view: _gfx.ImageView.Ref,
        sampler: _gfx.Sampler.Ref,
    };

    pub const QuadProperties = struct {
        colour: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
        border_colour: zm.F32x4 = zm.f32x4s(0.0),
        border_width_px: RectEdges = .{},
        corner_radii_px: CornerRadiiPx = .{},
        texture: ?QuadPropertiesTexture = null,
        wireframe: bool = false,
    };

    pub fn render_quad(
        self: *QuadRenderer,
        rect_pixels: RectPixels,
        props: QuadProperties,
        rtv: _gfx.ImageView.Ref, 
    ) void {
        const gfx = _gfx.GfxState.get();

        { // Setup quad vertex info buffer
            const mapped_buffer = self.quad_buffer_vertex.map(.{ .write = true, }) catch unreachable;
            defer mapped_buffer.unmap();

            const view = rtv.get() catch unreachable;
            mapped_buffer.data(QuadBufferVertexBuffer).* = QuadBufferVertexBuffer {
                .quad_bounds = Bounds.from_rect(rect_pixels, @floatFromInt(view.size.width), @floatFromInt(view.size.height)),
            };
        }
        { // Setup quad pixel info buffer
            const mapped_buffer = self.quad_buffer_pixel.map(.{ .write = true, }) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data(QuadBufferPixelBuffer).* = QuadBufferPixelBuffer {
                .bg_colour = props.colour,
                .border_colour = props.border_colour,
                .border_width_px = props.border_width_px,
                .quad_width_pixels = rect_pixels.width(),
                .quad_height_pixels = rect_pixels.height(),
                .corner_radii = props.corner_radii_px,
                .flags = @bitCast(QuadBufferFlags{
                    .has_texture = (props.texture != null),
                }),
            };
        }

        const view = rtv.get() catch unreachable;
        const viewport = _gfx.Viewport {
            .width = @floatFromInt(view.size.width),
            .height = @floatFromInt(view.size.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
            .top_left_x = 0,
            .top_left_y = 0,
        };
        gfx.cmd_set_viewport(viewport);

        gfx.cmd_set_pixel_shader(&self.quad_pso);

        gfx.cmd_set_render_target(&.{rtv}, null);

        gfx.cmd_set_vertex_shader(&self.quad_vso);

        gfx.cmd_set_topology(.TriangleList);
        if (props.wireframe) {
            @branchHint(.unlikely);
            gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FillFront = false, .FrontCounterClockwise = true, });
        } else {
            @branchHint(.likely);
            gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });
        }

        gfx.cmd_set_constant_buffers(.Vertex, 0, &.{&self.quad_buffer_vertex});
        gfx.cmd_set_constant_buffers(.Pixel, 1, &.{&self.quad_buffer_pixel});

        if (props.texture) |texture_props| {
            gfx.cmd_set_samplers(.Pixel, 0, &.{texture_props.sampler});
            gfx.cmd_set_shader_resources(.Pixel, 0, &.{texture_props.texture_view});
        } else {
            gfx.cmd_set_samplers(.Pixel, 0, &.{gfx.default.sampler});
            gfx.cmd_set_shader_resources(.Pixel, 0, &.{gfx.default.diffuse_view});
        }

        gfx.cmd_draw(6, 0);
    }
};

