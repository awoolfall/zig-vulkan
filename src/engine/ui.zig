const std = @import("std");
const win32 = @import("zwin32");
const d3d11 = win32.d3d11;
const zstbi = @import("zstbi");
const gfx_d3d11 = @import("../gfx/d3d11.zig");
const zm = @import("zmath");

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

pub const UiRenderer = struct {
    _allocator: std.mem.Allocator,
    sampler: *d3d11.ISamplerState,
    rasterizer_state: *d3d11.IRasterizerState,
    blend_state: *d3d11.IBlendState,

    quad_vso: *d3d11.IVertexShader,
    quad_input_layout: *d3d11.IInputLayout,
    quad_pso: *d3d11.IPixelShader,
    quad_buffer_vertex: *d3d11.IBuffer,
    quad_buffer_pixel: *d3d11.IBuffer,

    const QUAD_SHADER_HLSL = @embedFile("quad_shader.hlsl");

    pub fn deinit(self: *const UiRenderer) void {
        _ = self.blend_state.Release();
        _ = self.rasterizer_state.Release();
        _ = self.sampler.Release();

        _ = self.quad_buffer_vertex.Release();
        _ = self.quad_buffer_pixel.Release();
        _ = self.quad_input_layout.Release();
        _ = self.quad_vso.Release();
        _ = self.quad_pso.Release();
    }

    pub fn init(alloc: std.mem.Allocator, gfx: *gfx_d3d11.D3D11State) !UiRenderer {
        // construct ui object
        var ui = UiRenderer {
            ._allocator = alloc,
            .sampler = undefined,
            .rasterizer_state = undefined,
            .blend_state = undefined,

            .quad_vso = undefined,
            .quad_input_layout = undefined,
            .quad_pso = undefined,
            .quad_buffer_vertex = undefined,
            .quad_buffer_pixel = undefined,
        };

        // create the quad shaders
        var quad_vs_blob: *win32.d3d.IBlob = undefined;
        try win32.hrErrorOnFail(win32.d3dcompiler.D3DCompile(&QUAD_SHADER_HLSL[0], QUAD_SHADER_HLSL.len, null, null, null, "vs_main", "vs_5_0", 0, 0, @ptrCast(&quad_vs_blob), null));
        defer _ = quad_vs_blob.Release();

        try win32.hrErrorOnFail(gfx.device.CreateVertexShader(quad_vs_blob.GetBufferPointer(), quad_vs_blob.GetBufferSize(), null, @ptrCast(&ui.quad_vso)));
        errdefer _ = ui.quad_vso.Release();

        var quad_ps_blob: *win32.d3d.IBlob = undefined;
        try win32.hrErrorOnFail(win32.d3dcompiler.D3DCompile(&QUAD_SHADER_HLSL[0], QUAD_SHADER_HLSL.len, null, null, null, "ps_main", "ps_5_0", 0, 0, @ptrCast(&quad_ps_blob), null));
        defer _ = quad_ps_blob.Release();

        try win32.hrErrorOnFail(gfx.device.CreatePixelShader(quad_ps_blob.GetBufferPointer(), quad_ps_blob.GetBufferSize(), null, @ptrCast(&ui.quad_pso)));
        errdefer _ = ui.quad_pso.Release();

        // create vertex input layout
        const quad_input_layout_desc = [_]d3d11.INPUT_ELEMENT_DESC {
        };
        try win32.hrErrorOnFail(gfx.device.CreateInputLayout(quad_input_layout_desc[0..], quad_input_layout_desc.len, quad_vs_blob.GetBufferPointer(), quad_vs_blob.GetBufferSize(), @ptrCast(&ui.quad_input_layout)));
        errdefer _ = ui.quad_input_layout.Release();

        // create quad constant buffers
        const quad_buffer_vertex_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(QuadBufferVertexBuffer),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        try win32.hrErrorOnFail(gfx.device.CreateBuffer(&quad_buffer_vertex_desc, null, @ptrCast(&ui.quad_buffer_vertex)));
        errdefer _ = ui.quad_buffer_vertex.Release();

        const quad_buffer_pixel_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(QuadBufferPixelBuffer),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        try win32.hrErrorOnFail(gfx.device.CreateBuffer(&quad_buffer_pixel_desc, null, @ptrCast(&ui.quad_buffer_pixel)));
        errdefer _ = ui.quad_buffer_pixel.Release();

        // create sampler
        const sampler_desc = d3d11.SAMPLER_DESC {
            .Filter = d3d11.FILTER.MIN_MAG_LINEAR_MIP_POINT,
            .AddressU = d3d11.TEXTURE_ADDRESS_MODE.WRAP,
            .AddressV = d3d11.TEXTURE_ADDRESS_MODE.WRAP,
            .AddressW = d3d11.TEXTURE_ADDRESS_MODE.WRAP,
            .MipLODBias = 0.0,
            .MaxAnisotropy = 1,
            .ComparisonFunc = d3d11.COMPARISON_FUNC.NEVER,
            .BorderColor = [4]win32.w32.FLOAT{0.0, 0.0, 0.0, 1.0},
            .MinLOD = 0.0,
            .MaxLOD = 0.0,
        };
        try win32.hrErrorOnFail(gfx.device.CreateSamplerState(&sampler_desc, @ptrCast(&ui.sampler)));
        errdefer _ = ui.sampler.Release();

        // create rasterizer state
        var rasterizer_state_desc = d3d11.RASTERIZER_DESC {
            .FillMode = d3d11.FILL_MODE.SOLID,
            .CullMode = d3d11.CULL_MODE.BACK,
            .FrontCounterClockwise = 1,
        };
        try win32.hrErrorOnFail(gfx.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&ui.rasterizer_state)));
        errdefer _ = ui.rasterizer_state.Release();

        // create blend state
        var blend_state_desc = d3d11.BLEND_DESC {
            .AlphaToCoverageEnable = 0,
            .IndependentBlendEnable = 0,
            .RenderTarget = [_]d3d11.RENDER_TARGET_BLEND_DESC {undefined} ** 8,
        };
        blend_state_desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .RenderTargetWriteMask = d3d11.COLOR_WRITE_ENABLE.ALL,
            .SrcBlend = d3d11.BLEND.SRC_ALPHA,
            .DestBlend = d3d11.BLEND.INV_SRC_ALPHA,
            .BlendOp = d3d11.BLEND_OP.ADD,
            .SrcBlendAlpha = d3d11.BLEND.ONE,
            .DestBlendAlpha = d3d11.BLEND.ZERO,
            .BlendOpAlpha = d3d11.BLEND_OP.ADD,
        };
        try win32.hrErrorOnFail(gfx.device.CreateBlendState(&blend_state_desc, @ptrCast(&ui.blend_state)));
        errdefer _ = ui.blend_state.Release();

        // finally return the ui structure
        return ui;
    }

    pub const QuadProperties = struct {
        colour: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
    };

    pub fn render_quad(
        self: *UiRenderer,
        rect_pixels: RectPixels,
        props: QuadProperties,
        rtv: *d3d11.IRenderTargetView, 
        rtv_width: i32,
        rtv_height: i32,
        gfx: *gfx_d3d11.D3D11State,
    ) void {
        { // Setup quad vertex info buffer
            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
            win32.hrPanicOnFail(gfx.context.Map(@ptrCast(self.quad_buffer_vertex), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
            defer gfx.context.Unmap(@ptrCast(self.quad_buffer_vertex), 0);

            const buffer_data: *QuadBufferVertexBuffer = @ptrCast(@alignCast(mapped_subresource.pData));
            buffer_data.* = QuadBufferVertexBuffer {
                .quad_bounds = Bounds {
                    .left = ((@as(f32, @floatFromInt(rect_pixels.left)) / @as(f32, @floatFromInt(rtv_width))) * 2.0) - 1.0,
                    .right = ((@as(f32, @floatFromInt(rect_pixels.left + rect_pixels.width)) / @as(f32, @floatFromInt(rtv_width))) * 2.0) - 1.0,
                    .bottom = ((@as(f32, @floatFromInt(rect_pixels.bottom)) / @as(f32, @floatFromInt(rtv_height))) * 2.0) - 1.0,
                    .top = ((@as(f32, @floatFromInt(rect_pixels.bottom + rect_pixels.height)) / @as(f32, @floatFromInt(rtv_height))) * 2.0) - 1.0,
                },
            };
        }
        { // Setup quad pixel info buffer
            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
            win32.hrPanicOnFail(gfx.context.Map(@ptrCast(self.quad_buffer_pixel), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
            defer gfx.context.Unmap(@ptrCast(self.quad_buffer_pixel), 0);

            const buffer_data: *QuadBufferPixelBuffer = @ptrCast(@alignCast(mapped_subresource.pData));
            buffer_data.* = QuadBufferPixelBuffer {
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

        gfx.context.PSSetShader(self.quad_pso, null, 0);

        gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), null);
        gfx.context.OMSetBlendState(@ptrCast(self.blend_state), null, 0xffffffff);

        gfx.context.VSSetShader(self.quad_vso, null, 0);
        gfx.context.IASetInputLayout(null);

        gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        gfx.context.RSSetState(self.rasterizer_state);

        gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.quad_buffer_vertex));
        gfx.context.PSSetConstantBuffers(1, 1, @ptrCast(&self.quad_buffer_pixel));
        gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler));

        gfx.context.IASetInputLayout(self.quad_input_layout);

        gfx.context.Draw(6, 0);
    }
};
