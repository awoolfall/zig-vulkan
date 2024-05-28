const std = @import("std");
const builtin = @import("builtin");
const zwin32 = @import("zwin32");
const d3d11 = zwin32.d3d11;
const wb = @import("../window.zig");
const win32window = @import("../platform/windows.zig");
const path = @import("../engine/path.zig");
const bloom = @import("bloom.zig");

inline fn is_dbg() bool {
    return (builtin.mode == std.builtin.Mode.Debug);
}

pub const GfxState = struct {
    const Self = @This();

    device: *d3d11.IDevice,
    swapchain: *zwin32.dxgi.ISwapChain,
    context: *d3d11.IDeviceContext,

    framebuffer_rtv: RenderTargetView,

    hdr_rtv: RenderTargetView,
    hdr_texture_view: TextureView2D,

    swapchain_flags: zwin32.dxgi.SWAP_CHAIN_FLAG,
    swapchain_size: struct{width: i32, height: i32},

    rasterization_states_map: std.AutoHashMap(RasterizationStateDesc, RasterizationState),

    tone_mapping_filter: ToneMappingAndBloomFilter,

    default: struct {
        sampler: Sampler,
        diffuse: TextureView2D,
        normals: TextureView2D,
        metallic_roughness: TextureView2D,
        ambient_occlusion: TextureView2D,
        emission: TextureView2D,
    },

    // @TODO: add rasterization state map, blend state map, and sampler map so we can just use them at 
    // draw time instead of creating new objects each time at init. Be aggressive for JIT (Just in Time) gfx object creation

    const enable_debug_layers = true;
    const swapchain_buffer_count: u32 = 3;
    const hdr_format = TextureFormat.Rgba16_Float;
    const ldr_format = TextureFormat.Rgba8_Unorm;
    const swapchain_format = ldr_format;

    pub fn deinit(self: *Self) void {
        std.log.debug("D3D11 deinit", .{});

        var rast_iterator = self.rasterization_states_map.iterator();
        while (rast_iterator.next()) |r| {
            r.value_ptr.deinit();
        }
        self.rasterization_states_map.deinit();

        self.default.sampler.deinit();
        self.default.diffuse.deinit();
        self.default.normals.deinit();
        self.default.metallic_roughness.deinit();
        self.default.ambient_occlusion.deinit();
        self.default.emission.deinit();

        self.tone_mapping_filter.deinit();

        self.hdr_rtv.deinit();
        self.hdr_texture_view.deinit();

        self.framebuffer_rtv.deinit();
        _ = self.swapchain.Release();
        self.context.ClearState();
        self.context.Flush();
        _ = self.context.Release();
        _ = self.device.Release();

        var debug: *zwin32.dxgi.IDebug1 = undefined;
        if (zwin32.hrErrorOnFail(zwin32.dxgi.GetDebugInterface1(0, &zwin32.dxgi.IID_IDebug1, @ptrCast(&debug)))) {
            zwin32.hrErrorOnFail(debug.ReportLiveObjects(
                zwin32.dxgi.DXGI_DEBUG_ALL,
                zwin32.dxgi.RLO_FLAGS{ 
                    .DETAIL = true,
                    .IGNORE_INTERNAL = true,
                }
            )) catch |err| {
                std.log.warn("Dxgi debug failed to report live objects: {}", .{err});
            };
            _ = debug.Release();
        } else |err| {
            std.log.warn("Unable to get dxgi debug interface: {}", .{err});
        }
    }

    pub fn init(alloc: std.mem.Allocator, window: *win32window.Win32Window) !Self {
        const accepted_feature_levels = [_]zwin32.d3d.FEATURE_LEVEL{
            .@"11_0", 
            .@"10_1" 
        };

        const window_size = try window.get_client_size();

        const swapchain_flags = zwin32.dxgi.SWAP_CHAIN_FLAG {
            .ALLOW_MODE_SWITCH = true,
            .ALLOW_TEARING = true,
        };

        const swapchain_desc = zwin32.dxgi.SWAP_CHAIN_DESC {
            .BufferDesc = zwin32.dxgi.MODE_DESC {
                .Width = @intCast(window_size.width),
                .Height = @intCast(window_size.height),
                .Format = swapchain_format.to_d3d11(),
                .Scaling = zwin32.dxgi.MODE_SCALING.STRETCHED,
                .RefreshRate = zwin32.dxgi.RATIONAL{
                    .Numerator = 0,
                    .Denominator = 1,
                },
                .ScanlineOrdering = zwin32.dxgi.MODE_SCANLINE_ORDER.UNSPECIFIED,
            },
            .SampleDesc = zwin32.dxgi.SAMPLE_DESC {
                .Count = 1,
                .Quality = 0,
            },
            .BufferUsage = zwin32.dxgi.USAGE {
                .RENDER_TARGET_OUTPUT = true,
            },
            .BufferCount = swapchain_buffer_count,
            .OutputWindow = window.hwnd,
            .Windowed = zwin32.w32.TRUE,
            .SwapEffect = zwin32.dxgi.SWAP_EFFECT.FLIP_DISCARD,
            .Flags = swapchain_flags,
        };

        var device: *d3d11.IDevice = undefined;
        var swapchain: *zwin32.dxgi.ISwapChain = undefined;
        var feature_level = zwin32.d3d.FEATURE_LEVEL.@"1_0_CORE";
        var context: *d3d11.IDeviceContext = undefined;

        // Attempt to create the device and swapchain with feature level 11_1.
        attempt_create_device_and_swapchain(
            &[_]zwin32.d3d.FEATURE_LEVEL{ .@"11_1" },
            swapchain_desc,
            @ptrCast(&swapchain),
            @ptrCast(&device),
            @ptrCast(&feature_level),
            @ptrCast(&context)
        ) catch |err| {
            std.log.warn("Failed to create at feature level 11_1", .{});
            // If 11_1 is not available the above call will fail, then try creating at other levels
            if (err == zwin32.w32.Error.INVALIDARG) {
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

        var gfx_state = Self {
            .device = device,
            .swapchain = swapchain,
            .swapchain_flags = swapchain_flags,
            .swapchain_size = .{
                .width = @intCast(window_size.width), 
                .height = @intCast(window_size.height)
            },
            .context = context,
            .framebuffer_rtv = undefined,
            .hdr_rtv = undefined,
            .hdr_texture_view = undefined,
            .tone_mapping_filter = undefined,
            .rasterization_states_map = std.AutoHashMap(RasterizationStateDesc, RasterizationState).init(alloc),
            .default = .{
                .sampler = undefined,
                .diffuse = undefined,
                .normals = undefined,
                .metallic_roughness = undefined,
                .ambient_occlusion = undefined,
                .emission = undefined,
            },
        };

        const framebuffer_texture = try gfx_state.create_texture2d_from_framebuffer();
        defer framebuffer_texture.deinit();

        gfx_state.framebuffer_rtv = try RenderTargetView.init_from_texture2d(&framebuffer_texture, &gfx_state);
        errdefer gfx_state.framebuffer_rtv.deinit();

        const hdr_texture = try gfx_state.create_hdr_rtv_texture2d_from_framebuffer();
        defer hdr_texture.deinit();

        gfx_state.hdr_rtv = try RenderTargetView.init_from_texture2d(&hdr_texture, &gfx_state);
        errdefer gfx_state.hdr_rtv.deinit();

        gfx_state.hdr_texture_view = try TextureView2D.init_from_texture2d(&hdr_texture, &gfx_state);
        errdefer gfx_state.hdr_texture_view.deinit();

        gfx_state.tone_mapping_filter = try ToneMappingAndBloomFilter.init(&gfx_state);
        errdefer gfx_state.tone_mapping_filter.deinit();

        gfx_state.default.sampler = try Sampler.init(.{}, &gfx_state);
        errdefer gfx_state.default.sampler.deinit();
        gfx_state.default.diffuse = try init_single_pixel_texture_view([4]u8{255, 255, 255, 255}, &gfx_state);
        errdefer gfx_state.default.diffuse.deinit();
        gfx_state.default.normals = try init_single_pixel_texture_view([4]u8{128, 128, 255, 255}, &gfx_state);
        errdefer gfx_state.default.normals.deinit();
        gfx_state.default.metallic_roughness = try init_single_pixel_texture_view([4]u8{0, 255, 255, 255}, &gfx_state);
        errdefer gfx_state.default.metallic_roughness.deinit();
        gfx_state.default.ambient_occlusion = try init_single_pixel_texture_view([4]u8{255, 255, 255, 255}, &gfx_state);
        errdefer gfx_state.default.ambient_occlusion.deinit();
        gfx_state.default.emission = try init_single_pixel_texture_view([4]u8{0, 0, 0, 255}, &gfx_state);
        errdefer gfx_state.default.emission.deinit();

        return gfx_state;
    }

    fn init_single_pixel_texture_view(colour: [4]u8, gfx_state: *GfxState) !TextureView2D {
        const texture = try Texture2D.init_colour(
            .{
                .width = 1,
                .height = 1,
                .format = .Rgba8_Unorm,
            },
            .{ .ShaderResource = true, },
            .{},
            colour,
            gfx_state
        );
        defer texture.deinit();
        return try TextureView2D.init_from_texture2d(&texture, gfx_state);
    }

    fn attempt_create_device_and_swapchain(
        accepted_feature_levels: []const zwin32.d3d.FEATURE_LEVEL,
        swapchain_desc: zwin32.dxgi.SWAP_CHAIN_DESC,
        swapchain: ?*?*zwin32.dxgi.ISwapChain,
        device: ?*?*d3d11.IDevice,
        feature_level: ?*zwin32.d3d.FEATURE_LEVEL,
        context: ?*?*d3d11.IDeviceContext,
    ) !void {
        if (is_dbg() and enable_debug_layers) {
            std.log.debug("enabling d3d11 debug layers", .{});
        }
        try zwin32.hrErrorOnFail(d3d11.D3D11CreateDeviceAndSwapChain(
                null,
                zwin32.d3d.DRIVER_TYPE.HARDWARE, 
                null,
                zwin32.d3d11.CREATE_DEVICE_FLAG {
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

    fn create_texture2d_from_framebuffer(self: *Self) !Texture2D {
        var framebuffer: *d3d11.ITexture2D = undefined;
        zwin32.hrPanicOnFail(self.swapchain.GetBuffer(0, &d3d11.IID_ITexture2D, @ptrCast(&framebuffer)));

        return Texture2D {
            .texture = framebuffer,
            .desc = Texture2D.Descriptor {
                .width = @intCast(self.swapchain_size.width),
                .height = @intCast(self.swapchain_size.height),
                .format = TextureFormat.Rgba8_Unorm_Srgb,
            },
        };
    }

    fn create_hdr_rtv_texture2d_from_framebuffer(self: *Self) !Texture2D {
        return try Texture2D.init(
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

    pub fn begin_frame(self: *Self) !RenderTargetView {
        return self.hdr_rtv;
    }

    pub fn get_framebuffer(self: *Self) *RenderTargetView {
        return &self.framebuffer_rtv;
    }

    pub fn present(self: *Self) !void {
        try zwin32.hrErrorOnFail(self.swapchain.Present(0, zwin32.dxgi.PRESENT_FLAG {}));
    }

    pub fn swapchain_aspect(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.swapchain_size.width)) / @as(f32, @floatFromInt(self.swapchain_size.height));
    }

    pub fn rasterization_state(self: *Self, desc: RasterizationStateDesc) RasterizationState {
        if (self.rasterization_states_map.get(desc)) |r| {
            return r;
        } else {
            const r = RasterizationState.init(desc, self) catch unreachable;
            self.rasterization_states_map.put(desc, r) catch unreachable;
            return r;
        }
    }

    pub fn window_resized(self: *Self, new_width: i32, new_height: i32) void {
        // Release help render target view before we update the swapchain.
        // If we dont do this swapchain resize buffers will fail.
        self.hdr_rtv.deinit();
        self.hdr_texture_view.deinit();
        self.framebuffer_rtv.deinit();

        self.context.ClearState();
        self.context.Flush();
        zwin32.hrPanicOnFail(self.swapchain.ResizeBuffers(
                0, 0, 0, zwin32.dxgi.FORMAT.UNKNOWN, // automatic
                self.swapchain_flags)); 

        // Update swapchain size variables
        self.swapchain_size.width = new_width;
        self.swapchain_size.height = new_height;

        // Reacquire render target view from new swapchain
        var framebuffer_texture = self.create_texture2d_from_framebuffer() catch unreachable;
        defer framebuffer_texture.deinit();

        self.framebuffer_rtv = RenderTargetView.init_from_texture2d(&framebuffer_texture, self)
            catch unreachable;

        var hdr_texture = self.create_hdr_rtv_texture2d_from_framebuffer() catch unreachable;
        defer hdr_texture.deinit();

        self.hdr_rtv = RenderTargetView.init_from_texture2d(&hdr_texture, self)
            catch unreachable;

        self.hdr_texture_view = TextureView2D.init_from_texture2d(&hdr_texture, self)
            catch unreachable;
    }

    pub fn received_window_event(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .RESIZED => |new_size| { 
                self.window_resized(new_size.width, new_size.height);

                // send resize event to children
                self.exposure_tone_mapping_filter.framebuffer_resized(self) catch unreachable;
            },
            else => {},
        }
    }
};

pub const VertexShader = struct {
    vso: *d3d11.IVertexShader,
    layout: *d3d11.IInputLayout,
    
    pub fn deinit(self: *const VertexShader) void {
        _ = self.vso.Release();
        _ = self.layout.Release();
    }

    pub fn init_file(
        alloc: std.mem.Allocator,
        vs_path: path.Path, 
        vs_func: []const u8,
        vs_layout: []const VertexInputLayoutEntry,
        gfx: *GfxState,
    ) !VertexShader {
        const vs_res_path = try vs_path.resolve_path(alloc);
        defer alloc.free(vs_res_path);

        var vs_file = try std.fs.cwd().openFile(vs_res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer vs_file.close();

        const vs_file_len = try vs_file.getEndPos();

        const vs_buf: []u8 = try alloc.alloc(u8, vs_file_len);
        defer alloc.free(vs_buf);

        if (try vs_file.readAll(vs_buf) != vs_file_len) {
            return error.FailedToReadVertexShader;
        }

        return init_buffer(vs_buf, vs_func, vs_layout, gfx);
    }

    pub fn init_buffer(
        vs_data: []const u8, 
        vs_func: []const u8, 
        vs_layout: []const VertexInputLayoutEntry,
        gfx: *GfxState,
    ) !VertexShader {
        const vs_func_c = try std.heap.page_allocator.dupeZ(u8, vs_func);
        defer std.heap.page_allocator.free(vs_func_c);

        var vs_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&vs_data[0], vs_data.len, null, null, null, vs_func_c, "vs_5_0", 0, 0, @ptrCast(&vs_blob), null));
        defer _ = vs_blob.Release();

        var vso: *d3d11.IVertexShader = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, @ptrCast(&vso)));
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
                .Format = entry.format.to_dxgi(),
                .InputSlot = @intCast(entry.slot),
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = entry.per.to_d3d11(),
                .InstanceDataStepRate = @intFromBool(entry.per == .Instance),
            });
        }

        var vso_input_layout: *d3d11.IInputLayout = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateInputLayout(@ptrCast(&d3d11_layout_desc.buffer[0]), d3d11_layout_desc.len, vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), @ptrCast(&vso_input_layout)));
        errdefer _ = vso_input_layout.Release();

        return VertexShader {
            .vso = vso,
            .layout = vso_input_layout,
        };
    }
};

