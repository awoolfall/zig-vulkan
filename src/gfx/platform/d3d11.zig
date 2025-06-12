const std = @import("std");
const builtin = @import("builtin");
const zwindows = @import("zwindows");
const d3d11 = zwindows.d3d11;
const dxgi = zwindows.dxgi;
const zm = @import("zmath");
const gf = @import("../gfx.zig");
const wb = @import("../../window.zig");
const win32window = @import("../../platform/windows.zig");
const path = @import("../../engine/path.zig");
const bloom = @import("../bloom.zig");
const RectPixels = @import("../../root.zig").Rect;

inline fn is_dbg() bool {
    return (builtin.mode == std.builtin.Mode.Debug);
}

pub const GfxStateD3D11 = struct {
    const Self = @This();

    pub const VertexShader = VertexShaderD3D11;
    pub const PixelShader = PixelShaderD3D11;
    pub const HullShader = HullShaderD3D11;
    pub const DomainShader = DomainShaderD3D11;
    pub const GeometryShader = GeometryShaderD3D11;
    pub const ComputeShader = ComputeShaderD3D11;
    pub const Buffer = BufferD3D11;
    pub const Texture2D = Texture2DD3D11;
    pub const TextureView2D = TextureView2DD3D11;
    pub const Texture3D = Texture3DD3D11;
    pub const TextureView3D = TextureView3DD3D11;
    pub const RenderTargetView = RenderTargetViewD3D11;
    pub const DepthStencilView = DepthStencilViewD3D11;
    pub const RasterizationState = RasterizationStateD3D11;
    pub const Sampler = SamplerD3D11;
    pub const BlendState = BlendStateD3D11;
    pub const ShaderResourceView = d3d11.IShaderResourceView;
    pub const UnorderedAccessView = d3d11.IUnorderedAccessView;

    device: *d3d11.IDevice,
    swapchain: *dxgi.ISwapChain,
    context: *d3d11.IDeviceContext,

    swapchain_flags: dxgi.SWAP_CHAIN_FLAG,
    vsync: bool = true,

    rasterization_states_array: [16]?RasterizationState = [_]?RasterizationState{null} ** 16,

    render_state: struct {
        rasterization_desc: gf.RasterizationStateDesc = .{},
        scissor_rect: ?RectPixels = null,
    } = .{},

    const enable_debug_layers = true;
    const swapchain_buffer_count: u32 = 3;
    const hdr_format = gf.TextureFormat.Rgba16_Float;
    const ldr_format = gf.TextureFormat.Rgba8_Unorm;
    const swapchain_format = ldr_format;

    pub fn deinit(self: *Self) void {
        std.log.debug("D3D11 deinit", .{});

        for (self.rasterization_states_array) |r| {
            if (r) |*rs| {
                rs.deinit();
            }
        }

        _ = self.swapchain.Release();
        self.context.Flush();
        _ = self.context.Release();
        _ = self.device.Release();

        // var debug: *zwindows.dxgi.IDebug1 = undefined;
        // if (zwindows.hrErrorOnFail(zwindows.dxgi.GetDebugInterface1(0, &zwindows.dxgi.IID_IDebug1, @ptrCast(&debug)))) {
        //     zwindows.hrErrorOnFail(debug.ReportLiveObjects(
        //         zwindows.dxgi.DXGI_DEBUG_ALL,
        //         zwindows.dxgi.RLO_FLAGS{ 
        //             .DETAIL = true,
        //             .IGNORE_INTERNAL = true,
        //         }
        //     )) catch |err| {
        //         std.log.warn("Dxgi debug failed to report live objects: {}", .{err});
        //     };
        //     _ = debug.Release();
        // } else |err| {
        //     std.log.warn("Unable to get dxgi debug interface: {}", .{err});
        // }
    }

    pub fn init(alloc: std.mem.Allocator, window: *win32window.Win32Window) !Self {
        _ = alloc;
        const accepted_feature_levels = [_]zwindows.d3d.FEATURE_LEVEL{
            .@"11_0", 
        };

        const window_size = try window.get_client_size();

        // TODO: check at init if allow tearing is supported by the gpu before using it
        const swapchain_flags = dxgi.SWAP_CHAIN_FLAG {
            .ALLOW_MODE_SWITCH = true,
            .ALLOW_TEARING = true,
        };

        const swapchain_desc = dxgi.SWAP_CHAIN_DESC {
            .BufferDesc = dxgi.MODE_DESC {
                .Width = @intCast(window_size.width),
                .Height = @intCast(window_size.height),
                .Format = texture_format_to_d3d11(swapchain_format),
                .Scaling = dxgi.MODE_SCALING.STRETCHED,
                .RefreshRate = dxgi.RATIONAL{
                    .Numerator = 0,
                    .Denominator = 1,
                },
                .ScanlineOrdering = dxgi.MODE_SCANLINE_ORDER.UNSPECIFIED,
            },
            .SampleDesc = dxgi.SAMPLE_DESC {
                .Count = 1,
                .Quality = 0,
            },
            .BufferUsage = dxgi.USAGE {
                .RENDER_TARGET_OUTPUT = true,
            },
            .BufferCount = swapchain_buffer_count,
            .OutputWindow = window.hwnd,
            .Windowed = zwindows.windows.TRUE,
            .SwapEffect = dxgi.SWAP_EFFECT.FLIP_DISCARD,
            .Flags = swapchain_flags,
        };

        var device: *d3d11.IDevice = undefined;
        var swapchain: *dxgi.ISwapChain = undefined;
        var feature_level = zwindows.d3d.FEATURE_LEVEL.@"1_0_CORE";
        var context: *d3d11.IDeviceContext = undefined;

        // Attempt to create the device and swapchain with feature level 11_1.
        attempt_create_device_and_swapchain(
            &[_]zwindows.d3d.FEATURE_LEVEL{ .@"11_1" },
            swapchain_desc,
            @ptrCast(&swapchain),
            @ptrCast(&device),
            @ptrCast(&feature_level),
            @ptrCast(&context)
        ) catch |err| {
            std.log.warn("Failed to create at feature level 11_1", .{});
            // If 11_1 is not available the above call will fail, then try creating at other levels
            if (err == zwindows.windows.Error.INVALIDARG) {
                std.log.warn("Recreating at a lower level", .{});
                try attempt_create_device_and_swapchain(
                    accepted_feature_levels[0..], 
                    swapchain_desc,
                    @ptrCast(&swapchain),
                    @ptrCast(&device),
                    @ptrCast(&feature_level),
                    @ptrCast(&context)); 
            } else {
                return err;
            }
        };

        std.log.info("Swapchain, device, context created! at level: {}", .{feature_level});

        // Create reverse Z depth stencil state
        var depth_stencil_state: *d3d11.IDepthStencilState = undefined;
        try zwindows.hrErrorOnFail(device.CreateDepthStencilState(&d3d11.DEPTH_STENCIL_DESC {
            .DepthEnable = zwindows.windows.TRUE,
            .DepthWriteMask = d3d11.DEPTH_WRITE_MASK.ALL,
            .DepthFunc = d3d11.COMPARISON_FUNC.GREATER_EQUAL,
            .StencilEnable = 0,
            .StencilReadMask = 0,
            .StencilWriteMask = 0,
            .FrontFace = d3d11.DEPTH_STENCILOP_DESC {
                .StencilFailOp = d3d11.STENCIL_OP.KEEP,
                .StencilDepthFailOp = d3d11.STENCIL_OP.KEEP,
                .StencilPassOp = d3d11.STENCIL_OP.KEEP,
                .StencilFunc = d3d11.COMPARISON_FUNC.ALWAYS,
            },
            .BackFace = d3d11.DEPTH_STENCILOP_DESC {
                .StencilFailOp = d3d11.STENCIL_OP.KEEP,
                .StencilDepthFailOp = d3d11.STENCIL_OP.KEEP,
                .StencilPassOp = d3d11.STENCIL_OP.KEEP,
                .StencilFunc = d3d11.COMPARISON_FUNC.ALWAYS,
            },
        }, @ptrCast(&depth_stencil_state)));
        defer _ = depth_stencil_state.Release();

        context.OMSetDepthStencilState(@ptrCast(depth_stencil_state), 0);

        return Self {
            .device = device,
            .swapchain = swapchain,
            .swapchain_flags = swapchain_flags,
            .context = context,
        };
    }

    fn attempt_create_device_and_swapchain(
        accepted_feature_levels: []const zwindows.d3d.FEATURE_LEVEL,
        swapchain_desc: dxgi.SWAP_CHAIN_DESC,
        swapchain: ?*?*dxgi.ISwapChain,
        device: ?*?*d3d11.IDevice,
        feature_level: ?*zwindows.d3d.FEATURE_LEVEL,
        context: ?*?*d3d11.IDeviceContext,
    ) !void {
        if (is_dbg() and enable_debug_layers) {
            std.log.debug("enabling d3d11 debug layers", .{});
        }
        try zwindows.hrErrorOnFail(d3d11.D3D11CreateDeviceAndSwapChain(
                null,
                zwindows.d3d.DRIVER_TYPE.HARDWARE, 
                null,
                d3d11.CREATE_DEVICE_FLAG {
                    .DEBUG = (is_dbg() and enable_debug_layers),
                    .BGRA_SUPPORT = true,
                    .PREVENT_ALTERING_LAYER_SETTINGS_FROM_REGISTRY = !is_dbg(),
                }, 
                accepted_feature_levels.ptr,
                @intCast(accepted_feature_levels.len),
                d3d11.SDK_VERSION,
                &swapchain_desc, 
                swapchain,
                device,
                feature_level,
                context
        ));
    }

    pub fn create_texture2d_from_framebuffer(self: *Self, gfx: *gf.GfxState) !gf.Texture2D {
        var framebuffer: *d3d11.ITexture2D = undefined;
        zwindows.hrPanicOnFail(self.swapchain.GetBuffer(0, &d3d11.IID_ITexture2D, @ptrCast(&framebuffer)));

        return gf.Texture2D {
            .platform = Self.Texture2D {
                .texture = framebuffer,
            },
            .desc = gf.Texture2D.Descriptor {
                .width = @intCast(gfx.swapchain_size.width),
                .height = @intCast(gfx.swapchain_size.height),
                .format = gf.TextureFormat.Rgba8_Unorm_Srgb,
            },
            .usage_flags = .{ .RenderTarget = true },
            .access_flags = .{},
        };
    }

    fn create_hdr_rtv_texture2d_from_framebuffer(self: *Self) !gf.Texture2D {
        return try gf.Texture2D.init(
            .{ 
                .height = @intCast(self.swapchain_size.height),
                .width = @intCast(self.swapchain_size.width),
                .format = hdr_format,
            },
            .{ .RenderTarget = true, .ShaderResource = true, },
            .{ .GpuWrite = true, },
            null,
            self
        );
    }

    pub inline fn begin_frame(self: *Self) !gf.RenderTargetView {
        return self.hdr_rtv;
    }

    pub inline fn get_framebuffer(self: *Self) *gf.RenderTargetView {
        return &self.framebuffer_rtv;
    }

    pub inline fn present(self: *Self) !void {
        if (self.vsync) {
            try zwindows.hrErrorOnFail(self.swapchain.Present(1, dxgi.PRESENT_FLAG { .ALLOW_TEARING = false, }));
        } else {
            try zwindows.hrErrorOnFail(self.swapchain.Present(0, dxgi.PRESENT_FLAG { .ALLOW_TEARING = true, }));
        }
    }

    pub inline fn flush(self: *Self) void {
        self.context.Flush();
    }

    pub inline fn clear_state(self: *Self) void {
        self.context.ClearState();
    }

    fn get_rasterization_state(self: *Self, desc: gf.RasterizationStateDesc) RasterizationState {
        const rasterization_state_desc = D3D11RasterizationStateDesc {
            .gfx = desc,
            .scissor_enable = (self.render_state.scissor_rect != null),
        };
        const index: usize = @intCast(@as(u4, @bitCast(rasterization_state_desc)));
        if (self.rasterization_states_array[index]) |r| {
            return r;
        } else {
            const r = RasterizationState.init(rasterization_state_desc, self) catch unreachable;
            self.rasterization_states_array[index] = r;
            return r;
        }
    }
    
    pub inline fn resize_swapchain(self: *Self, new_width: i32, new_height: i32) void {
        _ = new_width;
        _ = new_height;

        self.clear_state();
        self.flush();
        zwindows.hrPanicOnFail(self.swapchain.ResizeBuffers(
                0, 0, 0, dxgi.FORMAT.UNKNOWN, // automatic
                self.swapchain_flags)); 
    }

    pub inline fn cmd_clear_render_target(self: *Self, rt: *const gf.RenderTargetView, color: zm.F32x4) void {
        self.context.ClearRenderTargetView(@ptrCast(rt.platform.view), &color);
    }

    pub inline fn cmd_clear_depth_stencil_view(self: *Self, dsv: *const gf.DepthStencilView, depth: ?f32, stencil: ?u8) void {
        self.context.ClearDepthStencilView(
            @ptrCast(dsv.platform.view), 
            d3d11.CLEAR_FLAG {
                .CLEAR_DEPTH = (depth != null),
                .CLEAR_STENCIL = (stencil != null),
            }, 
            if (depth) |d| d else 0.0,
            if (stencil) |s| s else 0
        );
    }

    pub inline fn cmd_set_viewport(self: *Self, viewport: gf.Viewport) void {
        const d3d11_viewport = d3d11.VIEWPORT {
            .Width = viewport.width,
            .Height = viewport.height,
            .TopLeftX = viewport.top_left_x,
            .TopLeftY = viewport.top_left_y,
            .MinDepth = viewport.min_depth,
            .MaxDepth = viewport.max_depth,
        };
        self.context.RSSetViewports(1, @ptrCast(&d3d11_viewport));
    }

    pub inline fn cmd_set_scissor_rect(self: *Self, scissor: ?RectPixels) void {
        self.render_state.scissor_rect = scissor;
    }

    fn apply_scissor_rect(self: *Self) void {
        if (self.render_state.scissor_rect) |s| {
            self.context.RSSetScissorRects(1, @ptrCast(&rect_to_d3d11(s)));
        } else {
        }
    }

    pub inline fn cmd_set_render_target(self: *Self, rtvs: []const ?*const gf.RenderTargetView, depth_stencil_view: ?*const gf.DepthStencilView) void {
        std.debug.assert(rtvs.len <= 8);
        var d3d11_rtvs: [8]?*d3d11.IRenderTargetView = undefined;
        for (rtvs, 0..) |mr, i| {
            d3d11_rtvs[i] = if (mr) |r| @ptrCast(r.platform.view) else null;
        }
        self.context.OMSetRenderTargets(@intCast(rtvs.len), @ptrCast(&d3d11_rtvs),
            if (depth_stencil_view) |dsv| @ptrCast(dsv.platform.view) else null);
    }

    pub inline fn cmd_set_vertex_shader(self: *Self, vs: *const gf.VertexShader) void {
        self.context.VSSetShader(@ptrCast(vs.platform.vso), null, 0);
        self.context.IASetInputLayout(vs.platform.layout);
    }

    pub inline fn cmd_set_pixel_shader(self: *Self, ps: *const gf.PixelShader) void {
        self.context.PSSetShader(@ptrCast(ps.platform.pso), null, 0);
    }

    pub inline fn cmd_set_hull_shader(self: *Self, hs: ?*const gf.HullShader) void {
        self.context.HSSetShader(
            if (hs) |h| @ptrCast(h.platform.hso) else null, 
            null, 
            0
        );
    }

    pub inline fn cmd_set_domain_shader(self: *Self, ds: ?*const gf.DomainShader) void {
        self.context.DSSetShader(
            if (ds) |d| @ptrCast(d.platform.dso) else null, 
            null, 
            0
        );
    }

    pub inline fn cmd_set_geometry_shader(self: *Self, gs: ?*const gf.GeometryShader) void {
        self.context.GSSetShader(
            if (gs) |g| @ptrCast(g.platform.gso) else null, 
            null, 
            0
        );
    }

    pub inline fn cmd_set_compute_shader(self: *Self, cs: ?*const gf.ComputeShader) void {
        self.context.CSSetShader(
            if (cs) |c| @ptrCast(c.platform.cso) else null, 
            null, 
            0
        );
    }

    pub inline fn cmd_set_vertex_buffers(self: *Self, start_slot: u32, buffers: []const gf.VertexBufferInput) void {
        var d3d11_buffers: [8]*d3d11.IBuffer = undefined;
        var d3d11_strides: [8]u32 = undefined;
        var d3d11_offsets: [8]u32 = undefined;
        for (buffers, 0..) |b, i| {
            d3d11_buffers[i] = @ptrCast(b.buffer.platform.buffer);
            d3d11_strides[i] = b.stride;
            d3d11_offsets[i] = b.offset;
        }
        self.context.IASetVertexBuffers(start_slot, @intCast(buffers.len), @ptrCast(&d3d11_buffers), @ptrCast(&d3d11_strides), @ptrCast(&d3d11_offsets));
    }

    pub inline fn cmd_set_index_buffer(self: *Self, buffer: *const gf.Buffer, format: gf.IndexFormat, offset: u32) void {
        const d3d11_format = switch (format) {
            .U16 => dxgi.FORMAT.R16_UINT,
            .U32 => dxgi.FORMAT.R32_UINT,
        };
        self.context.IASetIndexBuffer(buffer.platform.buffer, d3d11_format, offset);
    }

    pub inline fn cmd_set_constant_buffers(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, buffers: []const *const gf.Buffer) void {
        var d3d11_buffers: [8]*d3d11.IBuffer = undefined;
        for (buffers, 0..) |b, i| {
            d3d11_buffers[i] = @ptrCast(b.platform.buffer);
        }
        switch (shader_stage) {
            .Vertex => self.context.VSSetConstantBuffers(start_slot, @intCast(buffers.len), @ptrCast(&d3d11_buffers)),
            .Pixel => self.context.PSSetConstantBuffers(start_slot, @intCast(buffers.len), @ptrCast(&d3d11_buffers)),
            .Hull => self.context.HSSetConstantBuffers(start_slot, @intCast(buffers.len), @ptrCast(&d3d11_buffers)),
            .Domain => self.context.DSSetConstantBuffers(start_slot, @intCast(buffers.len), @ptrCast(&d3d11_buffers)),
            .Geometry => self.context.GSSetConstantBuffers(start_slot, @intCast(buffers.len), @ptrCast(&d3d11_buffers)),
            .Compute => self.context.CSSetConstantBuffers(start_slot, @intCast(buffers.len), @ptrCast(&d3d11_buffers)),
        }
    }

    pub inline fn cmd_set_rasterizer_state(self: *Self, rs: gf.RasterizationStateDesc) void {
        self.render_state.rasterization_desc = rs;
    }

    fn apply_rasterization_state(self: *Self) void {
        const rasterization_state = self.get_rasterization_state(self.render_state.rasterization_desc);
        self.context.RSSetState(@ptrCast(rasterization_state.state));
    }

    pub inline fn cmd_set_blend_state(self: *Self, blend_state: ?*const gf.BlendState) void {
        self.context.OMSetBlendState(if (blend_state) |b| @ptrCast(b.platform.state) else null, null, 0xffffffff);
    }

    pub inline fn cmd_set_shader_resources(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, views: []const ?*const ShaderResourceView) void {
        switch (shader_stage) {
            .Vertex => self.context.VSSetShaderResources(start_slot, @intCast(views.len), @ptrCast(views)),
            .Pixel => self.context.PSSetShaderResources(start_slot, @intCast(views.len), @ptrCast(views)),
            .Hull => self.context.HSSetShaderResources(start_slot, @intCast(views.len), @ptrCast(views)),
            .Domain => self.context.DSSetShaderResources(start_slot, @intCast(views.len), @ptrCast(views)),
            .Geometry => self.context.GSSetShaderResources(start_slot, @intCast(views.len), @ptrCast(views)),
            .Compute => self.context.CSSetShaderResources(start_slot, @intCast(views.len), @ptrCast(views)),
        }
    }

    pub inline fn cmd_set_samplers(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, sampler: []const *const gf.Sampler) void {
        var d3d11_samplers: [8]*d3d11.ISamplerState = undefined;
        for (sampler, 0..) |s, i| {
            d3d11_samplers[i] = @ptrCast(s.platform.sampler);
        }
        switch (shader_stage) {
            .Vertex => unreachable,// self.context.VSSetSamplers(start_slot, @intCast(sampler.len), @ptrCast(&d3d11_samplers)),
            .Pixel => self.context.PSSetSamplers(start_slot, @intCast(sampler.len), @ptrCast(&d3d11_samplers)),
            .Hull => self.context.HSSetSamplers(start_slot, @intCast(sampler.len), @ptrCast(&d3d11_samplers)),
            .Domain => self.context.DSSetSamplers(start_slot, @intCast(sampler.len), @ptrCast(&d3d11_samplers)),
            .Geometry => self.context.GSSetSamplers(start_slot, @intCast(sampler.len), @ptrCast(&d3d11_samplers)),
            .Compute => self.context.CSSetSamplers(start_slot, @intCast(sampler.len), @ptrCast(&d3d11_samplers)),
        }
    }

    fn apply_render_state(self: *Self) void {
        self.apply_scissor_rect();
        self.apply_rasterization_state();
    }

    pub inline fn cmd_draw(self: *Self, vertex_count: u32, start_vertex: u32) void {
        self.apply_render_state();
        self.context.Draw(@intCast(vertex_count), @intCast(start_vertex));
    }

    pub inline fn cmd_draw_indexed(self: *Self, index_count: u32, start_index: u32, base_vertex: i32) void {
        self.apply_render_state();
        self.context.DrawIndexed(@intCast(index_count), @intCast(start_index), @intCast(base_vertex));
    }

    pub inline fn cmd_draw_instanced(self: *Self, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) void {
        self.apply_render_state();
        self.context.DrawInstanced(@intCast(vertex_count), @intCast(instance_count), @intCast(start_vertex), @intCast(start_instance));
    }

    pub inline fn cmd_set_topology(self: *Self, topology: gf.Topology) void {
        const d3d11_topology = switch (topology) {
            .PointList => d3d11.PRIMITIVE_TOPOLOGY.POINTLIST,
            .LineList => d3d11.PRIMITIVE_TOPOLOGY.LINELIST,
            .LineStrip => d3d11.PRIMITIVE_TOPOLOGY.LINESTRIP,
            .TriangleList => d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST,
            .TriangleStrip => d3d11.PRIMITIVE_TOPOLOGY.TRIANGLESTRIP,
        };
        self.context.IASetPrimitiveTopology(d3d11_topology);
    }

    pub inline fn cmd_set_topology_patch_list_count(self: *Self, patch_list_count: u32) void {
        std.debug.assert(patch_list_count > 0);
        std.debug.assert(patch_list_count <= 32);
        self.context.IASetPrimitiveTopology(@enumFromInt(
                @intFromEnum(d3d11.PRIMITIVE_TOPOLOGY.CONTROL_POINT_PATCHLIST) + (patch_list_count - 1)
        ));
    }

    pub inline fn cmd_set_unordered_access_views(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, views: []const ?*const UnorderedAccessView) void {
        switch (shader_stage) {
            .Compute => self.context.CSSetUnorderedAccessViews(start_slot, @intCast(views.len), @ptrCast(views), null),
            else => unreachable,
        }
    }

    pub inline fn cmd_dispatch_compute(self: *Self, num_groups_x: u32, num_groups_y: u32, num_groups_z: u32) void {
        self.context.Dispatch(@intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z));
    }

    pub inline fn cmd_copy_texture_to_texture(self: *Self, dst_texture: *const gf.Texture2D, src_texture: *const gf.Texture2D) void {
        self.context.CopyResource(@ptrCast(dst_texture.platform.texture), @ptrCast(src_texture.platform.texture));
    }
};

