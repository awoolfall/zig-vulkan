const std = @import("std");
const win32 = @import("zwin32");
const d3d11 = win32.d3d11;
const zstbi = @import("zstbi");
const _gfx = @import("../gfx/gfx.zig");
const zm = @import("zmath");
const _font = @import("font.zig");
const path = @import("path.zig");

pub const RectPixels = struct {
    left: i32,
    bottom: i32,
    width: i32,
    height: i32,
};

pub const Size = union(enum) {
    Pixels: i32, // 0 -> image width/height
    Screen: f32, // 0.0 (bottom, left) -> 1.0 (top, right)
};

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

    pub fn render_text_2d(
        self: *UiRenderer, 
        font: FontEnum,
        text: []const u8,
        x_pos: i32,
        y_pos: i32,
        props: _font.Font.FontRenderProperties2D,
        rtv: _gfx.RenderTargetView, 
        rtv_width: i32,
        rtv_height: i32,
        gfx: *_gfx.GfxState,
    ) void {
        self.fonts[@intFromEnum(font)].render_text_2d(
            text, x_pos, y_pos, props, rtv, rtv_width, rtv_height, gfx
        );
    }

    pub fn render_quad(
        self: *UiRenderer,
        rect_pixels: RectPixels,
        props: QuadRenderer.QuadProperties,
        rtv: _gfx.RenderTargetView, 
        rtv_width: i32,
        rtv_height: i32,
        gfx: *_gfx.GfxState,
    ) void {
        self.quad_renderer.render_quad(
            rect_pixels, props, rtv, rtv_width, rtv_height, gfx
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
            gfx.device
        );
        errdefer ui.quad_vso.deinit();

        ui.quad_pso = try _gfx.PixelShader.init_buffer(
            QUAD_SHADER_HLSL,
            "ps_main",
            gfx.device
        );
        errdefer ui.quad_pso.deinit();

        // create quad constant buffers
        ui.quad_buffer_vertex = try _gfx.Buffer.init(
            @sizeOf(QuadBufferVertexBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx.device
        );
        errdefer ui.quad_buffer_vertex.deinit();

        ui.quad_buffer_pixel = try _gfx.Buffer.init(
            @sizeOf(QuadBufferPixelBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx.device
        );
        errdefer ui.quad_buffer_pixel.deinit();

        // create sampler
        ui.sampler = try _gfx.Sampler.init(
            .{
                .filter_min_mag = .Linear,
                .filter_mip = .Point,
                .border_mode = .Wrap,
            },
            gfx.device
        );
        errdefer ui.sampler.deinit();

        // create rasterizer state
        ui.rasterizer_state = try _gfx.RasterizationState.init(
            .{ .FillBack = false, .FrontCounterClockwise = true, },
            gfx.device
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
        rtv_width: i32,
        rtv_height: i32,
        gfx: *_gfx.GfxState,
    ) void {
        { // Setup quad vertex info buffer
            const mapped_buffer = self.quad_buffer_vertex.map(QuadBufferVertexBuffer, gfx.context) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data.* = QuadBufferVertexBuffer {
                .quad_bounds = Bounds {
                    .left = ((@as(f32, @floatFromInt(rect_pixels.left)) / @as(f32, @floatFromInt(rtv_width))) * 2.0) - 1.0,
                    .right = ((@as(f32, @floatFromInt(rect_pixels.left + rect_pixels.width)) / @as(f32, @floatFromInt(rtv_width))) * 2.0) - 1.0,
                    .bottom = ((@as(f32, @floatFromInt(rect_pixels.bottom)) / @as(f32, @floatFromInt(rtv_height))) * 2.0) - 1.0,
                    .top = ((@as(f32, @floatFromInt(rect_pixels.bottom + rect_pixels.height)) / @as(f32, @floatFromInt(rtv_height))) * 2.0) - 1.0,
                },
            };
        }
        { // Setup quad pixel info buffer
            const mapped_buffer = self.quad_buffer_pixel.map(QuadBufferPixelBuffer, gfx.context) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data.* = QuadBufferPixelBuffer {
                .colour = props.colour,
            };
        }

        const viewport = d3d11.VIEWPORT {
            .Width = @floatFromInt(rtv_width),
            .Height = @floatFromInt(rtv_height),
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