pub const VertexInputLayoutEntry = struct {
    name: []const u8,
    index: u32 = 0,
    slot: u32 = 0,
    format: VertexInputLayoutFormat,
    per: VertexInputLayoutIteratePer = VertexInputLayoutIteratePer.Vertex,
};

pub const VertexInputLayoutFormat = enum {
    F32x1,
    F32x2,
    F32x3,
    F32x4,
    I32x4,
    U8x4,

    pub fn to_dxgi(self: VertexInputLayoutFormat) zwin32.dxgi.FORMAT {
        switch (self) {
            .F32x1 => return zwin32.dxgi.FORMAT.R32_FLOAT,
            .F32x2 => return zwin32.dxgi.FORMAT.R32G32_FLOAT,
            .F32x3 => return zwin32.dxgi.FORMAT.R32G32B32_FLOAT,
            .F32x4 => return zwin32.dxgi.FORMAT.R32G32B32A32_FLOAT,
            .I32x4 => return zwin32.dxgi.FORMAT.R32G32B32A32_SINT,
            .U8x4 => return zwin32.dxgi.FORMAT.R8G8B8A8_UNORM,
        }
    }
};

pub const VertexInputLayoutIteratePer = enum {
    Vertex,
    Instance,

    pub fn to_d3d11(self: VertexInputLayoutIteratePer) d3d11.INPUT_CLASSIFICATION {
        switch (self) {
            .Vertex => return d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
            .Instance => return d3d11.INPUT_CLASSIFICATION.INPUT_PER_INSTANCE_DATA,
        }
    }
};