fn vertex_input_layout_format_to_dxgi(self: gf.VertexInputLayoutFormat) dxgi.FORMAT {
    return switch (self) {
        .F32x1 => dxgi.FORMAT.R32_FLOAT,
        .F32x2 => dxgi.FORMAT.R32G32_FLOAT,
        .F32x3 => dxgi.FORMAT.R32G32B32_FLOAT,
        .F32x4 => dxgi.FORMAT.R32G32B32A32_FLOAT,
        .I32x4 => dxgi.FORMAT.R32G32B32A32_SINT,
        .U8x4 => dxgi.FORMAT.R8G8B8A8_UNORM,
    };
}

fn vertex_input_layout_iterate_per_to_d3d11(self: gf.VertexInputLayoutIteratePer) d3d11.INPUT_CLASSIFICATION {
    return switch (self) {
        .Vertex => d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
        .Instance => d3d11.INPUT_CLASSIFICATION.INPUT_PER_INSTANCE_DATA,
    };
}

fn texture_format_to_d3d11(self: gf.TextureFormat) dxgi.FORMAT {
    return switch (self) {
        .Unknown => dxgi.FORMAT.UNKNOWN,
        .Rgba8_Unorm_Srgb => dxgi.FORMAT.R8G8B8A8_UNORM_SRGB,
        .Rgba8_Unorm => dxgi.FORMAT.R8G8B8A8_UNORM,
        .Bgra8_Unorm => dxgi.FORMAT.B8G8R8A8_UNORM,
        .R32_Float => dxgi.FORMAT.R32_FLOAT,
        .R32_Uint => dxgi.FORMAT.R32_UINT,
        .Rg32_Float => dxgi.FORMAT.R32G32_FLOAT,
        .Rgba32_Float => dxgi.FORMAT.R32G32B32A32_FLOAT,
        .Rgba16_Float => dxgi.FORMAT.R16G16B16A16_FLOAT,
        .Rg11b10_Float => dxgi.FORMAT.R11G11B10_FLOAT,
        .R24X8_Unorm_Uint => dxgi.FORMAT.R24_UNORM_X8_TYPELESS,
        .D24S8_Unorm_Uint => dxgi.FORMAT.D24_UNORM_S8_UINT,
    };
}

