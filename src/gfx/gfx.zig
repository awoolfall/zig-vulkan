const std = @import("std");
const builtin = @import("builtin");
const zm = @import("zmath");
const wb = @import("../window.zig");
const path = @import("../engine/path.zig");
const bloom = @import("bloom.zig");
const pl = @import("../platform/platform.zig");
const gen = @import("self").gen;
const ToneMappingAndBloomFilter = @import("tonemapping_filter.zig");

const eng = @import("../root.zig");
const Rect = eng.Rect;

pub const GfxState = struct {
    const Self = @This();
    const Platform = pl.GfxPlatform;

    pub const FULL_SCREEN_QUAD_VS = @embedFile("full_screen_quad_vs.hlsl");

    platform: Platform,

    buffers: gen.GenerationalList(Buffer),
    images: gen.GenerationalList(Image),
    image_views: gen.GenerationalList(ImageView),
    samplers: gen.GenerationalList(Sampler),

    render_passes: gen.GenerationalList(RenderPass),
    graphics_pipelines: gen.GenerationalList(GraphicsPipeline),
    framebuffers: gen.GenerationalList(FrameBuffer),

    descriptor_layouts: gen.GenerationalList(DescriptorLayout),
    descriptor_pools: gen.GenerationalList(DescriptorPool),

    command_pools: gen.GenerationalList(CommandPool),

    tone_mapping_filter: ToneMappingAndBloomFilter,

    default: struct {
        sampler: Sampler.Ref,

        depth_image: Image.Ref,
        depth_view: ImageView.Ref,

        diffuse: Image.Ref,
        diffuse_view: ImageView.Ref,

        normals: Image.Ref,
        normals_view: ImageView.Ref,

        metallic_roughness: Image.Ref,
        metallic_roughness_view: ImageView.Ref,

        ambient_occlusion: Image.Ref,
        ambient_occlusion_view: ImageView.Ref,

        emission: Image.Ref,
        emission_view: ImageView.Ref,

        vertex_shader: *const VertexShader = undefined,
        pixel_shader: *const PixelShader = undefined,
    },

    pub const hdr_format = ImageFormat.Rgba16_Float;
    pub const ldr_format = ImageFormat.Rgba8_Unorm;
    pub const depth_format = ImageFormat.D24S8_Unorm_Uint;

    pub fn deinit(self: *Self) void {
        std.log.debug("gfx deinit", .{});

        self.tone_mapping_filter.deinit();

        self.default.sampler.deinit();
        self.default.depth_view.deinit();
        self.default.depth_image.deinit();
        self.default.diffuse_view.deinit();
        self.default.diffuse.deinit();
        self.default.normals_view.deinit();
        self.default.normals.deinit();
        self.default.metallic_roughness_view.deinit();
        self.default.metallic_roughness.deinit();
        self.default.ambient_occlusion_view.deinit();
        self.default.ambient_occlusion.deinit();
        self.default.emission_view.deinit();
        self.default.emission.deinit();

        self.platform.deinit();

        self.buffers.deinit();
        self.images.deinit();
        self.image_views.deinit();
        self.samplers.deinit();

        self.framebuffers.deinit();
        self.graphics_pipelines.deinit();
        self.render_passes.deinit();

        self.descriptor_pools.deinit();
        self.descriptor_layouts.deinit();

        self.command_pools.deinit();
    }

    pub fn init(self: *Self, alloc: std.mem.Allocator, window: *pl.Window) !void {
        self.buffers = gen.GenerationalList(Buffer).init(alloc);
        errdefer self.buffers.deinit();

        self.images = gen.GenerationalList(Image).init(alloc);
        errdefer self.images.deinit();

        self.image_views = gen.GenerationalList(ImageView).init(alloc);
        errdefer self.image_views.deinit();

        self.samplers = gen.GenerationalList(Sampler).init(alloc);
        errdefer self.samplers.deinit();


        self.render_passes = gen.GenerationalList(RenderPass).init(alloc);
        errdefer self.render_passes.deinit();

        self.graphics_pipelines = gen.GenerationalList(GraphicsPipeline).init(alloc);
        errdefer self.graphics_pipelines.deinit();

        self.framebuffers = gen.GenerationalList(FrameBuffer).init(alloc);
        errdefer self.framebuffers.deinit();


        self.descriptor_layouts = gen.GenerationalList(DescriptorLayout).init(alloc);
        errdefer self.descriptor_layouts.deinit();
        
        self.descriptor_pools = gen.GenerationalList(DescriptorPool).init(alloc);
        errdefer self.descriptor_pools.deinit();

        self.command_pools = gen.GenerationalList(CommandPool).init(alloc);
        errdefer self.command_pools.deinit();


        try self.platform.init(alloc, window);
        errdefer self.platform.deinit();
        

        self.tone_mapping_filter = try ToneMappingAndBloomFilter.init();
        errdefer self.tone_mapping_filter.deinit();

        self.default.depth_image = try Image.init(.{
            .format = Self.depth_format,
            .match_swapchain_extent = true,

            .usage_flags = .{ .DepthStencil = true, },
            .access_flags = .{ .GpuWrite = true, },
        }, null);
        errdefer self.default.depth_image.deinit();

        self.default.depth_view = try ImageView.init(.{ .image = self.default.depth_image, });
        errdefer self.default.depth_view.deinit();

        self.default.sampler = try Sampler.init(.{});
        errdefer self.default.sampler.deinit();

        self.default.diffuse = try init_single_pixel_texture(zm.f32x4s(1.0));
        errdefer self.default.diffuse.deinit();

        self.default.diffuse_view = try ImageView.init(.{ .image = self.default.diffuse, });
        errdefer self.default.diffuse_view.deinit();

        self.default.normals = try init_single_pixel_texture(zm.f32x4(0.5, 0.5, 1.0, 1.0));
        errdefer self.default.normals.deinit();

        self.default.normals_view = try ImageView.init(.{ .image = self.default.normals, });
        errdefer self.default.normals_view.deinit();

        self.default.metallic_roughness = try init_single_pixel_texture(zm.f32x4(0.0, 1.0, 1.0, 1.0));
        errdefer self.default.metallic_roughness.deinit();

        self.default.metallic_roughness_view = try ImageView.init(.{ .image = self.default.metallic_roughness, });
        errdefer self.default.metallic_roughness_view.deinit();
        
        self.default.ambient_occlusion = try init_single_pixel_texture(zm.f32x4s(1.0));
        errdefer self.default.ambient_occlusion.deinit();

        self.default.ambient_occlusion_view = try ImageView.init(.{ .image = self.default.ambient_occlusion, });
        errdefer self.default.ambient_occlusion_view.deinit();

        self.default.emission = try init_single_pixel_texture(zm.f32x4(0.0, 0.0, 0.0, 1.0));
        errdefer self.default.emission.deinit();

        self.default.emission_view = try ImageView.init(.{ .image = self.default.emission, });
        errdefer self.default.emission_view.deinit();
    }

    pub inline fn get() *Self {
        return &eng.get().gfx;
    }

    pub fn swapchain_size(self: *const Self) [2]u32 {
        return self.platform.swapchain_size();
    }

    pub fn swapchain_aspect(self: *const Self) f32 {
        const s = self.swapchain_size();
        return @as(f32, @floatFromInt(s[0])) / @as(f32, @floatFromInt(s[1]));
    }

    fn init_single_pixel_texture(colour: zm.F32x4) !Image.Ref {
        return try Image.init_colour(
            .{
                .width = 1,
                .height = 1,
                .format = .Rgba8_Unorm,

                .usage_flags = .{ .ShaderResource = true, },
                .access_flags = .{},
            },
            colour,
        );
    }

    pub fn begin_frame(self: *Self) !void {
        try self.platform.begin_frame();
    }

    pub fn present(self: *Self, wait_semaphores: []const *Semaphore) !void {
        if (self.swapchain_size()[0] * self.swapchain_size()[1] == 0) {
            return error.SwapchainSizeIsZero;
        }
        try self.platform.present(wait_semaphores);
    }

    pub fn flush(self: *Self) void {
        self.platform.flush();
    }

    pub fn window_resized(self: *Self, new_width: u32, new_height: u32) void {
        self.flush();
        self.platform.resize_swapchain(@max(new_width, 1), @max(new_height, 1));
    }

    pub fn received_window_event(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .RESIZED => |new_size| { 
                self.window_resized(@intCast(new_size.width), @intCast(new_size.height));

                // send resize event to children
                self.tone_mapping_filter.framebuffer_resized() catch unreachable; // TODO remove?
            },
            else => {},
        }
    }
};