pub const PixelShader = struct {
    pso: *d3d11.IPixelShader,
    
    pub fn deinit(self: *const PixelShader) void {
        _ = self.pso.Release();
    }
    
    pub fn init_file(
        alloc: std.mem.Allocator,
        ps_path: path.Path, 
        ps_func: []const u8,
        gfx: *GfxState,
    ) !PixelShader {
        const ps_res_path = try ps_path.resolve_path(alloc);
        defer alloc.free(ps_res_path);

        var ps_file = try std.fs.cwd().openFile(ps_res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer ps_file.close();

        const ps_file_len = try ps_file.getEndPos();

        const ps_buf: []u8 = try alloc.alloc(u8, ps_file_len);
        defer alloc.free(ps_buf);

        if (try ps_file.readAll(ps_buf) != ps_file_len) {
            return error.FailedToReadVertexShader;
        }

        return init_buffer(ps_buf, ps_func, gfx);
    }

    pub fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8, 
        gfx: *GfxState,
    ) !PixelShader {
        const ps_func_c = try std.heap.page_allocator.dupeZ(u8, ps_func);
        defer std.heap.page_allocator.free(ps_func_c);

        var ps_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&ps_data[0], ps_data.len, null, null, null, ps_func_c, "ps_5_0", 0, 0, @ptrCast(&ps_blob), null));
        defer _ = ps_blob.Release();

        var pso: *d3d11.IPixelShader = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&pso)));
        errdefer _ = pso.Release();

        return PixelShader {
            .pso = pso,
        };
    }
};