fn buffer_usage_flags_to_d3d11(self: gf.BufferUsageFlags) d3d11.BIND_FLAG {
    return d3d11.BIND_FLAG {
        .VERTEX_BUFFER = self.VertexBuffer,
        .INDEX_BUFFER = self.IndexBuffer,
        .CONSTANT_BUFFER = self.ConstantBuffer,
        .SHADER_RESOURCE = self.ShaderResource,
    };
}
fn texture_usage_flags_to_d3d11(self: gf.TextureUsageFlags) d3d11.BIND_FLAG {
    return d3d11.BIND_FLAG {
        .SHADER_RESOURCE = self.ShaderResource,
        .RENDER_TARGET = self.RenderTarget,
        .DEPTH_STENCIL = self.DepthStencil,
    };
}

fn access_flags_to_d3d11_usage(self: gf.AccessFlags) d3d11.USAGE {
    if (self.CpuWrite and self.GpuWrite) {
        return d3d11.USAGE.STAGING;
    } else if (self.CpuWrite and !self.GpuWrite) {
        return d3d11.USAGE.DYNAMIC;
    } else if (!self.CpuWrite and self.GpuWrite) {
        return d3d11.USAGE.DEFAULT;
    } else {
        return d3d11.USAGE.IMMUTABLE;
    }
}

