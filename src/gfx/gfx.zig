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
        usage: Usage,
        bind_flags: BindFlag,
        cpu_access: CpuAccessFlags,
        device: *d3d11.IDevice,
    ) !Buffer {
        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = usage.to_d3d11(),
            .ByteWidth = @intCast(byte_size),
            .BindFlags = bind_flags.to_d3d11(),
            .CPUAccessFlags = cpu_access.to_d3d11(),
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
        usage: Usage,
        bind_flags: BindFlag,
        cpu_access: CpuAccessFlags,
        device: *d3d11.IDevice,
    ) !Buffer {
        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = usage.to_d3d11(),
            .ByteWidth = @intCast(data.len),
            .BindFlags = bind_flags.to_d3d11(),
            .CPUAccessFlags = cpu_access.to_d3d11(),
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

    pub const Usage = enum {
        Mutable,
        Immutable,

        fn to_d3d11(self: Usage) d3d11.USAGE {
            switch (self) {
                .Mutable => return d3d11.USAGE.DYNAMIC,
                .Immutable => return d3d11.USAGE.IMMUTABLE,
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

    pub const CpuAccessFlags = packed struct(u32) {
        CpuRead: bool = false,
        CpuWrite: bool = false,
        __unused: u30 = 0,

        pub fn to_d3d11(self: CpuAccessFlags) d3d11.CPU_ACCCESS_FLAG {
            return d3d11.CPU_ACCCESS_FLAG {
                .READ = self.CpuRead,
                .WRITE = self.CpuWrite,
            };
        }
    };
};