pub const Buffer = struct {
    buffer: *d3d11.IBuffer,  

    pub fn deinit(self: *const Buffer) void {
        _ = self.buffer.Release();
    }

    pub fn init(
        byte_size: u32,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        gfx: *GfxState,
    ) !Buffer {
        if (!access_flags.CpuWrite and !access_flags.GpuWrite) { return error.DataNotSuppliedToImmutableBuffer; }

        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = access_flags.to_d3d11_usage(),
            .ByteWidth = @intCast(byte_size),
            .BindFlags = bind_flags.to_d3d11(),
            .CPUAccessFlags = access_flags.to_d3d11_cpu_access(),
        };
        var buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateBuffer(&buffer_desc, null, @ptrCast(&buffer)));
        errdefer _ = buffer.Release();
        
        return Buffer {
            .buffer = buffer,
        };
    }
    
    pub fn init_with_data(
        data: []const u8,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        gfx: *GfxState,
    ) !Buffer {
        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = access_flags.to_d3d11_usage(),
            .ByteWidth = @intCast(data.len),
            .BindFlags = bind_flags.to_d3d11(),
            .CPUAccessFlags = access_flags.to_d3d11_cpu_access(),
        };
        var buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateBuffer(&buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = &data[0], }, @ptrCast(&buffer)));
        errdefer _ = buffer.Release();
        
        return Buffer {
            .buffer = buffer,
        };
    }

    pub fn map(self: *const Buffer, comptime OutType: type, gfx: *GfxState) !MappedBuffer(OutType) {
        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
        try zwin32.hrErrorOnFail(gfx.context.Map(@ptrCast(self.buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
        return MappedBuffer(OutType) {
            .context = gfx.context,
            .buffer = self.buffer,
            .data = @ptrCast(@alignCast(mapped_subresource.pData)),
        };
    }

    pub fn MappedBuffer(comptime T: type) type {
        return struct {
            data: *T,
            buffer: *d3d11.IBuffer,
            context: *d3d11.IDeviceContext,

            pub fn unmap(self: *const MappedBuffer(T)) void {
                self.context.Unmap(@ptrCast(self.buffer), 0);
            }
        };
    }

};

pub const Texture2D = struct {
    texture: *d3d11.ITexture2D,
    desc: Descriptor,

    pub fn deinit(self: *const Texture2D) void {
        _ = self.texture.Release();
    }

    pub fn init(
        desc: Descriptor,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        data: ?[]const u8,
        gfx: *GfxState
    ) !Texture2D {
        if (data) |d| {
            if (d.len < (desc.width * desc.height * desc.format.byte_width())) {
                return error.NotEnoughDataToFillTexture;
            }
        } else {
            if (!access_flags.CpuWrite and !access_flags.GpuWrite) { 
                return error.DataNotSuppliedToImmutableTexture; 
            }
        }

        const texture_desc = d3d11.TEXTURE2D_DESC {
            .Width = @intCast(desc.width),
            .Height = @intCast(desc.height),
            .MipLevels = @intCast(desc.mip_levels),
            .ArraySize = @intCast(desc.array_length),
            .Format = desc.format.to_d3d11(),
            .SampleDesc = zwin32.dxgi.SAMPLE_DESC {
                .Count = 1,
                .Quality = 0,
            },
            .Usage = access_flags.to_d3d11_usage(),
            .BindFlags = bind_flags.to_d3d11(),
            .CPUAccessFlags = access_flags.to_d3d11_cpu_access(),
            .MiscFlags = d3d11.RESOURCE_MISC_FLAG {},
        };
        var texture: *d3d11.ITexture2D = undefined;
        if (data) |d| {
            try zwin32.hrErrorOnFail(gfx.device.CreateTexture2D(
                    &texture_desc, 
                    &d3d11.SUBRESOURCE_DATA {
                        .pSysMem = @ptrCast(d), 
                        .SysMemPitch = @intCast(desc.width * desc.format.byte_width()),
                    }, 
                    @ptrCast(&texture)
            ));
        } else {
            try zwin32.hrErrorOnFail(gfx.device.CreateTexture2D(
                    &texture_desc, 
                    null,
                    @ptrCast(&texture)
            ));
        }
        errdefer _ = texture.Release();

        return Texture2D {
            .texture = texture,
            .desc = desc,
        };
    }

    pub fn init_colour(
        desc: Descriptor,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        colour: [4]u8,
        gfx: *GfxState
    ) !Texture2D {
        if (desc.format.byte_width() != 4) { return error.FormatByteWidthMustBe4; }

        const data = try std.heap.page_allocator.alloc(u8, desc.width * desc.height * 4);
        defer std.heap.page_allocator.free(data);

        const data_u32: *const align(1) []u32 = @ptrCast(&data);
        const colour_u32: *const align(1) u32 = @ptrCast(&colour);

        @memset(data_u32.*[0..(data.len / 4)], colour_u32.*);

        return init(desc, bind_flags, access_flags, data, gfx);
    }

    pub const Descriptor = struct {
        width: u32,
        height: u32,
        format: TextureFormat,
        array_length: u32 = 1,
        mip_levels: u32 = 1,
    };

};

pub const TextureView2D = struct {
    view: *d3d11.IShaderResourceView,

    pub fn deinit(self: *const TextureView2D) void {
        _ = self.view.Release();
    }

    pub fn init_from_texture2d(texture: *const Texture2D, gfx: *GfxState) !TextureView2D {
        const texture_resource_view_desc = d3d11.SHADER_RESOURCE_VIEW_DESC {
            .Format = texture.desc.format.to_d3d11(),
            .ViewDimension = d3d11.SRV_DIMENSION.TEXTURE2D,
            .u = .{
                .Texture2D = d3d11.TEX2D_SRV {
                    .MostDetailedMip = 0,
                    .MipLevels = texture.desc.mip_levels,
                },
            },
        };
        var texture_view: *d3d11.IShaderResourceView = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateShaderResourceView(
                @ptrCast(texture.texture), 
                &texture_resource_view_desc, 
                @ptrCast(&texture_view)
        ));
        errdefer _ = texture_view.Release();

        return TextureView2D {
            .view = texture_view,
        };
    }
};

pub const RenderTargetView = struct {
    view: *d3d11.IRenderTargetView,
    size: struct { width: u32, height: u32, },

    pub fn deinit(self: *const RenderTargetView) void {
        _ = self.view.Release();
    }

    pub fn init_from_texture2d(texture: *const Texture2D, gfx: *GfxState) !RenderTargetView {
        return init_from_texture2d_mip(texture, 0, gfx);
    }

    pub fn init_from_texture2d_mip(texture: *const Texture2D, mip_level: u32, gfx: *GfxState) !RenderTargetView {
        var rtv: *d3d11.IRenderTargetView = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateRenderTargetView(
                @ptrCast(texture.texture), 
                &d3d11.RENDER_TARGET_VIEW_DESC{
                    .ViewDimension = d3d11.RTV_DIMENSION.TEXTURE2D,
                    .Format = texture.desc.format.to_d3d11(),
                    .u = .{.Texture2D = d3d11.TEX2D_RTV {
                        .MipSlice = mip_level,
                    }},
                }, 
                @ptrCast(&rtv)
        ));

        return RenderTargetView {
            .view = rtv,
            .size = .{
                .width = texture.desc.width / std.math.pow(u32, 2, mip_level),
                .height = texture.desc.height / std.math.pow(u32, 2, mip_level),
            },
        };
    }
};