fn access_flags_to_d3d11_cpu_access(self: gf.AccessFlags) d3d11.CPU_ACCCESS_FLAG {
    return d3d11.CPU_ACCCESS_FLAG {
        .READ = self.CpuRead,
        .WRITE = self.CpuWrite,
    };
}

fn sampler_border_mode_to_d3d11(self: gf.SamplerBorderMode) d3d11.TEXTURE_ADDRESS_MODE {
    return switch (self) {
        .Wrap => d3d11.TEXTURE_ADDRESS_MODE.WRAP,
        .Mirror => d3d11.TEXTURE_ADDRESS_MODE.MIRROR,
        .Clamp => d3d11.TEXTURE_ADDRESS_MODE.CLAMP,
        .BorderColour => d3d11.TEXTURE_ADDRESS_MODE.BORDER,
    };
}

fn blend_type_to_d3d11(self: gf.BlendType) d3d11.RENDER_TARGET_BLEND_DESC {
    switch (self) {
        .None => return d3d11.RENDER_TARGET_BLEND_DESC {
            .BlendEnable = 0,
            .RenderTargetWriteMask = d3d11.COLOR_WRITE_ENABLE.ALL,
            .SrcBlend = d3d11.BLEND.ONE,
            .DestBlend = d3d11.BLEND.ZERO,
            .BlendOp = d3d11.BLEND_OP.ADD,
            .SrcBlendAlpha = d3d11.BLEND.ONE,
            .DestBlendAlpha = d3d11.BLEND.ZERO,
            .BlendOpAlpha = d3d11.BLEND_OP.ADD,
        },
        .Simple => return d3d11.RENDER_TARGET_BLEND_DESC {
            .BlendEnable = 1,
            .RenderTargetWriteMask = d3d11.COLOR_WRITE_ENABLE.ALL,
            .SrcBlend = d3d11.BLEND.SRC_ALPHA,
            .DestBlend = d3d11.BLEND.INV_SRC_ALPHA,
            .BlendOp = d3d11.BLEND_OP.ADD,
            .SrcBlendAlpha = d3d11.BLEND.ZERO,
            .DestBlendAlpha = d3d11.BLEND.DEST_ALPHA,
            .BlendOpAlpha = d3d11.BLEND_OP.ADD,
        },
        .PremultipliedAlpha => return d3d11.RENDER_TARGET_BLEND_DESC {
            .BlendEnable = 1,
            .RenderTargetWriteMask = d3d11.COLOR_WRITE_ENABLE.ALL,
            .SrcBlend = d3d11.BLEND.ONE,
            .DestBlend = d3d11.BLEND.INV_SRC_ALPHA,
            .BlendOp = d3d11.BLEND_OP.ADD,
            .SrcBlendAlpha = d3d11.BLEND.ONE,
            .DestBlendAlpha = d3d11.BLEND.ZERO,
            .BlendOpAlpha = d3d11.BLEND_OP.ADD,
        },
    }
}

const D3D11ShaderMacros = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    shader_macros: []zwindows.d3d.SHADER_MACRO,

    pub fn deinit(self: *D3D11ShaderMacros) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn init(allocator: std.mem.Allocator, macros: []const gf.ShaderDefineTuple) !D3D11ShaderMacros {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const alloc = arena.allocator();

        // +1 for sentinel value, must be null
        var allocation = try alloc.alloc(zwindows.d3d.SHADER_MACRO, macros.len + 1);
        errdefer alloc.free(allocation);
        @memset(std.mem.sliceAsBytes(allocation), 0);

        for (macros, 0..) |macro, i| {
            const name = try alloc.dupeZ(u8, macro[0]);
            errdefer alloc.free(name);

            const definition = try alloc.dupeZ(u8, macro[1]);
            errdefer alloc.free(definition);

            allocation[i] = zwindows.d3d.SHADER_MACRO {
                .Name = name,
                .Definition = definition,
            };
        }

        return D3D11ShaderMacros {
            .allocator = allocator,
            .arena = arena,
            .shader_macros = allocation,
        };
    }
};

pub const VertexShaderD3D11 = struct {
    const Self = @This();
    vso: *d3d11.IVertexShader,
    layout: *d3d11.IInputLayout,
    
    pub inline fn deinit(self: *const Self) void {
        _ = self.vso.Release();
        _ = self.layout.Release();
    }

    pub inline fn init_buffer(
        vs_data: []const u8, 
        vs_func: []const u8, 
        vs_layout: []const gf.VertexInputLayoutEntry,
        options: gf.VertexShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        const vs_func_c = try std.heap.page_allocator.dupeZ(u8, vs_func);
        defer std.heap.page_allocator.free(vs_func_c);

        const source_file_path_c_alloc = if (options.filepath) |s| try std.heap.page_allocator.dupeZ(u8, s) else null;
        defer if (source_file_path_c_alloc) |s| std.heap.page_allocator.free(s);
        const source_file_path_c = if (source_file_path_c_alloc) |s| @as([*:0]u8, s) else null;

        var defines = try D3D11ShaderMacros.init(std.heap.page_allocator, options.defines);
        defer defines.deinit();

        var error_blob: ?*zwindows.d3d.IBlob = null;

        var vs_blob: *zwindows.d3d.IBlob = undefined;
        const compile_result = zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(
                &vs_data[0], 
                vs_data.len, 
                source_file_path_c, 
                &defines.shader_macros[0], 
                zwindows.d3dcompiler.COMPILE_STANDARD_FILE_INCLUDE, 
                vs_func_c, 
                "vs_5_0", 
                0, 
                0, 
                @ptrCast(&vs_blob), 
                @ptrCast(&error_blob)
        ));

        if (error_blob) |err_blob| {
            const err_blob_string = @as([*c]u8, @ptrCast(err_blob.GetBufferPointer()));
            std.log.debug("Vertex shader compilation messages: \n\n{s}", .{err_blob_string});
        }

        try compile_result;
        defer _ = vs_blob.Release();

        var vso: *d3d11.IVertexShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, @ptrCast(&vso)));
        errdefer _ = vso.Release();

        var d3d11_layout_desc = try std.BoundedArray(d3d11.INPUT_ELEMENT_DESC, 32).init(0);

        var name_arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer name_arena_allocator.deinit();

        const name_arena = name_arena_allocator.allocator();

        for (vs_layout) |*entry| {
            const name_c = try name_arena.dupeZ(u8, entry.name);

            try d3d11_layout_desc.append(d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = name_c,
                .SemanticIndex = entry.index,
                .Format = vertex_input_layout_format_to_dxgi(entry.format),
                .InputSlot = @intCast(entry.slot),
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = vertex_input_layout_iterate_per_to_d3d11(entry.per),
                .InstanceDataStepRate = @intFromBool(entry.per == .Instance),
            });
        }

        var vso_input_layout: *d3d11.IInputLayout = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateInputLayout(@ptrCast(&d3d11_layout_desc.buffer[0]), @intCast(d3d11_layout_desc.len), vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), @ptrCast(&vso_input_layout)));
        errdefer _ = vso_input_layout.Release();

        return Self {
            .vso = vso,
            .layout = vso_input_layout,
        };
    }
};

