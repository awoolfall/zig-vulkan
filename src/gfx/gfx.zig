const std = @import("std");
const builtin = @import("builtin");
const zwin32 = @import("zwin32");
const d3d11 = zwin32.d3d11;
const wb = @import("../window.zig");
const win32window = @import("../platform/windows.zig");
const path = @import("../engine/path.zig");

inline fn is_dbg() bool {
    return (builtin.mode == std.builtin.Mode.Debug);
}

pub const GfxState = struct {
    const Self = @This();

    device: *d3d11.IDevice,
    swapchain: *zwin32.dxgi.ISwapChain,
    context: *d3d11.IDeviceContext,
    rtv: RenderTargetView,

    swapchain_flags: zwin32.dxgi.SWAP_CHAIN_FLAG,
    swapchain_size: struct{width: i32, height: i32},

    // @TODO: add rasterization state map, blend state map, and sampler map so we can just use them at 
    // draw time instead of creating new objects each time at init. Be aggressive for JIT (Just in Time) gfx object creation

    const enable_debug_layers = true;
    const swapchain_buffer_count: u32 = 3;
    const swapchain_format = TextureFormat.Bgra8_Unorm;

    pub fn deinit(self: *Self) void {
        std.log.debug("D3D11 deinit", .{});
        self.context.Flush();
        self.rtv.deinit();
        _ = self.swapchain.Release();
        _ = self.context.Release();
        _ = self.device.Release();
    }

    pub fn init(window: *win32window.Win32Window) !Self {
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
            .rtv = undefined,
        };

        const framebuffer_texture = try gfx_state.create_texture2d_from_framebuffer();
        defer framebuffer_texture.deinit();

        gfx_state.rtv = try RenderTargetView.init_from_texture2d(&framebuffer_texture, gfx_state.device);
        errdefer gfx_state.rtv.deinit();
        
        return gfx_state;
    }

    fn attempt_create_device_and_swapchain(
        accepted_feature_levels: []const zwin32.d3d.FEATURE_LEVEL,
        swapchain_desc: zwin32.dxgi.SWAP_CHAIN_DESC,
        swapchain: ?*?*zwin32.dxgi.ISwapChain,
        device: ?*?*d3d11.IDevice,
        feature_level: ?*zwin32.d3d.FEATURE_LEVEL,
        context: ?*?*d3d11.IDeviceContext,
    ) !void {
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
                .format = Self.swapchain_format,
            },
        };
    }

    pub fn begin_frame(self: *Self) !RenderTargetView {
        return self.rtv;
    }

    pub fn end_frame(self: *Self, rtv: RenderTargetView) !void {
        _ = rtv;
        try zwin32.hrErrorOnFail(self.swapchain.Present(1, zwin32.dxgi.PRESENT_FLAG {}));
    }

    pub fn swapchain_aspect(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.swapchain_size.width)) / @as(f32, @floatFromInt(self.swapchain_size.height));
    }

    pub fn window_resized(self: *Self, new_width: i32, new_height: i32) void {
        // Release help render target view before we update the swapchain.
        // If we dont do this swapchain resize buffers will fail.
        self.rtv.deinit();

        zwin32.hrPanicOnFail(self.swapchain.ResizeBuffers(
                0, 0, 0, zwin32.dxgi.FORMAT.UNKNOWN, // automatic
                self.swapchain_flags)); 

        // Update swapchain size variables
        self.swapchain_size.width = new_width;
        self.swapchain_size.height = new_height;

        // Reacquire render target view from new swapchain
        var framebuffer_texture = self.create_texture2d_from_framebuffer() catch unreachable;
        defer framebuffer_texture.deinit();

        self.rtv = RenderTargetView.init_from_texture2d(&framebuffer_texture, self.device)
            catch unreachable;
    }

    pub fn received_window_event(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .RESIZED => |new_size| { self.window_resized(new_size.width, new_size.height); },
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
        device: *d3d11.IDevice,
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

        return init_buffer(vs_buf, vs_func, vs_layout, device);
    }

    pub fn init_buffer(
        vs_data: []const u8, 
        vs_func: []const u8, 
        vs_layout: []const VertexInputLayoutEntry,
        device: *d3d11.IDevice,
    ) !VertexShader {
        const vs_func_c = try std.heap.page_allocator.dupeZ(u8, vs_func);
        defer std.heap.page_allocator.free(vs_func_c);

        var vs_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&vs_data[0], vs_data.len, null, null, null, vs_func_c, "vs_5_0", 0, 0, @ptrCast(&vs_blob), null));
        defer _ = vs_blob.Release();

        var vso: *d3d11.IVertexShader = undefined;
        try zwin32.hrErrorOnFail(device.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, @ptrCast(&vso)));
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
        try zwin32.hrErrorOnFail(device.CreateInputLayout(@ptrCast(&d3d11_layout_desc.buffer[0]), d3d11_layout_desc.len, vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), @ptrCast(&vso_input_layout)));
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
        device: *d3d11.IDevice,
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

        return init_buffer(ps_buf, ps_func, device);
    }

    pub fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8, 
        device: *d3d11.IDevice,
    ) !PixelShader {
        const ps_func_c = try std.heap.page_allocator.dupeZ(u8, ps_func);
        defer std.heap.page_allocator.free(ps_func_c);

        var ps_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&ps_data[0], ps_data.len, null, null, null, ps_func_c, "ps_5_0", 0, 0, @ptrCast(&ps_blob), null));
        defer _ = ps_blob.Release();

        var pso: *d3d11.IPixelShader = undefined;
        try zwin32.hrErrorOnFail(device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&pso)));
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
        device: *d3d11.IDevice,
    ) !Buffer {
        if (!access_flags.CpuWrite and !access_flags.GpuWrite) { return error.DataNotSuppliedToImmutableBuffer; }

        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = access_flags.to_d3d11_usage(),
            .ByteWidth = @intCast(byte_size),
            .BindFlags = bind_flags.to_d3d11(),
            .CPUAccessFlags = access_flags.to_d3d11_cpu_access(),
        };
        var buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(device.CreateBuffer(&buffer_desc, null, @ptrCast(&buffer)));
        errdefer _ = buffer.Release();
        
        return Buffer {
            .buffer = buffer,
        };
    }
    
    pub fn init_with_data(
        data: []const u8,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        device: *d3d11.IDevice,
    ) !Buffer {
        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = access_flags.to_d3d11_usage(),
            .ByteWidth = @intCast(data.len),
            .BindFlags = bind_flags.to_d3d11(),
            .CPUAccessFlags = access_flags.to_d3d11_cpu_access(),
        };
        var buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(device.CreateBuffer(&buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = &data[0], }, @ptrCast(&buffer)));
        errdefer _ = buffer.Release();
        
        return Buffer {
            .buffer = buffer,
        };
    }

    pub fn map(self: *const Buffer, comptime OutType: type, context: *d3d11.IDeviceContext) !MappedBuffer(OutType) {
        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
        try zwin32.hrErrorOnFail(context.Map(@ptrCast(self.buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
        return MappedBuffer(OutType) {
            .context = context,
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
        device: *d3d11.IDevice
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
            try zwin32.hrErrorOnFail(device.CreateTexture2D(
                    &texture_desc, 
                    &d3d11.SUBRESOURCE_DATA {
                        .pSysMem = @ptrCast(d), 
                        .SysMemPitch = @intCast(desc.width * desc.format.byte_width()),
                    }, 
                    @ptrCast(&texture)
            ));
        } else {
            try zwin32.hrErrorOnFail(device.CreateTexture2D(
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
        access_flags: AccessFlags,
        bind_flags: BindFlag,
        colour: [4]u8,
        device: *d3d11.IDevice
    ) !Texture2D {
        if (desc.format.byte_width() != 4) { return error.FormatByteWidthMustBe4; }

        const data = try std.heap.page_allocator.alloc(u8, desc.width * desc.height * 4);
        defer std.heap.page_allocator.free(data);

        data = colour ** (desc.width * desc.height);

        return init(desc, access_flags, bind_flags, data, device);
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

    pub fn init_from_texture2d(texture: *const Texture2D, device: *d3d11.IDevice) !TextureView2D {
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
        try zwin32.hrErrorOnFail(device.CreateShaderResourceView(
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

    pub fn init_from_texture2d(texture: *const Texture2D, device: *d3d11.IDevice) !RenderTargetView {
        var rtv: *d3d11.IRenderTargetView = undefined;
        try zwin32.hrErrorOnFail(device.CreateRenderTargetView(
                @ptrCast(texture.texture), 
                &d3d11.RENDER_TARGET_VIEW_DESC{
                    .ViewDimension = d3d11.RTV_DIMENSION.TEXTURE2D,
                    .Format = .@"UNKNOWN",
                    .u = .{.Texture2D = d3d11.TEX2D_RTV {
                        .MipSlice = 0,
                    }},
                }, 
                @ptrCast(&rtv)
        ));

        return RenderTargetView {
            .view = rtv,
            .size = .{
                .width = texture.desc.width,
                .height = texture.desc.height,
            },
        };
    }
};

pub const DepthStencilView = struct {
    view: *d3d11.IDepthStencilView,

    pub fn deinit(self: *const DepthStencilView) void {
        _ = self.view.Release();
    }

    pub fn init_from_texture2d(texture: *const Texture2D, device: *d3d11.IDevice) !DepthStencilView {
        if (!texture.desc.format.is_depth()) { return error.NotADepthFormat; }

        const depth_stencil_desc = d3d11.DEPTH_STENCIL_VIEW_DESC {
            .Format = texture.desc.format.to_d3d11(),
            .ViewDimension = d3d11.DSV_DIMENSION.TEXTURE2D,
            .u = .{
                .Texture2D = d3d11.TEX2D_DSV {
                    .MipSlice = 0,
                },
            },
            .Flags = d3d11.DSV_FLAGS {},
        };
        var depth_stencil_view: *d3d11.IDepthStencilView = undefined;
        try zwin32.hrErrorOnFail(device.CreateDepthStencilView(@ptrCast(texture.texture), &depth_stencil_desc, @ptrCast(&depth_stencil_view)));
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
    D24S8_Unorm_Uint,

    pub fn to_d3d11(self: TextureFormat) zwin32.dxgi.FORMAT {
        switch (self) {
            .Rgba8_Unorm_Srgb => return zwin32.dxgi.FORMAT.R8G8B8A8_UNORM_SRGB,
            .Rgba8_Unorm => return zwin32.dxgi.FORMAT.R8G8B8A8_UNORM,
            .Bgra8_Unorm => return zwin32.dxgi.FORMAT.B8G8R8A8_UNORM,
            .D24S8_Unorm_Uint => return zwin32.dxgi.FORMAT.D24_UNORM_S8_UINT,
        }
    }

    pub fn byte_width(self: TextureFormat) usize {
        switch (self) {
            .Rgba8_Unorm_Srgb => return 4,
            .Rgba8_Unorm => return 4,
            .Bgra8_Unorm => return 4,
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

    pub fn init(desc: RasterizationStateDesc, device: *d3d11.IDevice) !RasterizationState {
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
        try zwin32.hrErrorOnFail(device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterization_state)));
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

    pub fn init(desc: SamplerDescriptor, device: *d3d11.IDevice) !Sampler {
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
            .MinLOD = 0.0,
            .MaxLOD = 0.0,
        };
        var sampler: *d3d11.ISamplerState = undefined;
        try zwin32.hrErrorOnFail(device.CreateSamplerState(&sampler_desc, @ptrCast(&sampler)));
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
                .SrcBlend = d3d11.BLEND.SRC_ALPHA,
                .DestBlend = d3d11.BLEND.INV_SRC_ALPHA,
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

    pub fn init(render_target_blend_types: []const BlendType, gfx: *GfxState) !BlendState {
        if (render_target_blend_types.len > 8) {
            return error.Maximum8BlendStates;
        }
        
        var blend_state_desc = d3d11.BLEND_DESC {
            .AlphaToCoverageEnable = 0,
            .IndependentBlendEnable = 0,
            .RenderTarget = [_]d3d11.RENDER_TARGET_BLEND_DESC {render_target_blend_types[0].to_d3d11()} ** 8,
        };
        for (render_target_blend_types, 0..) |t, i| {
            blend_state_desc.RenderTarget[i] = t.to_d3d11();
        }

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
        var blend_state: *d3d11.IBlendState = undefined;
        try zwin32.hrErrorOnFail(gfx.device.CreateBlendState(&blend_state_desc, @ptrCast(&blend_state)));
        errdefer _ = blend_state.Release();

        return BlendState {
            .state = blend_state,
        };
    }
};