pub const DepthStencilView = struct {
    view: *d3d11.IDepthStencilView,

    pub fn deinit(self: *const DepthStencilView) void {
        _ = self.view.Release();
    }

    pub fn init_from_texture2d(
        texture: *const Texture2D, 
        flags: struct{ read_only_depth: bool = false, read_only_stencil: bool = false, },
        gfx: *GfxState
    ) !DepthStencilView {
        if (!texture.desc.format.is_depth()) { return error.NotADepthFormat; }

        const depth_stencil_desc = d3d11.DEPTH_STENCIL_VIEW_DESC {
            .Format = texture.desc.format.to_d3d11(),
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
        try zwin32.hrErrorOnFail(gfx.device.CreateDepthStencilView(@ptrCast(texture.texture), &depth_stencil_desc, @ptrCast(&depth_stencil_view)));
        errdefer _ = depth_stencil_view.Release();

        return DepthStencilView {
            .view = depth_stencil_view,
        };
    }
};

pub const TextureFormat = enum {
    Rgba8_Unorm_Srgb,
    Rgba8_Unorm,
    Bgra8_Unorm,
    Rgba16_Float,
    Rg11b10_Float,
    D24S8_Unorm_Uint,

    pub fn to_d3d11(self: TextureFormat) zwin32.dxgi.FORMAT {
        switch (self) {
            .Rgba8_Unorm_Srgb => return zwin32.dxgi.FORMAT.R8G8B8A8_UNORM_SRGB,
            .Rgba8_Unorm => return zwin32.dxgi.FORMAT.R8G8B8A8_UNORM,
            .Bgra8_Unorm => return zwin32.dxgi.FORMAT.B8G8R8A8_UNORM,
            .Rgba16_Float => return zwin32.dxgi.FORMAT.R16G16B16A16_FLOAT,
            .Rg11b10_Float => return zwin32.dxgi.FORMAT.R11G11B10_FLOAT,
            .D24S8_Unorm_Uint => return zwin32.dxgi.FORMAT.D24_UNORM_S8_UINT,
        }
    }

    pub fn byte_width(self: TextureFormat) usize {
        switch (self) {
            .Rgba8_Unorm_Srgb => return 4,
            .Rgba8_Unorm => return 4,
            .Bgra8_Unorm => return 4,
            .Rgba16_Float => return 8,
            .Rg11b10_Float => return 3,
            .D24S8_Unorm_Uint => return 4,
        }
    }

    pub fn is_depth(self: TextureFormat) bool {
        switch (self) {
            .D24S8_Unorm_Uint => return true,
            else => return false,
        }
    }
};

pub const BindFlag = packed struct(u32) {
    VertexBuffer: bool = false,
    IndexBuffer: bool = false,
    ConstantBuffer: bool = false,
    ShaderResource: bool = false,
    StreamOutput: bool = false,
    RenderTarget: bool = false,
    DepthStencil: bool = false,
    UnorderedAccess: bool = false,
    Decoder: bool = false,
    VideoEncoder: bool = false,
    __unused: u22 = 0,

    pub fn to_d3d11(self: BindFlag) d3d11.BIND_FLAG {
        return d3d11.BIND_FLAG {
            .VERTEX_BUFFER = self.VertexBuffer,
            .INDEX_BUFFER = self.IndexBuffer,
            .CONSTANT_BUFFER = self.ConstantBuffer,
            .SHADER_RESOURCE = self.ShaderResource,
            .STREAM_OUTPUT = self.StreamOutput,
            .RENDER_TARGET = self.RenderTarget,
            .DEPTH_STENCIL = self.DepthStencil,
            .UNORDERED_ACCESS = self.UnorderedAccess,
            .DECODER = self.Decoder,
            .VIDEO_ENCODER = self.VideoEncoder,
        };
    }
};

pub const AccessFlags = packed struct(u32) {
    GpuWrite: bool = false,
    CpuRead: bool = false,
    CpuWrite: bool = false,
    __unused: u29 = 0,

    fn to_d3d11_usage(self: AccessFlags) d3d11.USAGE {
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

    fn to_d3d11_cpu_access(self: AccessFlags) d3d11.CPU_ACCCESS_FLAG {
        return d3d11.CPU_ACCCESS_FLAG {
            .READ = self.CpuRead,
            .WRITE = self.CpuWrite,
        };
    }
};

pub const RasterizationStateDesc = packed struct(u32) {
    FillBack: bool = true,
    FillFront: bool = true,
    FrontCounterClockwise: bool = false,
    __unused: u29 = 0,
};

pub const RasterizationState = struct {
    state: *d3d11.IRasterizerState,

    pub fn deinit(self: *const RasterizationState) void {
        _ = self.state.Release();
    }

    pub fn init(desc: RasterizationStateDesc, gfx: *GfxState) !RasterizationState {
        var rasterizer_state_desc = d3d11.RASTERIZER_DESC {
            .FillMode = blk: {
                if (!desc.FillBack and !desc.FillFront) {
                    break :blk d3d11.FILL_MODE.WIREFRAME;
                } else {
                    break :blk d3d11.FILL_MODE.SOLID;
                }
            },
            .CullMode = blk: {
                if (desc.FillBack == desc.FillFront) {
                    break :blk d3d11.CULL_MODE.NONE;
                } else if (!desc.FillBack) {
                    break :blk d3d11.CULL_MODE.BACK;
                } else {
                    break :blk d3d11.CULL_MODE.FRONT;
                }
            },
            .FrontCounterClockwise = @intFromBool(desc.FrontCounterClockwise),
        };

        var rasterization_state: *d3d11.IRasterizerState = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterization_state)));
        errdefer _ = rasterization_state.Release();

        return RasterizationState {
            .state = rasterization_state,
        };
    }
};