pub const PixelShaderD3D11 = struct {
    const Self = @This();
    pso: *d3d11.IPixelShader,
    
    pub inline fn deinit(self: *const Self) void {
        _ = self.pso.Release();
    }
    
    pub inline fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8, 
        options: gf.PixelShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        const ps_func_c = try std.heap.page_allocator.dupeZ(u8, ps_func);
        defer std.heap.page_allocator.free(ps_func_c);

        const source_file_path_c_alloc = if (options.filepath) |s| try std.heap.page_allocator.dupeZ(u8, s) else null;
        defer if (source_file_path_c_alloc) |s| std.heap.page_allocator.free(s);
        const source_file_path_c = if (source_file_path_c_alloc) |s| @as([*:0]u8, s) else null;

        var defines = try D3D11ShaderMacros.init(std.heap.page_allocator, options.defines);
        defer defines.deinit();

        var error_blob: ?*zwindows.d3d.IBlob = null;

        var ps_blob: *zwindows.d3d.IBlob = undefined;
        const compile_result = zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(
                &ps_data[0], 
                ps_data.len, 
                source_file_path_c, 
                &defines.shader_macros[0], 
                zwindows.d3dcompiler.COMPILE_STANDARD_FILE_INCLUDE,
                ps_func_c,
                "ps_5_0", 
                0, 
                0, 
                @ptrCast(&ps_blob), 
                @ptrCast(&error_blob)
        ));

        if (error_blob) |err_blob| {
            const err_blob_string = @as([*c]u8, @ptrCast(err_blob.GetBufferPointer()));
            std.log.debug("Pixel shader compilation messages: \n\n{s}", .{err_blob_string});
        }

        try compile_result;
        defer _ = ps_blob.Release();

        var pso: *d3d11.IPixelShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&pso)));
        errdefer _ = pso.Release();

        return Self {
            .pso = pso,
        };
    }
};

pub const HullShaderD3D11 = struct {
    const Self = @This();
    hso: *d3d11.IHullShader,
    
    pub inline fn deinit(self: *const Self) void {
        _ = self.hso.Release();
    }
    
    pub inline fn init_buffer(
        hs_data: []const u8, 
        hs_func: []const u8, 
        options: gf.HullShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        const func_c = try std.heap.page_allocator.dupeZ(u8, hs_func);
        defer std.heap.page_allocator.free(func_c);

        const source_file_path_c_alloc = if (options.filepath) |s| try std.heap.page_allocator.dupeZ(u8, s) else null;
        defer if (source_file_path_c_alloc) |s| std.heap.page_allocator.free(s);
        const source_file_path_c = if (source_file_path_c_alloc) |s| @as([*:0]u8, s) else null;

        var defines = try D3D11ShaderMacros.init(std.heap.page_allocator, options.defines);
        defer defines.deinit();

        var error_blob: ?*zwindows.d3d.IBlob = null;

        var hs_blob: *zwindows.d3d.IBlob = undefined;
        const compile_result = zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(
                &hs_data[0], 
                hs_data.len, 
                source_file_path_c, 
                &defines.shader_macros[0], 
                zwindows.d3dcompiler.COMPILE_STANDARD_FILE_INCLUDE,
                func_c,
                "hs_5_0", 
                0, 
                0, 
                @ptrCast(&hs_blob), 
                @ptrCast(&error_blob)
        ));

        if (error_blob) |err_blob| {
            const err_blob_string = @as([*c]u8, @ptrCast(err_blob.GetBufferPointer()));
            std.log.debug("Hull shader compilation messages: \n\n{s}", .{err_blob_string});
        }

        try compile_result;
        defer _ = hs_blob.Release();

        var hso: *d3d11.IHullShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateHullShader(hs_blob.GetBufferPointer(), hs_blob.GetBufferSize(), null, @ptrCast(&hso)));
        errdefer _ = hso.Release();

        return Self {
            .hso = hso,
        };
    }
};

pub const DomainShaderD3D11 = struct {
    const Self = @This();
    dso: *d3d11.IDomainShader,
    
    pub inline fn deinit(self: *const Self) void {
        _ = self.dso.Release();
    }
    
    pub inline fn init_buffer(
        ds_data: []const u8, 
        ds_func: []const u8, 
        options: gf.DomainShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        const func_c = try std.heap.page_allocator.dupeZ(u8, ds_func);
        defer std.heap.page_allocator.free(func_c);

        const source_file_path_c_alloc = if (options.filepath) |s| try std.heap.page_allocator.dupeZ(u8, s) else null;
        defer if (source_file_path_c_alloc) |s| std.heap.page_allocator.free(s);
        const source_file_path_c = if (source_file_path_c_alloc) |s| @as([*:0]u8, s) else null;

        var defines = try D3D11ShaderMacros.init(std.heap.page_allocator, options.defines);
        defer defines.deinit();

        var error_blob: ?*zwindows.d3d.IBlob = null;

        var ds_blob: *zwindows.d3d.IBlob = undefined;
        const compile_result = zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(
                &ds_data[0], 
                ds_data.len, 
                source_file_path_c, 
                &defines.shader_macros[0], 
                zwindows.d3dcompiler.COMPILE_STANDARD_FILE_INCLUDE,
                func_c,
                "ds_5_0", 
                0, 
                0, 
                @ptrCast(&ds_blob), 
                @ptrCast(&error_blob)
        ));

        if (error_blob) |err_blob| {
            const err_blob_string = @as([*c]u8, @ptrCast(err_blob.GetBufferPointer()));
            std.log.debug("Domain shader compilation messages: \n\n{s}", .{err_blob_string});
        }

        try compile_result;
        defer _ = ds_blob.Release();

        var dso: *d3d11.IDomainShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateDomainShader(ds_blob.GetBufferPointer(), ds_blob.GetBufferSize(), null, @ptrCast(&dso)));
        errdefer _ = dso.Release();

        return Self {
            .dso = dso,
        };
    }
};

