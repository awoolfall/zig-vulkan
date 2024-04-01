const std = @import("std");
const zwin32 = @import("zwin32");
const d3d11 = zwin32.d3d11;
const path = @import("../engine/path.zig");

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

        for (vs_layout, 0..) |*entry, slot| {
            const name_c = try name_arena.dupeZ(u8, entry.name);

            try d3d11_layout_desc.append(d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = name_c,
                .SemanticIndex = entry.index,
                .Format = entry.format.to_dxgi(),
                .InputSlot = @intCast(slot),
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = entry.per.to_d3d11(),
                .InstanceDataStepRate = 0,
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
    format: VertexInputLayoutFormat,
    per: VertexInputLayoutIteratePer = VertexInputLayoutIteratePer.Vertex,
};

pub const VertexInputLayoutFormat = enum {
    F32x1,
    F32x2,
    F32x3,
    F32x4,
    I32x4,

    pub fn to_dxgi(self: VertexInputLayoutFormat) zwin32.dxgi.FORMAT {
        switch (self) {
            .F32x1 => return zwin32.dxgi.FORMAT.R32_FLOAT,
            .F32x2 => return zwin32.dxgi.FORMAT.R32G32_FLOAT,
            .F32x3 => return zwin32.dxgi.FORMAT.R32G32B32_FLOAT,
            .F32x4 => return zwin32.dxgi.FORMAT.R32G32B32A32_FLOAT,
            .I32x4 => return zwin32.dxgi.FORMAT.R32G32B32A32_SINT,
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

    pub fn deinit(self: *const Texture2D) void {
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
                @ptrCast(texture), 
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
    D24S8_Unorm_Uint,

    pub fn to_d3d11(self: TextureFormat) zwin32.dxgi.FORMAT {
        switch (self) {
            .Rgba8_Unorm_Srgb => return zwin32.dxgi.FORMAT.R8G8B8A8_UNORM_SRGB,
            .D24S8_Unorm_Uint => return zwin32.dxgi.FORMAT.D24_UNORM_S8_UINT,
        }
    }

    pub fn byte_width(self: TextureFormat) usize {
        switch (self) {
            .Rgba8_Unorm_Srgb => return 4,
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
        };

        var rasterization_state: *d3d11.IRasterizerState = undefined;
        try zwin32.hrErrorOnFail(device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterization_state)));
        errdefer _ = rasterization_state.Release();

        return RasterizationState {
            .state = rasterization_state,
        };
    }
};