pub const SamplerDescriptor = struct {
    anisotropic_filter: bool = false,
    filter_min_mag: SamplerFilter = .Point,
    filter_mip: SamplerFilter = .Point,
    border_mode: SamplerBorderMode = .Clamp,
    border_colour: [4]f32 = [4]f32{0.0, 0.0, 0.0, 0.0},
    min_lod: f32 = 0.0,
    max_lod: f32 = 0.0,
};

pub const SamplerFilter = enum {
    Point,
    Linear,
};

pub const SamplerBorderMode = enum {
    Wrap,
    Mirror,
    Clamp,
    BorderColour,

    fn to_d3d11(self: SamplerBorderMode) d3d11.TEXTURE_ADDRESS_MODE {
        switch (self) {
            .Wrap => return d3d11.TEXTURE_ADDRESS_MODE.WRAP,
            .Mirror => return d3d11.TEXTURE_ADDRESS_MODE.MIRROR,
            .Clamp => return d3d11.TEXTURE_ADDRESS_MODE.CLAMP,
            .BorderColour => return d3d11.TEXTURE_ADDRESS_MODE.BORDER,
        }
    }
};

pub const Sampler = struct {
    sampler: *d3d11.ISamplerState,

    pub fn deinit(self: *const Sampler) void {
        _ = self.sampler.Release();
    }

    pub fn init(desc: SamplerDescriptor, gfx: *GfxState) !Sampler {
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
            .AddressU = desc.border_mode.to_d3d11(),
            .AddressV = desc.border_mode.to_d3d11(),
            .AddressW = desc.border_mode.to_d3d11(),
            .MaxAnisotropy = 1, // @TODO: setting from gfx?
            .BorderColor = desc.border_colour,
            .MipLODBias = 0.0,
            .ComparisonFunc = .NEVER,
            .MinLOD = desc.min_lod,
            .MaxLOD = desc.max_lod,
        };
        var sampler: *d3d11.ISamplerState = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateSamplerState(&sampler_desc, @ptrCast(&sampler)));
        errdefer _ = sampler.Release();

        return Sampler {
            .sampler = sampler,
        };
    }
};