pub const GeometryShaderD3D11 = struct {
    const Self = @This();
    gso: *d3d11.IGeometryShader,
    
    pub inline fn deinit(self: *const Self) void {
        _ = self.gso.Release();
    }
    
    pub inline fn init_buffer(
        gs_data: []const u8, 
        gs_func: []const u8, 
        options: gf.GeometryShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        const func_c = try std.heap.page_allocator.dupeZ(u8, gs_func);
        defer std.heap.page_allocator.free(func_c);

        const source_file_path_c_alloc = if (options.filepath) |s| try std.heap.page_allocator.dupeZ(u8, s) else null;
        defer if (source_file_path_c_alloc) |s| std.heap.page_allocator.free(s);
        const source_file_path_c = if (source_file_path_c_alloc) |s| @as([*:0]u8, s) else null;

        var defines = try D3D11ShaderMacros.init(std.heap.page_allocator, options.defines);
        defer defines.deinit();

        var error_blob: ?*zwindows.d3d.IBlob = null;

        var gs_blob: *zwindows.d3d.IBlob = undefined;
        const compile_result = zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(
                &gs_data[0], 
                gs_data.len, 
                source_file_path_c, 
                &defines.shader_macros[0], 
                zwindows.d3dcompiler.COMPILE_STANDARD_FILE_INCLUDE,
                func_c,
                "gs_5_0", 
                0, 
                0, 
                @ptrCast(&gs_blob), 
                @ptrCast(&error_blob)
        ));

        if (error_blob) |err_blob| {
            const err_blob_string = @as([*c]u8, @ptrCast(err_blob.GetBufferPointer()));
            std.log.debug("Geometry shader compilation messages: \n\n{s}", .{err_blob_string});
        }

        try compile_result;
        defer _ = gs_blob.Release();

        var gso: *d3d11.IGeometryShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateGeometryShader(gs_blob.GetBufferPointer(), gs_blob.GetBufferSize(), null, @ptrCast(&gso)));
        errdefer _ = gso.Release();

        return Self {
            .gso = gso,
        };
    }
};

pub const ComputeShaderD3D11 = struct {
    const Self = @This();
    cso: *d3d11.IComputeShader,
    
    pub inline fn deinit(self: *const Self) void {
        _ = self.cso.Release();
    }
    
    pub inline fn init_buffer(
        cs_data: []const u8, 
        cs_func: []const u8,
        options: gf.ComputeShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        const cs_func_c = try std.heap.page_allocator.dupeZ(u8, cs_func);
        defer std.heap.page_allocator.free(cs_func_c);

        const source_file_path_c_alloc = if (options.filepath) |s| try std.heap.page_allocator.dupeZ(u8, s) else null;
        defer if (source_file_path_c_alloc) |s| std.heap.page_allocator.free(s);
        const source_file_path_c = if (source_file_path_c_alloc) |s| @as([*:0]u8, s) else null;

        var defines = try D3D11ShaderMacros.init(std.heap.page_allocator, options.defines);
        defer defines.deinit();

        var error_blob: ?*zwindows.d3d.IBlob = null;

        var cs_blob: *zwindows.d3d.IBlob = undefined;
        const compile_result = zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(
                &cs_data[0], 
                cs_data.len, 
                source_file_path_c,
                &defines.shader_macros[0],
                zwindows.d3dcompiler.COMPILE_STANDARD_FILE_INCLUDE,
                cs_func_c, 
                "cs_5_0", 
                0, 
                0, 
                @ptrCast(&cs_blob),
                @ptrCast(&error_blob)
        ));

        if (error_blob) |err_blob| {
            const err_blob_string = @as([*c]u8, @ptrCast(err_blob.GetBufferPointer()));
            std.log.debug("Compute shader compilation messages: \n\n{s}", .{err_blob_string});
        }

        try compile_result;
        defer _ = cs_blob.Release();

        var cso: *d3d11.IComputeShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateComputeShader(cs_blob.GetBufferPointer(), cs_blob.GetBufferSize(), null, @ptrCast(&cso)));
        errdefer _ = cso.Release();

        return Self {
            .cso = cso,
        };
    }
};

pub const BufferD3D11 = struct {
    const Self = @This();
    buffer: *d3d11.IBuffer,  

    pub inline fn deinit(self: *const Self) void {
        _ = self.buffer.Release();
    }

    pub inline fn init(
        byte_size: u32,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
        gfx: *gf.GfxState,
    ) !Self {
        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = access_flags_to_d3d11_usage(access_flags),
            .ByteWidth = @intCast(byte_size),
            .BindFlags = buffer_usage_flags_to_d3d11(usage_flags),
            .CPUAccessFlags = access_flags_to_d3d11_cpu_access(access_flags),
        };
        var buffer: *d3d11.IBuffer = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateBuffer(&buffer_desc, null, @ptrCast(&buffer)));
        errdefer _ = buffer.Release();
        
        return Self {
            .buffer = buffer,
        };
    }
    
    pub inline fn init_with_data(
        data: []const u8,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
        gfx: *gf.GfxState,
    ) !Self {
        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = access_flags_to_d3d11_usage(access_flags),
            .ByteWidth = @intCast(data.len),
            .BindFlags = buffer_usage_flags_to_d3d11(usage_flags),
            .CPUAccessFlags = access_flags_to_d3d11_cpu_access(access_flags),
        };
        var buffer: *d3d11.IBuffer = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateBuffer(&buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = &data[0], }, @ptrCast(&buffer)));
        errdefer _ = buffer.Release();
        
        return Self {
            .buffer = buffer,
        };
    }

    pub inline fn map(self: *const Self, gfx: *gf.GfxState) !MappedBuffer {
        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.context.Map(@ptrCast(self.buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
        return MappedBuffer {
            .context = gfx.platform.context,
            .buffer = self.buffer,
            .data_ptr = mapped_subresource.pData,
        };
    }

    pub const MappedBuffer = struct {
        data_ptr: *anyopaque,
        buffer: *d3d11.IBuffer,
        context: *d3d11.IDeviceContext,

        pub inline fn unmap(self: *const MappedBuffer) void {
            self.context.Unmap(@ptrCast(self.buffer), 0);
        }

        pub inline fn data(self: *const MappedBuffer, comptime Type: type) *Type {
            return @alignCast(@ptrCast(self.data_ptr));
        }

        pub inline fn data_array(self: *const MappedBuffer, comptime Type: type, length: usize) []Type {
            return @as([*]Type, @ptrCast(self.data_ptr))[0..(length)];
        }
    };

};

pub const Texture2DD3D11 = struct {
    const Self = @This();
    texture: *d3d11.ITexture2D,

    pub inline fn deinit(self: *const Self) void {
        _ = self.texture.Release();
    }

    pub inline fn init(
        desc: gf.Texture2D.Descriptor,
        usage_flags: gf.TextureUsageFlags,
        access_flags: gf.AccessFlags,
        data: ?[]const u8,
        gfx: *gf.GfxState
    ) !Self {
        const texture_desc = d3d11.TEXTURE2D_DESC {
            .Width = @intCast(desc.width),
            .Height = @intCast(desc.height),
            .MipLevels = @intCast(desc.mip_levels),
            .ArraySize = @intCast(desc.array_length),
            .Format = texture_format_to_d3d11(desc.format),
            .SampleDesc = dxgi.SAMPLE_DESC {
                .Count = 1,
                .Quality = 0,
            },
            .Usage = access_flags_to_d3d11_usage(access_flags),
            .BindFlags = texture_usage_flags_to_d3d11(usage_flags),
            .CPUAccessFlags = access_flags_to_d3d11_cpu_access(access_flags),
            .MiscFlags = d3d11.RESOURCE_MISC_FLAG {},
        };
        var texture: *d3d11.ITexture2D = undefined;
        if (data) |d| {
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateTexture2D(
                    &texture_desc, 
                    &d3d11.SUBRESOURCE_DATA {
                        .pSysMem = @ptrCast(d), 
                        .SysMemPitch = @intCast(desc.width * desc.format.byte_width()),
                    }, 
                    @ptrCast(&texture)
            ));
        } else {
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateTexture2D(
                    &texture_desc, 
                    null,
                    @ptrCast(&texture)
            ));
        }
        errdefer _ = texture.Release();

        return Self {
            .texture = texture,
        };
    }

    pub inline fn map_read(self: *const Self, comptime OutType: type, gfx: *gf.GfxState) !MappedTexture(OutType) {
        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.context.Map(@ptrCast(self.texture), 0, d3d11.MAP.READ, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
        return MappedTexture(OutType) {
            .context = gfx.platform.context,
            .texture = self.texture,
            .data_ptr = @ptrCast(@alignCast(mapped_subresource.pData)),
        };
    }

    pub inline fn map_write_discard(self: *const Self, comptime OutType: type, gfx: *gf.GfxState) !MappedTexture(OutType) {
        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.context.Map(@ptrCast(self.texture), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
        return MappedTexture(OutType) {
            .context = gfx.platform.context,
            .texture = self.texture,
            .data_ptr = @ptrCast(@alignCast(mapped_subresource.pData)),
        };
    }

    pub fn MappedTexture(comptime T: type) type {
        return struct {
            data_ptr: *align(16)T,
            texture: *d3d11.ITexture2D,
            context: *d3d11.IDeviceContext,

            pub inline fn unmap(self: *const MappedTexture(T)) void {
                self.context.Unmap(@ptrCast(self.texture), 0);
            }
            
            pub inline fn data(self: *const MappedTexture(T)) [*]align(16)T {
                return @as([*]align(16)T, @ptrCast(self.data_ptr));
            }
        };
    }
};

pub const TextureView2DD3D11 = struct {
    const Self = @This();
    srv: ?*d3d11.IShaderResourceView,
    uav: ?*d3d11.IUnorderedAccessView,

    pub inline fn deinit(self: *const Self) void {
        if (self.srv) |v| { _ = v.Release(); }
        if (self.uav) |v| { _ = v.Release(); }
    }

    pub inline fn init_from_texture2d(texture: *const gf.Texture2D, gfx: *gf.GfxState) !Self {
        var srv: ?*d3d11.IShaderResourceView = null;
        if (texture.usage_flags.ShaderResource) {
            const texture_resource_view_desc = d3d11.SHADER_RESOURCE_VIEW_DESC {
                .Format = texture_format_to_d3d11(texture.desc.format),
                .ViewDimension = d3d11.SRV_DIMENSION.TEXTURE2D,
                .u = .{
                    .Texture2D = d3d11.TEX2D_SRV {
                        .MostDetailedMip = 0,
                        .MipLevels = texture.desc.mip_levels,
                    },
                    },
                };
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateShaderResourceView(
                    @ptrCast(texture.platform.texture), 
                    &texture_resource_view_desc, 
                    @ptrCast(&srv)
            ));
        }
        errdefer { if (srv) |v| _ = v.Release(); }

        var uav: ?*d3d11.IUnorderedAccessView = null;
        if (texture.usage_flags.UnorderedAccess) {
            const uav_desc = d3d11.UNORDERED_ACCESS_VIEW_DESC {
                .Format = texture_format_to_d3d11(texture.desc.format),
                .ViewDimension = d3d11.UAV_DIMENSION.TEXTURE2D,
                .u = .{
                    .Texture2D = d3d11.TEX2D_UAV {
                        .MipSlice = 0,
                    },
                },
            };
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateUnorderedAccessView(
                    @ptrCast(texture.platform.texture), 
                    &uav_desc,
                    @ptrCast(&uav)
            ));
        }
        errdefer { if (uav) |v| _ = v.Release(); }

        return Self {
            .srv = srv,
            .uav = uav,
        };
    }

    pub fn shader_resource_view(self: *const Self) *const GfxStateD3D11.ShaderResourceView {
        std.debug.assert(self.srv != null);
        return self.srv.?;
    }

    pub fn unordered_access_view(self: *const Self) *const GfxStateD3D11.UnorderedAccessView {
        std.debug.assert(self.uav != null);
        return self.uav.?;
    }
};