pub const QueueFamily = enum {
    Graphics,
    Transfer,
    Compute,
};

pub const VertexBufferInput = struct {
    buffer: Buffer.Ref,
    stride: u32,
    offset: u32,
};

pub const IndexFormat = enum {
    U16,
    U32,
};

pub const ShaderStage = enum {
    Vertex,
    Pixel,
    Hull,
    Domain,
    Geometry,
    Compute,
};

pub const ShaderStageFlags = packed struct(u2) {
    Vertex: bool = false,
    Pixel: bool = false,
};

pub const Topology = enum {
    PointList,
    LineList,
    LineStrip,
    TriangleList,
    TriangleStrip,
};

pub const Viewport = struct {
    width: f32,
    height: f32,
    top_left_x: f32 = 0.0,
    top_left_y: f32 = 0.0,
    min_depth: f32 = 0.0,
    max_depth: f32 = 1.0,
};

pub const ShaderDefineTuple = std.meta.Tuple(&[_]type{ []const u8, []const u8 });

pub const VertexShaderOptions = struct {
    filepath: ?[]const u8 = null,
    defines: []const ShaderDefineTuple = &.{},
};

pub const VertexShader = struct {
    platform: pl.GfxPlatform.VertexShader,
    
    pub fn deinit(self: *const VertexShader) void {
        self.platform.deinit();
    }

    pub fn init_file(
        alloc: std.mem.Allocator,
        vs_path: path.Path, 
        vs_func: []const u8,
        vs_layout: []const VertexInputLayoutEntry,
        options: VertexShaderOptions,
    ) !VertexShader {
        const vs_res_path = try vs_path.resolve_path(alloc);
        defer alloc.free(vs_res_path);

        var modified_options = options;
        modified_options.filepath = vs_res_path;

        var vs_file = try std.fs.cwd().openFile(vs_res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer vs_file.close();

        const vs_file_len = try vs_file.getEndPos();

        const vs_buf: []u8 = try alloc.alloc(u8, @intCast(vs_file_len));
        defer alloc.free(vs_buf);

        if (try vs_file.readAll(vs_buf) != vs_file_len) {
            return error.FailedToReadShader;
        }

        return init_buffer(vs_buf, vs_func, vs_layout, modified_options);
    }

    pub fn init_buffer(
        vs_data: []const u8, 
        vs_func: []const u8, 
        vs_layout: []const VertexInputLayoutEntry,
        options: VertexShaderOptions,
    ) !VertexShader {
        const platform = pl.GfxPlatform.VertexShader.init_buffer(vs_data, vs_func, vs_layout, options) catch |err| {
            std.log.err("Vertex shader init failed: {s}", .{@errorName(err)});
            return err;
        };
        return VertexShader {
            .platform = platform,
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
};

pub const VertexInputLayoutIteratePer = enum {
    Vertex,
    Instance,
};

pub const PixelShaderOptions = struct {
    filepath: ?[]const u8 = null,
    defines: []const ShaderDefineTuple = &.{},
};

pub const PixelShader = struct {
    platform: pl.GfxPlatform.PixelShader,
    
    pub fn deinit(self: *const PixelShader) void {
        self.platform.deinit();
    }
    
    pub fn init_file(
        alloc: std.mem.Allocator,
        ps_path: path.Path, 
        ps_func: []const u8,
        options: PixelShaderOptions,
    ) !PixelShader {
        const ps_res_path = try ps_path.resolve_path(alloc);
        defer alloc.free(ps_res_path);

        var modified_options = options;
        modified_options.filepath = ps_res_path;

        var ps_file = try std.fs.cwd().openFile(ps_res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer ps_file.close();

        const ps_file_len = try ps_file.getEndPos();

        const ps_buf: []u8 = try alloc.alloc(u8, @intCast(ps_file_len));
        defer alloc.free(ps_buf);

        if (try ps_file.readAll(ps_buf) != ps_file_len) {
            return error.FailedToReadShader;
        }

        return init_buffer(ps_buf, ps_func, modified_options);
    }

    pub fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8,
        options: PixelShaderOptions,
    ) !PixelShader {
        const platform = pl.GfxPlatform.PixelShader.init_buffer(ps_data, ps_func, options) catch |err| {
            std.log.err("Pixel shader init failed: {s}\n\t- {s}", .{
                @errorName(err),
                options.filepath orelse "no filepath provided",
            });
            return err;
        };
        return PixelShader {
            .platform = platform,
        };
    }
};

pub const HullShaderOptions = struct {
    filepath: ?[]const u8 = null,
    defines: []const ShaderDefineTuple = &.{},
};

pub const HullShader = struct {
    platform: pl.GfxPlatform.HullShader,
    
    pub fn deinit(self: *const HullShader) void {
        self.platform.deinit();
    }
    
    pub fn init_file(
        alloc: std.mem.Allocator,
        hs_path: path.Path, 
        hs_func: []const u8,
        options: HullShaderOptions,
    ) !HullShader {
        const res_path = try hs_path.resolve_path(alloc);
        defer alloc.free(res_path);

        var modified_options = options;
        modified_options.filepath = res_path;

        var file = try std.fs.cwd().openFile(res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer file.close();

        const file_len = try file.getEndPos();

        const buf: []u8 = try alloc.alloc(u8, @intCast(file_len));
        defer alloc.free(buf);

        if (try file.readAll(buf) != file_len) {
            return error.FailedToReadShader;
        }

        return init_buffer(buf, hs_func, modified_options);
    }

    pub fn init_buffer(
        hs_data: []const u8, 
        hs_func: []const u8,
        options: HullShaderOptions,
    ) !HullShader {
        const platform = pl.GfxPlatform.HullShader.init_buffer(hs_data, hs_func, options) catch |err| {
            std.log.err("Hull shader init failed: {s}\n\t- {s}", .{
                @errorName(err),
                options.filepath orelse "no filepath provided",
            });
            return err;
        };
        return HullShader {
            .platform = platform,
        };
    }
};

pub const DomainShaderOptions = struct {
    filepath: ?[]const u8 = null,
    defines: []const ShaderDefineTuple = &.{},
};

pub const DomainShader = struct {
    platform: pl.GfxPlatform.DomainShader,
    
    pub fn deinit(self: *const DomainShader) void {
        self.platform.deinit();
    }
    
    pub fn init_file(
        alloc: std.mem.Allocator,
        ds_path: path.Path, 
        ds_func: []const u8,
        options: DomainShaderOptions,
    ) !DomainShader {
        const res_path = try ds_path.resolve_path(alloc);
        defer alloc.free(res_path);

        var modified_options = options;
        modified_options.filepath = res_path;

        var file = try std.fs.cwd().openFile(res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer file.close();

        const file_len = try file.getEndPos();

        const buf: []u8 = try alloc.alloc(u8, @intCast(file_len));
        defer alloc.free(buf);

        if (try file.readAll(buf) != file_len) {
            return error.FailedToReadShader;
        }

        return init_buffer(buf, ds_func, modified_options);
    }

    pub fn init_buffer(
        ds_data: []const u8, 
        ds_func: []const u8,
        options: DomainShaderOptions,
    ) !DomainShader {
        const platform = pl.GfxPlatform.DomainShader.init_buffer(ds_data, ds_func, options) catch |err| {
            std.log.err("Domain shader init failed: {s}\n\t- {s}", .{
                @errorName(err),
                options.filepath orelse "no filepath provided",
            });
            return err;
        };
        return DomainShader {
            .platform = platform,
        };
    }
};

pub const GeometryShaderOptions = struct {
    filepath: ?[]const u8 = null,
    defines: []const ShaderDefineTuple = &.{},
};

pub const GeometryShader = struct {
    platform: pl.GfxPlatform.GeometryShader,
    
    pub fn deinit(self: *const GeometryShader) void {
        self.platform.deinit();
    }
    
    pub fn init_file(
        alloc: std.mem.Allocator,
        gs_path: path.Path, 
        gs_func: []const u8,
        options: GeometryShaderOptions,
    ) !GeometryShader {
        const res_path = try gs_path.resolve_path(alloc);
        defer alloc.free(res_path);

        var modified_options = options;
        modified_options.filepath = res_path;

        var file = try std.fs.cwd().openFile(res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer file.close();

        const file_len = try file.getEndPos();

        const buf: []u8 = try alloc.alloc(u8, @intCast(file_len));
        defer alloc.free(buf);

        if (try file.readAll(buf) != file_len) {
            return error.FailedToReadShader;
        }

        return init_buffer(buf, gs_func, modified_options);
    }

    pub fn init_buffer(
        gs_data: []const u8, 
        gs_func: []const u8,
        options: GeometryShaderOptions,
    ) !GeometryShader {
        const platform = pl.GfxPlatform.GeometryShader.init_buffer(gs_data, gs_func, options) catch |err| {
            std.log.err("Geometry shader init failed: {s}\n\t- {s}", .{
                @errorName(err),
                options.filepath orelse "no filepath provided",
            });
            return err;
        };
        return GeometryShader {
            .platform = platform,
        };
    }
};

pub const ComputeShaderOptions = struct {
    filepath: ?[]const u8 = null,
    defines: []const ShaderDefineTuple = &.{},
};

pub const ComputeShader = struct {
    platform: pl.GfxPlatform.ComputeShader,
    
    pub fn deinit(self: *const ComputeShader) void {
        self.platform.deinit();
    }
    
    pub fn init_file(
        alloc: std.mem.Allocator,
        cs_path: path.Path, 
        cs_func: []const u8,
        options: ComputeShaderOptions,
    ) !ComputeShader {
        const cs_res_path = try cs_path.resolve_path(alloc);
        defer alloc.free(cs_res_path);

        var modified_options = options;
        modified_options.filepath = cs_res_path;

        var cs_file = try std.fs.cwd().openFile(cs_res_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer cs_file.close();

        const cs_file_len = try cs_file.getEndPos();

        const cs_buf: []u8 = try alloc.alloc(u8, @intCast(cs_file_len));
        defer alloc.free(cs_buf);

        if (try cs_file.readAll(cs_buf) != cs_file_len) {
            return error.FailedToReadShader;
        }

        return init_buffer(cs_buf, cs_func, modified_options);
    }

    pub fn init_buffer(
        cs_data: []const u8, 
        cs_func: []const u8, 
        options: ComputeShaderOptions,
    ) !ComputeShader {
        const platform = pl.GfxPlatform.ComputeShader.init_buffer(cs_data, cs_func, options) catch |err| {
            std.log.err("Compute shader init failed: {s}", .{@errorName(err)});
            return err;
        };
        return ComputeShader {
            .platform = platform,
        };
    }
};

pub fn Reference(comptime Type: type) type {
    return struct {
        const Self = @This();

        id: gen.GenerationalIndex,

        pub fn deinit(self: *const Self) void {
            if (self.get()) |asset| {
                asset.deinit();
            } else |_| {
                std.log.warn("Unable to retrieve {s} asset", .{@typeName(Type)});
            }
            gfxstate_list().remove(self.id) catch |err| {
                std.log.warn("Unable to remove {s} asset: {}", .{@typeName(Type), err});
            };
        }

        pub fn get(self: *const Self) !*Type {
            return gfxstate_list().get(self.id) orelse return error.UnableToRetrieveAsset;
        }

        inline fn gfxstate_list() *gen.GenerationalList(Type) {
            return switch (Type) {
                Buffer => &GfxState.get().buffers,
                Image => &GfxState.get().images,
                ImageView => &GfxState.get().image_views,
                Sampler => &GfxState.get().samplers,
                RenderPass => &GfxState.get().render_passes,
                GraphicsPipeline => &GfxState.get().graphics_pipelines,
                FrameBuffer => &GfxState.get().framebuffers,
                DescriptorLayout => &GfxState.get().descriptor_layouts,
                DescriptorPool => &GfxState.get().descriptor_pools,
                CommandPool => &GfxState.get().command_pools,
                else => unreachable,
            };
        }
    };
}

pub const Buffer = struct {
    pub const Ref = Reference(Buffer);

    platform: pl.GfxPlatform.Buffer,

    pub fn deinit(self: *const Buffer) void {
        self.platform.deinit();
    }

    pub fn init(
        byte_size: u32,
        usage_flags: BufferUsageFlags,
        access_flags: AccessFlags,
    ) !Buffer.Ref {
        const platform = try pl.GfxPlatform.Buffer.init(byte_size, usage_flags, access_flags);
        errdefer platform.deinit();

        const buffer = Buffer {
            .platform = platform,
        };

        return Buffer.Ref {
            .id = try GfxState.get().buffers.insert(buffer),
        };
    }
    
    pub fn init_with_data(
        data: []const u8,
        usage_flags: BufferUsageFlags,
        access_flags: AccessFlags,
    ) !Buffer.Ref {
        const platform = try pl.GfxPlatform.Buffer.init_with_data(data, usage_flags, access_flags);
        errdefer platform.deinit();

        const buffer = Buffer {
            .platform = platform,
        };

        return Buffer.Ref {
            .id = try GfxState.get().buffers.insert(buffer),
        };
    }

    pub const MapOptions = struct {
        read: bool = false,
        write: bool = false,
    };

    pub fn map(self: *const Buffer, options: MapOptions) !MappedBuffer {
        return MappedBuffer {
            .platform = try self.platform.map(options),
        };
    }

    pub const MappedBuffer = struct {
        platform: pl.GfxPlatform.Buffer.MappedBuffer,

        pub fn unmap(self: *const MappedBuffer) void {
            self.platform.unmap();
        }

        pub fn data(self: *const MappedBuffer, comptime Type: type) *Type {
            return self.platform.data(Type);
        }

        pub fn data_array(self: *const MappedBuffer, comptime Type: type, length: usize) []Type {
            return self.platform.data_array(Type, length);
        }
    };
};

pub const ImageInfo = struct {
    format: ImageFormat,

    match_swapchain_extent: bool = false,
    width: u32 = 1,
    height: u32 = 1,
    depth: u32 = 1,
    mip_levels: u32 = 1,
    array_length: u32 = 1,

    usage_flags: TextureUsageFlags,
    access_flags: AccessFlags,
};

pub const Image = struct {
    pub const Ref = Reference(Image);

    info: ImageInfo,
    platform: GfxState.Platform.Image,
    child_views: std.ArrayList(ImageView.Ref),

    pub fn deinit(self: *const Image) void {
        self.child_views.deinit();
        self.platform.deinit();
    }

    pub fn init(info: ImageInfo, data: ?[]const u8) !Image.Ref {
        var modified_info = info;
        if (modified_info.match_swapchain_extent) {
            modified_info.width = GfxState.get().swapchain_size()[0];
            modified_info.height = GfxState.get().swapchain_size()[1];
        }

        const platform = try GfxState.Platform.Image.init(modified_info, data);
        errdefer platform.deinit();

        const image = Image {
            .platform = platform,
            .info = info,
            .child_views = std.ArrayList(ImageView.Ref).init(eng.get().general_allocator),
        };

        return Image.Ref {
            .id = try GfxState.get().images.insert(image),
        };
    }

    pub fn init_colour(info: ImageInfo, colour: zm.F32x4) !Image.Ref {
        if (info.format.byte_width() != 4) { return error.FormatByteWidthMustBe4; }
        if (info.array_length != 1) { return error.CannotSetColourOnImageArray; }
        if (info.mip_levels != 1) { return error.CannotSetColourOnMippedImage; }

        var modified_info = info;
        if (modified_info.match_swapchain_extent) {
            modified_info.width = GfxState.get().swapchain_size()[0];
            modified_info.height = GfxState.get().swapchain_size()[1];
        }

        const alloc = eng.get().frame_allocator;

        const data = try alloc.alloc(u8, modified_info.width * modified_info.height * modified_info.depth * 4);
        defer alloc.free(data);

        const data_u32: *const align(1) []u32 = @ptrCast(&data);
        const clamped_colour = zm.clamp(colour, zm.f32x4s(0.0), zm.f32x4s(1.0));
        const colour_u8: [4]u8 = .{
            @intFromFloat(clamped_colour[0] * 255),
            @intFromFloat(clamped_colour[1] * 255),
            @intFromFloat(clamped_colour[2] * 255),
            @intFromFloat(clamped_colour[3] * 255),
        };
        const colour_u32: *const align(1) u32 = @ptrCast(&colour_u8);

        @memset(data_u32.*[0..(data.len / 4)], colour_u32.*);

        return try Image.init(modified_info, data);
    }

    pub const MapOptions = struct {
        read: bool = false,
        write: bool = false,
    };

    pub fn map(self: *const Image, options: MapOptions) !MappedImage {
        return MappedImage {
            .platform = try self.platform.map(options),
        };
    }

    pub const MappedImage = struct {
        platform: pl.GfxPlatform.Image.MappedImage,

        pub fn unmap(self: *const MappedImage) void {
            self.platform.unmap();
        }

        pub fn data(self: *const MappedImage, comptime Type: type) [*]align(16)Type {
            return self.platform.data(Type);
        }
    };
};

pub const ImageViewInfo = struct {
    image: Image.Ref,
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 1,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 1,
};

pub const ImageView = struct {
    pub const Ref = Reference(ImageView);

    platform: GfxState.Platform.ImageView,
    info: ImageViewInfo,
    size: struct { width: u32, height: u32, },

    pub fn deinit(self: *ImageView) void {
        self.platform.deinit();
    }

    pub fn init(info: ImageViewInfo) !ImageView.Ref {
        const platform = try GfxState.Platform.ImageView.init(info);
        errdefer platform.deinit();

        const image = try info.image.get();

        const image_view = ImageView {
            .platform = platform,
            .info = info,
            .size = .{
                .width = @divFloor(image.info.width, std.math.pow(u32, 2, info.base_mip_level)),
                .height = @divFloor(image.info.height, std.math.pow(u32, 2, info.base_mip_level)),
            },
        };

        const view_ref = ImageView.Ref {
            .id = try GfxState.get().image_views.insert(image_view),
        };
        errdefer GfxState.get().image_views.remove(view_ref.id) catch {};

        try image.child_views.append(view_ref);

        return view_ref;
    }
};

pub const ImageFormat = enum {
    Unknown,
    Rgba8_Unorm_Srgb,
    Rgba8_Unorm,
    Bgra8_Unorm,
    R32_Float,
    R32_Uint,
    Rg32_Float,
    Rgba16_Float,
    Rgba32_Float,
    Rg11b10_Float,
    R24X8_Unorm_Uint,
    D24S8_Unorm_Uint,

    pub fn byte_width(self: ImageFormat) usize {
        switch (self) {
            .Unknown => return 0,
            .R32_Float => return 4,
            .R32_Uint => return 4,
            .Rg32_Float => return 8,
            .Rgba8_Unorm_Srgb => return 4,
            .Rgba8_Unorm => return 4,
            .Bgra8_Unorm => return 4,
            .Rgba16_Float => return 8,
            .Rgba32_Float => return 16,
            .Rg11b10_Float => return 3,
            .R24X8_Unorm_Uint => return 4,
            .D24S8_Unorm_Uint => return 4,
        }
    }

    pub fn is_depth(self: ImageFormat) bool {
        switch (self) {
            .D24S8_Unorm_Uint => return true,
            else => return false,
        }
    }
};

pub const BufferUsageFlags = packed struct {
    VertexBuffer: bool = false,
    IndexBuffer: bool = false,
    ConstantBuffer: bool = false,
    ShaderResource: bool = false,
    TransferSrc: bool = false,
    TransferDst: bool = false,
};

pub const TextureUsageFlags = packed struct {
    ShaderResource: bool = false,
    RenderTarget: bool = false,
    DepthStencil: bool = false,
    TransferSrc: bool = false,
    TransferDst: bool = false,
};

pub const AccessFlags = packed struct(u32) {
    GpuWrite: bool = false,
    CpuRead: bool = false,
    CpuWrite: bool = false,
    __unused: u29 = 0,
};

pub const RasterizationStateDesc = packed struct(u3) {
    FillBack: bool = true,
    FillFront: bool = true,
    FrontCounterClockwise: bool = false,
};

pub const SamplerInfo = struct {
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
};

pub const Sampler = struct {
    pub const Ref = Reference(Sampler);

    platform: GfxState.Platform.Sampler,
    info: SamplerInfo,

    pub fn deinit(self: *const Sampler) void {
        self.platform.deinit();
    }

    pub fn init(info: SamplerInfo) !Sampler.Ref {
        const platform = try pl.GfxPlatform.Sampler.init(info);
        errdefer platform.deinit();

        const sampler = Sampler {
            .platform = platform,
            .info = info,
        };

        return Sampler.Ref {
            .id = try GfxState.get().samplers.insert(sampler),
        };
    }
};

pub const BlendType = enum {
    None,
    Simple,
    PremultipliedAlpha,
};

pub const FillMode = enum {
    Fill,
    Line,
    Point,
};

pub const CullMode = enum {
    CullNone,
    CullFront,
    CullBack,
    CullFrontAndBack,
};

pub const FrontFace = enum {
    CounterClockwise,
    Clockwise,
};

pub const CompareOp = enum {
    Never,
    Less,
    Equal,
    LessOrEqual,
    Greater,
    NotEqual,
    GreaterOrEqual,
    Always,
};

pub const AttachmentLoadOp = enum {
    Load,
    Clear,
    DontCare,
};

pub const AttachmentStoreOp = enum {
    Store,
    DontCare,
};

pub const AttachmentInfo = struct {
    name: []const u8, // an identifier to relate this attachment to attachments in other subpasses
    format: ImageFormat,
    blend_type: BlendType = BlendType.None,

    load_op: AttachmentLoadOp = AttachmentLoadOp.Load,
    store_op: AttachmentStoreOp = AttachmentStoreOp.Store,

    stencil_load_op: AttachmentLoadOp = AttachmentLoadOp.Load,
    stencil_store_op: AttachmentStoreOp = AttachmentStoreOp.Store,

    clear_value: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
};

pub const SubpassInfo = struct {
    attachments: []const []const u8,
    depth_attachment: ?[]const u8 = null,
};

pub const RenderPassInfo = struct {
    attachments: []const AttachmentInfo,
    subpasses: []const SubpassInfo,
};

pub const RenderPass = struct {
    const Self = @This();
    pub const Ref = Reference(Self);

    platform: GfxState.Platform.RenderPass,

    pub fn deinit(self: *const Self) void {
        self.platform.deinit();
    }

    pub fn init(info: RenderPassInfo) !RenderPass.Ref {
        const platform = try pl.GfxPlatform.RenderPass.init(info);
        errdefer platform.deinit();

        const render_pass = RenderPass {
            .platform = platform,
        };

        return Self.Ref {
            .id = try GfxState.get().render_passes.insert(render_pass),
        };
    }
};

pub const GraphicsPipelineInfo = struct {
    vertex_shader: *const VertexShader,
    pixel_shader: *const PixelShader,

    topology: Topology = Topology.TriangleList,

    cull_mode: CullMode = CullMode.CullBack,
    front_face: FrontFace = FrontFace.CounterClockwise,

    rasterization_fill_mode: FillMode = FillMode.Fill,
    rasterization_line_width: f32 = 1.0,

    depth_test: ?struct {
        write: bool = false,
        compare_op: CompareOp = CompareOp.GreaterOrEqual,
    } = null,

    stencil_test: ?struct {
        // @TODO
    } = null,

    depth_clamp: bool = false,
    depth_bias: ?struct {
        constant_factor: f32,
        clamp: f32,
        slope_factor: f32,
    } = null,

    attachments: []const AttachmentInfo,
    render_pass: RenderPass.Ref,
    subpass_index: u32 = 0,
};

pub const GraphicsPipeline = struct {
    pub const Ref = Reference(GraphicsPipeline);

    platform: GfxState.Platform.GraphicsPipeline,
    info: GraphicsPipelineInfo,

    pub fn deinit(self: *const GraphicsPipeline) void {
        self.platform.deinit();
    }
    
    pub fn init(info: GraphicsPipelineInfo) !GraphicsPipeline.Ref {
        const platform = try pl.GfxPlatform.GraphicsPipeline.init(info);
        errdefer platform.deinit();

        const graphics_pipeline = GraphicsPipeline {
            .platform = platform,
            .info = info,
        };

        return GraphicsPipeline.Ref {
            .id = try GfxState.get().graphics_pipelines.insert(graphics_pipeline),
        };
    }
};

pub const FrameBufferAttachmentInfo = union(enum) {
    View: ImageView.Ref,
    Swapchain: void,
    SwapchainDepth: void,
};

pub const FrameBufferInfo = struct {
    render_pass: RenderPass.Ref,
    attachments: []const FrameBufferAttachmentInfo,
};

pub const FrameBuffer = struct {
    pub const Ref = Reference(FrameBuffer);

    platform: GfxState.Platform.FrameBuffer,

    pub fn deinit(self: *const FrameBuffer) void {
        self.platform.deinit();
    }

    pub fn init(info: FrameBufferInfo) !FrameBuffer.Ref {
        const platform = try pl.GfxPlatform.FrameBuffer.init(info);
        errdefer platform.deinit();

        const framebuffer = FrameBuffer {
            .platform = platform,
        };

        return FrameBuffer.Ref {
            .id = try GfxState.get().framebuffers.insert(framebuffer),
        };
    }
};

pub const BindingType = enum {
    UniformBuffer,
    StorageBuffer,
    ImageView,
    Sampler,
    ImageViewAndSampler,
};

pub const DescriptorBindingInfo = struct {
    binding: u32,
    binding_type: BindingType,
    array_count: u32 = 1,
    shader_stages: ShaderStageFlags,
};

pub const DescriptorLayoutInfo = struct {
    bindings: []const DescriptorBindingInfo,
};

pub const DescriptorLayout = struct {
    pub const Ref = Reference(DescriptorLayout);

    platform: GfxState.Platform.DescriptorLayout,
    info: DescriptorLayoutInfo,

    pub fn deinit(self: *const DescriptorLayout) void {
        self.platform.deinit();
    }

    pub fn init(info: DescriptorLayoutInfo) !DescriptorLayout.Ref {
        const platform = try GfxState.Platform.DescriptorLayout.init(info);
        errdefer platform.deinit();

        const layout = DescriptorLayout {
            .platform = platform,
            .info = info,
        };

        return DescriptorLayout.Ref {
            .id = try GfxState.get().descriptor_layouts.insert(layout),
        };
    }
};

pub const PoolSizeInfo = struct {
    binding_type: BindingType,
    count: u32,
};

pub const DescriptorPoolInfo = struct {
    strategy: union(enum) {
        Layout: DescriptorLayout.Ref,
        Manual: []const PoolSizeInfo,
    },
    max_sets: u32,
};

pub const DescriptorPool = struct {
    pub const Ref = Reference(DescriptorPool);

    platform: GfxState.Platform.DescriptorPool,

    pub fn deinit(self: *const DescriptorPool) void {
        self.platform.deinit();
    }

    pub fn init(info: DescriptorPoolInfo) !DescriptorPool.Ref {
        const platform = try GfxState.Platform.DescriptorPool.init(info);
        errdefer platform.deinit();

        const pool = DescriptorPool {
            .platform = platform,
        };

        return DescriptorPool.Ref {
            .id = try GfxState.get().descriptor_pools.insert(pool),
        };
    }

    pub fn allocate_sets(
        self: *const DescriptorPool,
        alloc: std.mem.Allocator,
        info: DescriptorSetInfo,
        number_of_sets: u32
    ) ![]DescriptorSet {
        // TODO track resources
        const sets = try self.platform.allocate_sets(alloc, info, number_of_sets);
        return sets;
    }
};

pub const DescriptorSetInfo = struct {
    layout: DescriptorLayout.Ref,
};

pub const DescriptorSetWriteBufferInfo = struct {
    buffer: Buffer.Ref,
    offset: u64 = 0,
    range: u64 = std.math.maxInt(u64),
};

pub const DescriptorSetUpdateWriteInfo = struct {
    binding: u32,
    array_element: u32 = 0,
    array_count: u32 = 1,
    data: union(BindingType) {
        UniformBuffer: []const DescriptorSetWriteBufferInfo,
        StorageBuffer: []const DescriptorSetWriteBufferInfo,
        ImageView: []const ImageView.Ref,
        Sampler: []const Sampler.Ref,
        ImageViewAndSampler: []const struct{ view: ImageView.Ref, sampler: Sampler.Ref, },
    },
};

pub const DescriptorSetUpdateInfo = struct {
    writes: []const DescriptorSetUpdateWriteInfo,
};

pub const DescriptorSet = struct {
    pub const Ref = Reference(DescriptorSet);

    platform: GfxState.Platform.DescriptorSet,

    pub fn deinit(self: *const DescriptorSet) void {
        self.platform.deinit();
    }

    pub fn update(self: *DescriptorSet, info: DescriptorSetUpdateInfo) void {
        self.platform.update(info);
    }
};

pub const CommandPoolInfo = struct {
    transient_buffers: bool = false,
    allow_reset_command_buffers: bool = false,
    queue_family: QueueFamily,
};

pub const CommandPool = struct {
    const Self = @This();
    pub const Ref = Reference(CommandPool);
    
    platform: GfxState.Platform.CommandPool,

    pub fn deinit(self: *const Self) void {
        self.platform.deinit();
    }

    pub fn init(info: CommandPoolInfo) !Self.Ref {
        const platform = try GfxState.Platform.CommandPool.init(info);
        errdefer platform.deinit();

        const pool = CommandPool {
            .platform = platform,
        };

        return Self.Ref {
            .id = try GfxState.get().command_pools.insert(pool),
        };
    }

    pub fn allocate_command_buffer(self: *Self, info: CommandBufferInfo) !CommandBuffer {
        return CommandBuffer {
            .platform = try self.platform.allocate_command_buffer(info),
        };
    }
};

pub const CommandBufferLevel = enum {
    Primary,
    Secondary,
};

pub const CommandBufferInfo = struct {
    level: CommandBufferLevel = .Primary,
};

pub const CommandBuffer = struct {
    const Self = @This();

    platform: GfxState.Platform.CommandBuffer,

    pub fn deinit(self: *const Self) void {
        self.platform.deinit();
    }

    pub fn cmd_begin(self: *Self) !void {
        self.platform.cmd_begin();
    }

    pub fn cmd_end(self: *Self) !void {
        self.platform.cmd_end();
    }

    pub const BeginRenderPassInfo = struct {
        pub const SubpassContents = enum {
            Inline,
            SecondaryCommandBuffers,
        };

        render_pass: RenderPass.Ref,
        framebuffer: FrameBuffer.Ref,
        render_area: Rect = .{ .top = 0.0, .left = 0.0, .bottom = 1.0, .right = 1.0, },
        subpass_contents: SubpassContents = .Inline,
    };

    pub fn cmd_begin_render_pass(self: *Self, info: BeginRenderPassInfo) void {
        self.platform.cmd_begin_render_pass(info);
    }

    pub fn cmd_end_render_pass(self: *Self) void {
        self.platform.cmd_end_render_pass();
    }

    pub fn cmd_bind_graphics_pipeline(self: *Self, pipeline: GraphicsPipeline.Ref) void {
        self.platform.cmd_bind_graphics_pipeline(pipeline);
    }

    pub const SetViewportsInfo = struct {
        viewports: []const Viewport,
        first_viewport: u32 = 0,
    };

    pub fn cmd_set_viewports(self: *Self, info: SetViewportsInfo) void {
        self.platform.cmd_set_viewports(info);
    }

    pub const SetScissorsInfo = struct {
        scissors: []const Rect,
        first_scissor: u32 = 0,
    };

    pub fn cmd_set_scissors(self: *Self, info: SetScissorsInfo) void {
        self.platform.cmd_set_scissor(info);
    }

    pub const VertexBufferBindInfo = struct {
        buffer: Buffer.Ref,
        offset: u64 = 0,
    };

    pub const BindVertexBuffersInfo = struct {
        first_binding: u32 = 0,
        buffers: []const VertexBufferBindInfo,
    };

    pub fn cmd_bind_vertex_buffers(self: *Self, info: BindVertexBuffersInfo) void {
        self.platform.cmd_bind_vertex_buffers(info);
    }

    pub const BindIndexBufferInfo = struct {
        buffer: Buffer.Ref,
        index_format: IndexFormat,
        offset: u64 = 0,
    };

    pub fn cmd_bind_index_buffer(self: *Self, info: BindIndexBufferInfo) void {
        self.platform.cmd_bind_index_buffer(info);
    }

    pub const BindDescriptorSetInfo = struct {
        graphics_pipeline: GraphicsPipeline.Ref,
        first_binding: u32 = 0,
        descriptor_sets: []const DescriptorSet.Ref,
        dynamic_offsets: []const u32 = &.{},
    };

    pub fn cmd_bind_descriptor_sets(self: *Self, info: BindDescriptorSetInfo) void {
        self.platform.cmd_bind_descriptor_sets(info);
    }

    pub const DrawInfo = struct {
        vertex_count: u32,
        first_vertex: u32 = 0,
        instance_count: u32 = 1,
        first_instance: u32 = 0,
    };

    pub fn cmd_draw(self: *Self, info: DrawInfo) void {
        self.platform.cmd_draw(info);
    }

    pub const DrawIndexedInfo = struct {
        index_count: u32,
        first_index: u32 = 0,
        vertex_offset: i32 = 0,
        instance_count: u32 = 1,
        first_instance: u32 = 0,
    };

    pub fn cmd_draw_indexed(self: *Self, info: DrawIndexedInfo) void {
        self.platform.cmd_draw_indexed(info);
    }
};

pub const SemaphoreCreateInfo = struct {
};

pub const Semaphore = struct {
    const Self = @This();

    platform: GfxState.Platform.Semaphore,

    pub fn deinit(self: *const Self) void {
        self.platform.deinit();
    }

    pub fn init(info: SemaphoreCreateInfo) !Self {
        return try GfxState.Platform.Semaphore.init(info);
    }
};

pub const FenceCreateInfo = struct {
    create_signalled: bool = false,
};

pub const Fence = struct {
    const Self = @This();

    platform: GfxState.Platform.Fence,

    pub fn deinit(self: *const Self) void {
        self.platform.deinit();
    }

    pub fn init(info: FenceCreateInfo) !Self {
        return try GfxState.Platform.Fence.init(info);
    }

    pub fn wait(self: *Self) !void {
        try self.platform.wait();
    }

    pub fn wait_all(fences: []const *Self) !void {
        try GfxState.Platform.Fence.wait_all(fences);
    }

    pub fn reset(self: *Self) !void {
        try self.platform.reset();
    }
};