pub const BlendType = enum {
    None,
    Simple,

    pub fn to_d3d11(self: BlendType) d3d11.RENDER_TARGET_BLEND_DESC {
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
                .SrcBlendAlpha = d3d11.BLEND.ONE,
                .DestBlendAlpha = d3d11.BLEND.ZERO,
                .BlendOpAlpha = d3d11.BLEND_OP.ADD,
            },
        }
    }
};

pub const BlendState = struct {
    state: *d3d11.IBlendState,

    pub fn deinit(self: *const BlendState) void {
        _ = self.state.Release();
    }

    pub fn init(render_target_blend_types: []const BlendType, gfx: *const GfxState) !BlendState {
        if (render_target_blend_types.len > 8) {
            return error.Maximum8BlendStates;
        }
        
        var blend_state_desc = d3d11.BLEND_DESC {
            .AlphaToCoverageEnable = 0,
            .IndependentBlendEnable = 0,
            .RenderTarget = [_]d3d11.RENDER_TARGET_BLEND_DESC {BlendType.None.to_d3d11()} ** 8,
        };
        for (render_target_blend_types, 0..) |t, i| {
            blend_state_desc.RenderTarget[i] = t.to_d3d11();
        }

        var blend_state: *d3d11.IBlendState = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateBlendState(&blend_state_desc, @ptrCast(&blend_state)));
        errdefer _ = blend_state.Release();

        return BlendState {
            .state = blend_state,
        };
    }
};