pub const TextureView3DD3D11 = struct {
    const Self = @This();
    srv: ?*d3d11.IShaderResourceView,
    uav: ?*d3d11.IUnorderedAccessView,

    pub inline fn deinit(self: *const Self) void {
        if (self.srv) |v| { _ = v.Release(); }
        if (self.uav) |v| { _ = v.Release(); }
    }

    pub inline fn init_from_texture3d(texture: *const gf.Texture3D, gfx: *gf.GfxState) !Self {
        var srv: ?*d3d11.IShaderResourceView = null;
        if (texture.usage_flags.ShaderResource) {
            const texture_resource_view_desc = d3d11.SHADER_RESOURCE_VIEW_DESC {
                .Format = texture_format_to_d3d11(texture.desc.format),
                .ViewDimension = d3d11.SRV_DIMENSION.TEXTURE3D,
                .u = .{
                    .Texture3D = d3d11.TEX3D_SRV {
                        .MostDetailedMip = 0,
                        .MipLevels = texture.desc.mip_levels,
                    },
                    },
                };
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateShaderResourceView(
                    @ptrCast(texture.platform.texture), 
                    &texture_resource_view_desc, 
                    @ptrCast(&srv)
            ));
        }
        errdefer { if (srv) |v| _ = v.Release(); }

        var uav: ?*d3d11.IUnorderedAccessView = null;
        if (texture.usage_flags.UnorderedAccess) {
            const uav_desc = d3d11.UNORDERED_ACCESS_VIEW_DESC {
                .Format = texture_format_to_d3d11(texture.desc.format),
                .ViewDimension = d3d11.UAV_DIMENSION.TEXTURE3D,
                .u = .{
                    .Texture3D = d3d11.TEX3D_UAV {
                        .MipSlice = 0,
                        .FirstWSlice = 0,
                        .WSize = texture.desc.depth,
                    },
                },
            };
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateUnorderedAccessView(
                    @ptrCast(texture.platform.texture), 
                    &uav_desc,
                    @ptrCast(&uav)
            ));
        }
        errdefer { if (uav) |v| _ = v.Release(); }

        return Self {
            .srv = srv,
            .uav = uav,
        };
    }

    pub fn shader_resource_view(self: *const Self) *const GfxStateD3D11.ShaderResourceView {
        std.debug.assert(self.srv != null);
        return self.srv.?;
    }

    pub fn unordered_access_view(self: *const Self) *const GfxStateD3D11.UnorderedAccessView {
        std.debug.assert(self.uav != null);
        return self.uav.?;
    }
};

pub const Texture3DD3D11 = struct {
    const Self = @This();
    texture: *d3d11.ITexture3D,

    pub inline fn deinit(self: *const Self) void {
        _ = self.texture.Release();
    }

    pub inline fn init(
        desc: gf.Texture3D.Descriptor,
        usage_flags: gf.TextureUsageFlags,
        access_flags: gf.AccessFlags,
        data: ?[]const u8,
        gfx: *gf.GfxState
    ) !Self {
        const texture_desc = d3d11.TEXTURE3D_DESC {
            .Width = @intCast(desc.width),
            .Height = @intCast(desc.height),
            .Depth = @intCast(desc.depth),
            .MipLevels = @intCast(desc.mip_levels),
            .Format = texture_format_to_d3d11(desc.format),
            .Usage = access_flags_to_d3d11_usage(access_flags),
            .BindFlags = texture_usage_flags_to_d3d11(usage_flags),
            .CPUAccessFlags = access_flags_to_d3d11_cpu_access(access_flags),
            .MiscFlags = d3d11.RESOURCE_MISC_FLAG {},
        };
        var texture: *d3d11.ITexture3D = undefined;
        if (data) |d| {
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateTexture3D(
                    &texture_desc, 
                    &d3d11.SUBRESOURCE_DATA {
                        .pSysMem = @ptrCast(d), 
                        .SysMemPitch = @intCast(desc.width * desc.format.byte_width()),
                        .SysMemSlicePitch = @intCast(desc.width * desc.height * desc.format.byte_width()),
                    }, 
                    @ptrCast(&texture)
            ));
        } else {
            try zwindows.hrErrorOnFail(gfx.platform.device.CreateTexture3D(
                    &texture_desc, 
                    null,
                    @ptrCast(&texture)
            ));
        }
        errdefer _ = texture.Release();

        return Self {
            .texture = texture,
        };
    }

    pub inline fn map(self: *const Self, comptime OutType: type, gfx: *gf.GfxState) !MappedTexture(OutType) {
        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.context.Map(@ptrCast(self.texture), 0, d3d11.MAP.READ, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
        return MappedTexture(OutType) {
            .context = gfx.platform.context,
            .texture = self.texture,
            .data_ptr = @ptrCast(@alignCast(mapped_subresource.pData)),
        };
    }

    pub fn MappedTexture(comptime T: type) type {
        return struct {
            data_ptr: *T,
            texture: *d3d11.ITexture3D,
            context: *d3d11.IDeviceContext,

            pub inline fn unmap(self: *const MappedTexture(T)) void {
                self.context.Unmap(@ptrCast(self.texture), 0);
            }
            
            pub inline fn data(self: *const MappedTexture(T)) [*]align(1)T {
                return @as([*]align(1)T, @ptrCast(self.data_ptr));
            }
        };
    }
};

pub const RenderTargetViewD3D11 = struct {
    const Self = @This();
    view: *d3d11.IRenderTargetView,
    size: struct { width: u32, height: u32, depth: u32, },

    pub inline fn deinit(self: *const Self) void {
        _ = self.view.Release();
    }

    pub inline fn init_from_texture2d(texture: *const gf.Texture2D, gfx: *gf.GfxState) !Self {
        return init_from_texture2d_mip(texture, 0, gfx);
    }

    pub inline fn init_from_texture2d_mip(texture: *const gf.Texture2D, mip_level: u32, gfx: *gf.GfxState) !Self {
        var rtv: *d3d11.IRenderTargetView = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateRenderTargetView(
                @ptrCast(texture.platform.texture), 
                &d3d11.RENDER_TARGET_VIEW_DESC{
                    .ViewDimension = d3d11.RTV_DIMENSION.TEXTURE2D,
                    .Format = texture_format_to_d3d11(texture.desc.format),
                    .u = .{.Texture2D = d3d11.TEX2D_RTV {
                        .MipSlice = mip_level,
                    }},
                }, 
                @ptrCast(&rtv)
        ));

        return Self {
            .view = rtv,
            .size = .{
                .width = texture.desc.width / std.math.pow(u32, 2, mip_level),
                .height = texture.desc.height / std.math.pow(u32, 2, mip_level),
                .depth = 1,
            },
        };
    }

    pub fn init_from_texture3d(texture: *const gf.Texture3D, gfx: *gf.GfxState) !Self {
        var rtv: *d3d11.IRenderTargetView = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateRenderTargetView(
                @ptrCast(texture.platform.texture), 
                &d3d11.RENDER_TARGET_VIEW_DESC{
                    .ViewDimension = d3d11.RTV_DIMENSION.TEXTURE3D,
                    .Format = texture_format_to_d3d11(texture.desc.format),
                    .u = .{.Texture3D = d3d11.TEX3D_RTV {
                        .MipSlice = 0,
                        .FirstWSlice = 0,
                        .WSize = texture.desc.depth,
                    }},
                }, 
                @ptrCast(&rtv)
        ));

        return Self {
            .view = rtv,
            .size = .{
                .width = texture.desc.width,
                .height = texture.desc.height,
                .depth = texture.desc.depth,
            },
        };
    }
};

pub const DepthStencilViewD3D11 = struct {
    const Self = @This();
    view: *d3d11.IDepthStencilView,

    pub inline fn deinit(self: *const Self) void {
        _ = self.view.Release();
    }

    pub inline fn init_from_texture2d(
        texture: *const gf.Texture2D, 
        flags: gf.DepthStencilView.Flags,
        gfx: *gf.GfxState
    ) !Self {
        const depth_stencil_desc = d3d11.DEPTH_STENCIL_VIEW_DESC {
            .Format = texture_format_to_d3d11(texture.desc.format),
            .ViewDimension = d3d11.DSV_DIMENSION.TEXTURE2D,
            .u = .{
                .Texture2D = d3d11.TEX2D_DSV {
                    .MipSlice = 0,
                },
            },
            .Flags = d3d11.DSV_FLAGS {
                .READ_ONLY_DEPTH = flags.read_only_depth,
                .READ_ONLY_STENCIL = flags.read_only_stencil,
            },
        };
        var depth_stencil_view: *d3d11.IDepthStencilView = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateDepthStencilView(@ptrCast(texture.platform.texture), &depth_stencil_desc, @ptrCast(&depth_stencil_view)));
        errdefer _ = depth_stencil_view.Release();

        return Self {
            .view = depth_stencil_view,
        };
    }
};

const D3D11RasterizationStateDesc = packed struct(u4) {
    gfx: gf.RasterizationStateDesc,
    scissor_enable: bool = false,
};

pub const RasterizationStateD3D11 = struct {
    const Self = @This();
    state: *d3d11.IRasterizerState,

    pub inline fn deinit(self: *const Self) void {
        _ = self.state.Release();
    }

    pub inline fn init(desc: D3D11RasterizationStateDesc, gfx: *GfxStateD3D11) !Self {
        var rasterizer_state_desc = d3d11.RASTERIZER_DESC {
            .FillMode = blk: {
                if (!desc.gfx.FillBack and !desc.gfx.FillFront) {
                    break :blk d3d11.FILL_MODE.WIREFRAME;
                } else {
                    break :blk d3d11.FILL_MODE.SOLID;
                }
            },
            .CullMode = blk: {
                if (desc.gfx.FillBack == desc.gfx.FillFront) {
                    break :blk d3d11.CULL_MODE.NONE;
                } else if (!desc.gfx.FillBack) {
                    break :blk d3d11.CULL_MODE.BACK;
                } else {
                    break :blk d3d11.CULL_MODE.FRONT;
                }
            },
            .FrontCounterClockwise = @intFromBool(desc.gfx.FrontCounterClockwise),
            .ScissorEnable = @intFromBool(desc.scissor_enable),
        };

        var rasterization_state: *d3d11.IRasterizerState = undefined;
        try zwindows.hrErrorOnFail(gfx.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterization_state)));
        errdefer _ = rasterization_state.Release();

        return Self {
            .state = rasterization_state,
        };
    }
};

pub const SamplerD3D11 = struct {
    const Self = @This();
    sampler: *d3d11.ISamplerState,

    pub inline fn deinit(self: *const Self) void {
        _ = self.sampler.Release();
    }

    pub inline fn init(desc: gf.SamplerDescriptor, gfx: *gf.GfxState) !Self {
        const d3d11_filter = blk: {
            if (desc.anisotropic_filter) {
                break :blk d3d11.FILTER.ANISOTROPIC;
            }
            switch (desc.filter_min_mag) {
                .Point => {
                    switch (desc.filter_mip) {
                        .Point => break :blk d3d11.FILTER.MIN_MAG_MIP_POINT,
                        .Linear => break :blk d3d11.FILTER.MIN_MAG_POINT_MIP_LINEAR,
                    }
                },
                .Linear => {
                    switch (desc.filter_mip) {
                        .Point => break :blk d3d11.FILTER.MIN_MAG_LINEAR_MIP_POINT,
                        .Linear => break :blk d3d11.FILTER.MIN_MAG_MIP_LINEAR,
                    }
                },
            }
        };

        const sampler_desc = d3d11.SAMPLER_DESC {
            .Filter = d3d11_filter,
            .AddressU = sampler_border_mode_to_d3d11(desc.border_mode),
            .AddressV = sampler_border_mode_to_d3d11(desc.border_mode),
            .AddressW = sampler_border_mode_to_d3d11(desc.border_mode),
            .MaxAnisotropy = 1, // @TODO: setting from gfx?
            .BorderColor = desc.border_colour,
            .MipLODBias = 0.0,
            .ComparisonFunc = .NEVER,
            .MinLOD = desc.min_lod,
            .MaxLOD = desc.max_lod,
        };
        var sampler: *d3d11.ISamplerState = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateSamplerState(&sampler_desc, @ptrCast(&sampler)));
        errdefer _ = sampler.Release();

        return Self {
            .sampler = sampler,
        };
    }
};

pub const BlendStateD3D11 = struct {
    const Self = @This();
    state: *d3d11.IBlendState,

    pub inline fn deinit(self: *const Self) void {
        _ = self.state.Release();
    }

    pub inline fn init(render_target_blend_types: []const gf.BlendType, gfx: *const gf.GfxState) !Self {
        var blend_state_desc = d3d11.BLEND_DESC {
            .AlphaToCoverageEnable = 0,
            .IndependentBlendEnable = 0,
            .RenderTarget = [_]d3d11.RENDER_TARGET_BLEND_DESC {blend_type_to_d3d11(gf.BlendType.None)} ** 8,
        };
        for (render_target_blend_types, 0..) |t, i| {
            blend_state_desc.RenderTarget[i] = blend_type_to_d3d11(t);
        }

        var blend_state: *d3d11.IBlendState = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateBlendState(&blend_state_desc, @ptrCast(&blend_state)));
        errdefer _ = blend_state.Release();

        return Self {
            .state = blend_state,
        };
    }
};

inline fn rect_to_d3d11(rect: RectPixels) d3d11.RECT {
    return .{
        .left = @intFromFloat(@round(rect.left)),
        .right = @intFromFloat(@round(rect.right)),
        .top = @intFromFloat(@round(rect.top)),
        .bottom = @intFromFloat(@round(rect.bottom)),
    };
}