const ToneMappingAndBloomFilter = struct {
    const FULL_SCREEN_QUAD_VS = @embedFile("full_screen_quad_vs.hlsl");
    const HLSL = //
\\  Texture2D hdr_buffer;
\\  Texture2D bloom_buffer;
\\  SamplerState hdr_sampler;
\\
\\  cbuffer exposure_buffer : register(b0)
\\  {
\\      float exposure;
\\      float __unused0;
\\      float __unused1;
\\      float __unused2;
\\  }
\\
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      float3 hdr_colour = hdr_buffer.Sample(hdr_sampler, input.uv).rgb;
\\      float3 bloom_colour = bloom_buffer.Sample(hdr_sampler, input.uv).rgb;
\\      float3 mixed_colour = lerp(hdr_colour, bloom_colour, 0.04);
\\      
\\      bool use_aces = true;
\\      bool use_exposure = false;
\\
\\      float4 toned_colour;
\\      if (use_aces) {
\\          float3 c = mixed_colour;
\\          float3 mapped_aces = (c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14);
\\          toned_colour = float4(saturate(mapped_aces), 1.0);
\\      } 
\\      else if (use_exposure) {
\\          float3 mapped = float3(1.0, 1.0, 1.0) - exp(-mixed_colour * exposure);
\\          toned_colour = float4(saturate(mapped), 1.0);
\\      }
\\      else {
\\          // otherwise just use LDR clamped
\\          toned_colour = float4(saturate(mixed_colour), 1.0);
\\      }
\\
\\      return toned_colour;
\\  }
;

    const ExposureConstantBuffer = extern struct {
        exposure: f32,
        __unused0: f32 = 0.0,
        __unused1: f32 = 0.0,
        __unused2: f32 = 0.0,
    };

    vertex_shader: VertexShader,
    pixel_shader: PixelShader,
    sampler: Sampler,
    buffer: Buffer,

    bloom_filter: bloom.BloomFilter,

    pub fn deinit(self: *ToneMappingAndBloomFilter) void {
        self.bloom_filter.deinit();
        self.buffer.deinit();
        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.sampler.deinit();
    }

    pub fn init(gfx: *GfxState) !ToneMappingAndBloomFilter {
        var vertex_shader = try VertexShader.init_buffer(
            FULL_SCREEN_QUAD_VS,
            "vs_main",
            ([0]VertexInputLayoutEntry {})[0..],
            gfx
        );
        errdefer vertex_shader.deinit();

        var pixel_shader = try PixelShader.init_buffer(
            FULL_SCREEN_QUAD_VS ++ HLSL,
            "ps_main",
            gfx
        );
        errdefer pixel_shader.deinit();

        var sampler = try Sampler.init(
            SamplerDescriptor {},
            gfx
        );
        errdefer sampler.deinit();

        var buffer = try Buffer.init(
            @sizeOf(ExposureConstantBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        errdefer buffer.deinit();

        var bloom_filter = try bloom.BloomFilter.init(gfx);
        errdefer bloom_filter.deinit();

        return ToneMappingAndBloomFilter {
            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,
            .sampler = sampler,
            .bloom_filter = bloom_filter,
            .buffer = buffer,
        };
    }

    pub fn apply_filter(
        self: *ToneMappingAndBloomFilter,
        hdr_buffer: *TextureView2D,
        exposure: f32,
        rtv: *RenderTargetView,
        gfx: *GfxState
    ) void {
        self.bloom_filter.render_bloom_texture(hdr_buffer, 0.005, gfx);

        if (self.buffer.map(ExposureConstantBuffer, gfx)) |mapped_buffer| {
            defer mapped_buffer.unmap();
            mapped_buffer.data.exposure = exposure;
        } else |_| {}

        const viewport = d3d11.VIEWPORT {
            .Width = @floatFromInt(rtv.size.width),
            .Height = @floatFromInt(rtv.size.height),
            .TopLeftX = 0.0,
            .TopLeftY = 0.0,
            .MinDepth = 0.0,
            .MaxDepth = 0.0,
        };

        gfx.context.OMSetBlendState(null, null, 0xffffffff);
        gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv.view), null);

        gfx.context.RSSetViewports(1, @ptrCast(&viewport));
        gfx.context.RSSetState(@ptrCast(gfx.rasterization_state(.{ .FillBack = false, .FrontCounterClockwise = true, }).state));

        gfx.context.VSSetShader(@ptrCast(self.vertex_shader.vso), null, 0);

        gfx.context.PSSetShader(@ptrCast(self.pixel_shader.pso), null, 0);
        gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler.sampler));
        gfx.context.PSSetShaderResources(0, 2, @ptrCast(&([2]*d3d11.IShaderResourceView{
            hdr_buffer.view, 
            self.bloom_filter.get_bloom_view().view
        })));
        gfx.context.PSSetConstantBuffers(0, 1, @ptrCast(&self.buffer.buffer));

        gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);

        gfx.context.Draw(6, 0);
        
        // unset hdr texture so it can be used as rtv again
        gfx.context.PSSetShaderResources(0, 2, @ptrCast(&([2]?*d3d11.IShaderResourceView{null, null})));
    }

    pub fn framebuffer_resized(self: *ToneMappingAndBloomFilter, gfx: *GfxState) !void {
        self.bloom_filter.framebuffer_resized(gfx);
    }
};
