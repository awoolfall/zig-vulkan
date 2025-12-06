const std = @import("std");
const builtin = @import("builtin");
const zm = @import("zmath");
const wb = @import("../window.zig");
const path = @import("../engine/path.zig");
const bloom = @import("bloom.zig");
const pl = @import("../platform/platform.zig");
const gen = @import("self").gen;
const ToneMappingFilter = @import("tonemapping_filter.zig");
const BloomFilter = @import("bloom.zig");
const ShaderManager = @import("shader_manager.zig");

const eng = @import("../root.zig");
const Rect = eng.Rect;

pub const GfxState = struct {
    const Self = @This();
    const Platform = pl.GfxPlatform;

    pub const FULL_SCREEN_QUAD_VS = @embedFile("full_screen_quad_vs.slang");

    platform: Platform,

    shader_manager: ShaderManager,

    buffers: gen.GenerationalList(Buffer),
    images: gen.GenerationalList(Image),
    image_views: gen.GenerationalList(ImageView),
    samplers: gen.GenerationalList(Sampler),

    render_passes: gen.GenerationalList(RenderPass),
    graphics_pipelines: gen.GenerationalList(GraphicsPipeline),
    compute_pipelines: gen.GenerationalList(ComputePipeline),
    framebuffers: gen.GenerationalList(FrameBuffer),

    descriptor_layouts: gen.GenerationalList(DescriptorLayout),
    descriptor_pools: gen.GenerationalList(DescriptorPool),
    descriptor_sets: gen.GenerationalList(DescriptorSet),

    command_pools: gen.GenerationalList(CommandPool),

    tone_mapping_filter: ToneMappingFilter,
    bloom_filter: BloomFilter,

    default: struct {
        hdr_image: Image.Ref,
        hdr_image_view: ImageView.Ref,

        depth_image: Image.Ref,
        depth_view: ImageView.Ref,

        sampler: Sampler.Ref,

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
    },

    pub const hdr_format = ImageFormat.Rgba16_Float;
    pub const ldr_format = ImageFormat.Bgra8_Srgb;// ImageFormat.Rgba8_Unorm;
    pub const depth_format = ImageFormat.D32S8_Sfloat_Uint;

    pub fn deinit(self: *Self) void {
        std.log.debug("gfx deinit", .{});

        self.tone_mapping_filter.deinit();
        self.bloom_filter.deinit();

        self.default.hdr_image_view.deinit();
        self.default.hdr_image.deinit();
        self.default.depth_view.deinit();
        self.default.depth_image.deinit();
        self.default.sampler.deinit();
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
        self.shader_manager.deinit();

        self.buffers.deinit();
        self.images.deinit();
        self.image_views.deinit();
        self.samplers.deinit();

        self.framebuffers.deinit();
        self.graphics_pipelines.deinit();
        self.compute_pipelines.deinit();
        self.render_passes.deinit();

        self.descriptor_sets.deinit();
        self.descriptor_pools.deinit();
        self.descriptor_layouts.deinit();

        self.command_pools.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, window: *pl.Window) !Self {
        var shader_manager = try ShaderManager.init();
        errdefer shader_manager.deinit();

        var buffers = try gen.GenerationalList(Buffer).init(alloc);
        errdefer buffers.deinit();

        var images = try gen.GenerationalList(Image).init(alloc);
        errdefer images.deinit();

        var image_views = try gen.GenerationalList(ImageView).init(alloc);
        errdefer image_views.deinit();

        var samplers = try gen.GenerationalList(Sampler).init(alloc);
        errdefer samplers.deinit();


        var render_passes = try gen.GenerationalList(RenderPass).init(alloc);
        errdefer render_passes.deinit();

        var graphics_pipelines = try gen.GenerationalList(GraphicsPipeline).init(alloc);
        errdefer graphics_pipelines.deinit();
        
        var compute_pipelines = try gen.GenerationalList(ComputePipeline).init(alloc);
        errdefer compute_pipelines.deinit();

        var framebuffers = try gen.GenerationalList(FrameBuffer).init(alloc);
        errdefer framebuffers.deinit();


        var descriptor_layouts = try gen.GenerationalList(DescriptorLayout).init(alloc);
        errdefer descriptor_layouts.deinit();
        
        var descriptor_pools = try gen.GenerationalList(DescriptorPool).init(alloc);
        errdefer descriptor_pools.deinit();

        var descriptor_sets = try gen.GenerationalList(DescriptorSet).init(alloc);
        errdefer descriptor_sets.deinit();

        var command_pools = try gen.GenerationalList(CommandPool).init(alloc);
        errdefer command_pools.deinit();


        const platform = try Self.Platform.init(alloc, window);
        errdefer platform.deinit();

        return Self {
            .platform = platform,
            .shader_manager = shader_manager,
            
            .buffers = buffers,
            .images = images,
            .image_views = image_views,
            .samplers = samplers,
            .render_passes = render_passes,
            .graphics_pipelines = graphics_pipelines,
            .compute_pipelines = compute_pipelines,
            .framebuffers = framebuffers,
            .descriptor_layouts = descriptor_layouts,
            .descriptor_pools = descriptor_pools,
            .descriptor_sets = descriptor_sets,
            .command_pools = command_pools,
            
            .default = undefined,
            .tone_mapping_filter = undefined,
            .bloom_filter = undefined,
        };
    }

    pub fn init_late(self: *Self, window: *pl.Window) !void {
        try self.platform.init_late(window);

        self.default.hdr_image = try Image.init(.{
            .format = GfxState.hdr_format,
            .match_swapchain_extent = true,

            .usage_flags = .{ .RenderTarget = true, .TransferSrc = true, .ShaderResource = true, },
            .access_flags = .{ .GpuWrite = true, },
            .dst_layout = .ColorAttachmentOptimal,
        }, null);
        errdefer self.default.hdr_image.deinit();

        self.default.hdr_image_view = try ImageView.init(.{
            .image = self.default.hdr_image,
            .view_type = .ImageView2D,
        });
        errdefer self.default.hdr_image_view.deinit();

        self.default.depth_image = try Image.init(.{
            .format = Self.depth_format,
            .match_swapchain_extent = true,

            .usage_flags = .{ .DepthStencil = true, },
            .access_flags = .{ .GpuWrite = true, },
            .dst_layout = .DepthStencilAttachmentOptimal,
        }, null);
        errdefer self.default.depth_image.deinit();

        self.default.depth_view = try ImageView.init(.{
            .image = self.default.depth_image,
            .view_type = .ImageView2D,
        });
        errdefer self.default.depth_view.deinit();

        self.default.sampler = try Sampler.init(.{});
        errdefer self.default.sampler.deinit();

        self.default.diffuse = try init_single_pixel_texture(zm.f32x4s(1.0));
        errdefer self.default.diffuse.deinit();

        self.default.diffuse_view = try ImageView.init(.{
            .image = self.default.diffuse,
            .view_type = .ImageView2D,
        });
        errdefer self.default.diffuse_view.deinit();

        self.default.normals = try init_single_pixel_texture(zm.f32x4(0.5, 0.5, 1.0, 1.0));
        errdefer self.default.normals.deinit();

        self.default.normals_view = try ImageView.init(.{
            .image = self.default.normals,
            .view_type = .ImageView2D,
        });
        errdefer self.default.normals_view.deinit();

        self.default.metallic_roughness = try init_single_pixel_texture(zm.f32x4(0.0, 1.0, 1.0, 1.0));
        errdefer self.default.metallic_roughness.deinit();

        self.default.metallic_roughness_view = try ImageView.init(.{
            .image = self.default.metallic_roughness,
            .view_type = .ImageView2D,
        });
        errdefer self.default.metallic_roughness_view.deinit();
        
        self.default.ambient_occlusion = try init_single_pixel_texture(zm.f32x4s(1.0));
        errdefer self.default.ambient_occlusion.deinit();

        self.default.ambient_occlusion_view = try ImageView.init(.{
            .image = self.default.ambient_occlusion,
            .view_type = .ImageView2D,
        });
        errdefer self.default.ambient_occlusion_view.deinit();

        self.default.emission = try init_single_pixel_texture(zm.f32x4(0.0, 0.0, 0.0, 1.0));
        errdefer self.default.emission.deinit();

        self.default.emission_view = try ImageView.init(.{
            .image = self.default.emission,
            .view_type = .ImageView2D,
        });
        errdefer self.default.emission_view.deinit();


        self.tone_mapping_filter = try ToneMappingFilter.init();
        errdefer self.tone_mapping_filter.deinit();

        self.bloom_filter = try BloomFilter.init();
        errdefer self.bloom_filter.deinit();
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

    pub fn frames_in_flight(self: *const Self) u32 {
        return self.platform.frames_in_flight();
    }

    pub fn current_frame_index(self: *const Self) u32 {
        return self.platform.current_frame_index();
    }

    fn init_single_pixel_texture(colour: zm.F32x4) !Image.Ref {
        return try Image.init_colour(
            .{
                .width = 1,
                .height = 1,
                .format = .Rgba8_Unorm,

                .usage_flags = .{ .ShaderResource = true, },
                .access_flags = .{},
                .dst_layout = .ShaderReadOnlyOptimal,
            },
            colour,
        );
    }

    pub fn begin_frame(self: *Self) !Semaphore {
        return try self.platform.begin_frame();
    }

    pub const SubmitWaitSemaphoreInfo = struct {
        semaphore: *const Semaphore,
        dst_stage: PipelineStageFlags,
    };

    pub const SubmitInfo = struct {
        command_buffers: []const *const CommandBuffer,
        signal_semaphores: []const *const Semaphore = &.{},
        wait_semaphores: []const SubmitWaitSemaphoreInfo = &.{},
        fence: ?Fence = null,
    };

    pub fn submit_command_buffer(self: *Self, info: SubmitInfo) !void {
        try self.platform.submit_command_buffer(info);
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
    offset: u64 = 0,
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

pub const ShaderStageFlags = packed struct {
    Vertex: bool = false,
    Pixel: bool = false,
    Compute: bool = false,
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

    pub inline fn full_screen_viewport() Viewport {
        return full_screen_viewport_mip(0);
    }

    pub inline fn full_screen_viewport_mip(mip_level: usize) Viewport {
        const size = GfxState.get().swapchain_size();
        return Viewport {
            .width = @floatFromInt(@max(size[0] >> @intCast(mip_level), 1)),
            .height = @floatFromInt(@max(size[1] >> @intCast(mip_level), 1)),
        };
    }
};

pub const VertexInputLayoutFormat = enum {
    F32x1,
    F32x2,
    F32x3,
    F32x4,
    I32x4,
    U8x4,
};

pub const VertexInputLayoutInputRate = enum {
    Vertex,
    Instance,
};

pub const VertexInputBinding = struct {
    binding: u32,
    stride: u32,
    input_rate: VertexInputLayoutInputRate,
};

pub const VertexInputAttribute = struct {
    name: []const u8,
    location: u32,
    binding: u32,
    offset: u32,
    format: VertexInputLayoutFormat,
};

pub const ShaderModuleInfo = struct {
    spirv_data: []const u8,
};

pub const ShaderModule = struct {
    platform: pl.GfxPlatform.ShaderModule,

    pub fn deinit(self: *const ShaderModule) void {
        self.platform.deinit();
    }

    pub fn init(info: ShaderModuleInfo) !ShaderModule {
        const platform = pl.GfxPlatform.ShaderModule.init(info) catch |err| {
            std.log.err("Failed to initialise shader module: {}", .{err});
            return err;
        };
        return ShaderModule {
            .platform = platform,
        };
    }
};

pub const Shader = struct {
    module: *const ShaderModule,
    entry_point: [:0]const u8,
};

pub const VertexInputInfo = struct {
    bindings: []const VertexInputBinding,
    attributes: []const VertexInputAttribute,
};

pub const VertexInput = struct {
    platform: pl.GfxPlatform.VertexInput,

    pub fn deinit(self: *const VertexInput) void {
        self.platform.deinit();
    }

    pub fn init(info: VertexInputInfo) !VertexInput {
        const platform = pl.GfxPlatform.VertexInput.init(info) catch |err| {
            std.log.err("Failed to initialise vertex input: {}", .{err});
            return err;
        };
        return VertexInput {
            .platform = platform,
        };
    }
};

pub fn Reference(comptime T: type) type {
    return struct {
        const Self = @This();

        id: gen.GenerationalIndex,

        pub fn deinit(self: *const Self) void {
            if (self.get()) |asset| {
                asset.deinit();
            } else |_| {
                std.log.warn("Unable to retrieve {s} asset", .{@typeName(T)});
            }
            gfxstate_list().remove(self.id) catch |err| {
                std.log.warn("Unable to remove {s} asset: {}", .{@typeName(T), err});
            };
        }

        pub fn get(self: *const Self) !*T {
            return gfxstate_list().get(self.id) orelse return error.UnableToRetrieveAsset;
        }

        pub fn init_from_index(idx: usize) !Self {
            const list = Self.gfxstate_list();
            if (list.data.items.len < idx) {
                return error.IndexOutOfBounds;
            }
            return Self {
                .id = .{
                    .index = idx,
                    .generation = list.data.items[idx].generation,
                },
            };
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.id.eql(other.id);
        }

        fn gfxstate_list() *gen.GenerationalList(T) {
            return switch (T) {
                Buffer => &GfxState.get().buffers,
                Image => &GfxState.get().images,
                ImageView => &GfxState.get().image_views,
                Sampler => &GfxState.get().samplers,
                RenderPass => &GfxState.get().render_passes,
                GraphicsPipeline => &GfxState.get().graphics_pipelines,
                ComputePipeline => &GfxState.get().compute_pipelines,
                FrameBuffer => &GfxState.get().framebuffers,
                DescriptorLayout => &GfxState.get().descriptor_layouts,
                DescriptorPool => &GfxState.get().descriptor_pools,
                DescriptorSet => &GfxState.get().descriptor_sets,
                CommandPool => &GfxState.get().command_pools,
                else => @compileError("Unsupported gfx reference type"),
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
        pub const WriteOptions = enum {
            NoWrite,
            Infrequent,
            EveryFrame,
        };
        read: bool = false,
        write: WriteOptions = .NoWrite,
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

pub const ImageLayout = enum {
    Undefined,
    General,
    ColorAttachmentOptimal,
    DepthStencilAttachmentOptimal,
    DepthStencilReadOnlyOptimal,
    ShaderReadOnlyOptimal,
    TransferSrcOptimal,
    TransferDstOptimal,
    Preinitialized,
    PresentSrc,
};

pub const ImageInfo = struct {
    format: ImageFormat,

    match_swapchain_extent: bool = false,
    width: u32 = 1,
    height: u32 = 1,
    depth: u32 = 1,
    mip_levels: u32 = 1,
    array_length: u32 = 1,
    dst_layout: ImageLayout,

    usage_flags: ImageUsageFlags,
    access_flags: AccessFlags,
};

pub const Image = struct {
    pub const Ref = Reference(Image);

    info: ImageInfo,
    platform: GfxState.Platform.Image,

    pub fn deinit(self: *Image) void {
        self.platform.deinit();
    }

    pub fn init(info: ImageInfo, data: ?[]const u8) !Image.Ref {
        const image = try Image.init_standalone(info, data);
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

    pub fn init_standalone(info: ImageInfo, data: ?[]const u8) !Image {
        var modified_info = info;
        if (modified_info.match_swapchain_extent) {
            modified_info.width = GfxState.get().swapchain_size()[0];
            modified_info.height = GfxState.get().swapchain_size()[1];
        }

        const platform = try GfxState.Platform.Image.init(modified_info, data);
        errdefer platform.deinit();

        return Image {
            .platform = platform,
            .info = modified_info,
        };
    }

    pub fn reinit(self: *Image, image_ref: Image.Ref) !void {
        // copy old image
        var old_image = self.*;

        // create and set new image
        self.* = try Image.init_standalone(self.info, null);

        // reinitialise all image views that refer to old image
        for (GfxState.get().image_views.data.items) |*maybe_image_view| {
            if (maybe_image_view.item_data) |*image_view| {
                if (image_view.info.image.eql(image_ref)) {
                    image_view.deinit();
                    image_view.* = try ImageView.init_standalone(image_view.info);
                }
            }
        }

        // finally deinit old image
        old_image.deinit();
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

pub const ImageViewType = enum {
    ImageView1D,
    ImageView2D,
    ImageView2DArray,
};

pub const ImageViewInfo = struct {
    image: Image.Ref,
    view_type: ImageViewType,
    mip_levels: ?struct {
        base_mip_level: u32 = 0,
        mip_level_count: u32,
    } = null,
    array_layers: ?struct {
        base_array_layer: u32 = 0,
        array_layer_count: u32,
    } = null,
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
        const view = try ImageView.init_standalone(info);

        const view_ref = ImageView.Ref {
            .id = try GfxState.get().image_views.insert(view),
        };
        errdefer GfxState.get().image_views.remove(view_ref.id) catch {};

        return view_ref;
    }
    
    pub fn init_standalone(info: ImageViewInfo) !ImageView {
        const image = try info.image.get();

        var adjusted_info = info;
        if (adjusted_info.array_layers == null) {
            adjusted_info.array_layers = .{
                .base_array_layer = 0,
                .array_layer_count = image.info.array_length,
            };
        }
        if (adjusted_info.mip_levels == null) {
            adjusted_info.mip_levels = .{
                .base_mip_level = 0,
                .mip_level_count = image.info.mip_levels,
            };
        }

        const platform = try GfxState.Platform.ImageView.init(adjusted_info);
        errdefer platform.deinit();

        return ImageView {
            .platform = platform,
            .info = adjusted_info,
            .size = .{
                .width = @divFloor(image.info.width, std.math.pow(u32, 2, adjusted_info.mip_levels.?.base_mip_level)),
                .height = @divFloor(image.info.height, std.math.pow(u32, 2, adjusted_info.mip_levels.?.base_mip_level)),
            },
        };
    }
};

pub const ImageFormat = enum {
    Unknown,
    Rgba8_Unorm_Srgb,
    Rgba8_Unorm,
    Bgra8_Unorm,
    Bgra8_Srgb,
    R32_Float,
    R32_Uint,
    Rg32_Float,
    Rgba16_Float,
    Rgba32_Float,
    Rg11b10_Float,

    R24X8_Unorm_Uint,

    D16S8_Unorm_Uint,
    D24S8_Unorm_Uint,
    D32S8_Sfloat_Uint,

    pub fn byte_width(self: ImageFormat) usize {
        switch (self) {
            .Unknown => return 0,
            .R32_Float => return 4,
            .R32_Uint => return 4,
            .Rg32_Float => return 8,
            .Rgba8_Unorm_Srgb => return 4,
            .Rgba8_Unorm => return 4,
            .Bgra8_Unorm => return 4,
            .Bgra8_Srgb => return 4,
            .Rgba16_Float => return 8,
            .Rgba32_Float => return 16,
            .Rg11b10_Float => return 3,
            .R24X8_Unorm_Uint => return 4,
            .D24S8_Unorm_Uint => return 4,
            .D16S8_Unorm_Uint => return 3,
            .D32S8_Sfloat_Uint => return 5,
        }
    }

    pub fn is_depth(self: ImageFormat) bool {
        switch (self) {
            .D16S8_Unorm_Uint,
            .D32S8_Sfloat_Uint,
            .D24S8_Unorm_Uint => return true,
            else => return false,
        }
    }
};

pub const BufferUsageFlags = packed struct {
    VertexBuffer: bool = false,
    IndexBuffer: bool = false,
    ConstantBuffer: bool = false,
    StorageBuffer: bool = false,
    TransferSrc: bool = false,
    TransferDst: bool = false,
};

pub const ImageUsageFlags = packed struct {
    RenderTarget: bool = false,
    DepthStencil: bool = false,
    ShaderResource: bool = false,
    StorageResource: bool = false,
    TransferSrc: bool = false,
    TransferDst: bool = false,
};

pub const AccessFlags = packed struct {
    GpuWrite: bool = false,
    CpuRead: bool = false,
    CpuWrite: bool = false,
};

pub const RasterizationStateDesc = packed struct {
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

    initial_layout: ImageLayout,
    final_layout: ImageLayout,

    clear_value: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
};

pub const SubpassInfo = struct {
    attachments: []const []const u8,
    depth_attachment: ?[]const u8 = null,
};

pub const PipelineStageFlags = packed struct {
    top_of_pipe: bool = false,
    draw_indirect: bool = false,
    vertex_input: bool = false,
    vertex_shader: bool = false,
    tessellation_control_shader: bool = false,
    tessellation_evaluation_shader: bool = false,
    geometry_shader: bool = false,
    fragment_shader: bool = false,
    early_fragment_tests: bool = false,
    late_fragment_tests: bool = false,
    color_attachment_output: bool = false,
    compute_shader: bool = false,
    transfer: bool = false,
    bottom_of_pipe: bool = false,
    host: bool = false,
    all_graphics: bool = false,
    all_commands: bool = false,
};

pub const AccessMaskFlags = packed struct {
    indirect_command_read: bool = false,
    index_read: bool = false,
    vertex_attribute_read: bool = false,
    uniform_read: bool = false,
    input_attachment_read: bool = false,
    shader_read: bool = false,
    shader_write: bool = false,
    color_attachment_read: bool = false,
    color_attachment_write: bool = false,
    depth_stencil_attachment_read: bool = false,
    depth_stencil_attachment_write: bool = false,
    transfer_read: bool = false,
    transfer_write: bool = false,
    host_read: bool = false,
    host_write: bool = false,
    memory_read: bool = false,
    memory_write: bool = false,
};

pub const SubpassDependencyInfo = struct {
    src_subpass: ?u32,
    dst_subpass: u32,

    src_stage_mask: PipelineStageFlags,
    src_access_mask: AccessMaskFlags,

    dst_stage_mask: PipelineStageFlags,
    dst_access_mask: AccessMaskFlags,
};

pub const RenderPassInfo = struct {
    attachments: []const AttachmentInfo,
    subpasses: []const SubpassInfo,
    dependencies: []const SubpassDependencyInfo,
};

pub const RenderPass = struct {
    const Self = @This();
    pub const Ref = Reference(Self);

    platform: GfxState.Platform.RenderPass,
    attachments_info: []AttachmentInfo,

    pub fn deinit(self: *const Self) void {
        self.platform.deinit();
        eng.get().general_allocator.free(self.attachments_info);
    }

    pub fn init(info: RenderPassInfo) !RenderPass.Ref {
        const platform = try pl.GfxPlatform.RenderPass.init(info);
        errdefer platform.deinit();

        const owned_attachments = try eng.get().general_allocator.dupe(AttachmentInfo, info.attachments);
        errdefer eng.get().general_allocator.free(owned_attachments);

        const render_pass = RenderPass {
            .platform = platform,
            .attachments_info = owned_attachments,
        };

        return Self.Ref {
            .id = try GfxState.get().render_passes.insert(render_pass),
        };
    }
};

pub const PushConstantLayoutInfo = struct {
    shader_stages: ShaderStageFlags,
    offset: u32,
    size: u32,
};

pub const GraphicsPipelineInfo = struct {
    vertex_shader: Shader,
    pixel_shader: Shader,

    vertex_input: *const VertexInput,

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

    render_pass: RenderPass.Ref,
    subpass_index: u32 = 0,

    descriptor_set_layouts: []const DescriptorLayout.Ref = &.{},
    push_constants: []const PushConstantLayoutInfo = &.{},
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

pub const ComputePipelineInfo = struct {
    compute_shader: Shader,

    descriptor_set_layouts: []const DescriptorLayout.Ref = &.{},
    push_constants: []const PushConstantLayoutInfo = &.{},
};

pub const ComputePipeline = struct {
    pub const Ref = Reference(ComputePipeline);

    platform: GfxState.Platform.ComputePipeline,
    info: ComputePipelineInfo,

    pub fn deinit(self: *const ComputePipeline) void {
        self.platform.deinit();
    }
    
    pub fn init(info: ComputePipelineInfo) !ComputePipeline.Ref {
        const platform = try pl.GfxPlatform.ComputePipeline.init(info);
        errdefer platform.deinit();

        const compute_pipeline = ComputePipeline {
            .platform = platform,
            .info = info,
        };

        return ComputePipeline.Ref {
            .id = try GfxState.get().compute_pipelines.insert(compute_pipeline),
        };
    }
};

pub const FrameBufferAttachmentInfo = union(enum) {
    View: ImageView.Ref,
    SwapchainHDR: void,
    SwapchainLDR: void,
    SwapchainDepth: void,
};

pub const FrameBufferInfo = struct {
    render_pass: RenderPass.Ref,
    attachments: []const FrameBufferAttachmentInfo,
};

pub const FrameBuffer = struct {
    pub const Ref = Reference(FrameBuffer);

    platform: GfxState.Platform.FrameBuffer,
    info: FrameBufferInfo,

    pub fn deinit(self: *const FrameBuffer) void {
        self.platform.deinit();
        eng.get().general_allocator.free(self.info.attachments);
    }

    pub fn init(info: FrameBufferInfo) !FrameBuffer.Ref {
        const framebuffer = try FrameBuffer.init_standalone(info);

        return FrameBuffer.Ref {
            .id = try GfxState.get().framebuffers.insert(framebuffer),
        };
    }

    pub fn init_standalone(info: FrameBufferInfo) !FrameBuffer {
        const platform = try pl.GfxPlatform.FrameBuffer.init(info);
        errdefer platform.deinit();

        var owned_info = info;
        owned_info.attachments = try eng.get().general_allocator.dupe(FrameBufferAttachmentInfo, info.attachments);
        errdefer eng.get().general_allocator.free(owned_info.attachments);

        return FrameBuffer {
            .platform = platform,
            .info = owned_info,
        };
    }

    pub fn reinit(self: *FrameBuffer) !void {
        const new_framebuffer = try FrameBuffer.init_standalone(self.info);
        self.deinit();
        self.* = new_framebuffer;
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

    pub fn allocate_set(
        self: *const DescriptorPool,
        info: DescriptorSetInfo,
    ) !DescriptorSet.Ref {
        const alloc = eng.get().frame_allocator;

        const sets = try self.allocate_sets(alloc, info, 1);
        defer alloc.free(sets);

        return sets[0];
    }

    pub fn allocate_sets(
        self: *const DescriptorPool,
        alloc: std.mem.Allocator,
        info: DescriptorSetInfo,
        number_of_sets: u32
    ) ![]DescriptorSet.Ref {
        const set_refs = try alloc.alloc(DescriptorSet.Ref, number_of_sets);
        errdefer alloc.free(set_refs);

        // TODO track resources
        const sets = try self.platform.allocate_sets(alloc, info, number_of_sets);
        defer alloc.free(sets);
        errdefer { for (sets) |*s| { s.deinit(); } }

        for (sets, 0..) |set, idx| {
            set_refs[idx] = .{
                .id = try GfxState.get().descriptor_sets.insert(set),
            };
        }

        return set_refs;
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

pub const ImageViewAndSampler = struct {
    view: ImageView.Ref,
    sampler: Sampler.Ref,
};

pub const DescriptorSetUpdateWriteInfo = struct {
    binding: u32,
    array_element: u32 = 0,
    data: union(enum) {
        UniformBuffer: DescriptorSetWriteBufferInfo,
        StorageBuffer: DescriptorSetWriteBufferInfo,
        ImageView: ImageView.Ref,
        Sampler: Sampler.Ref,
        ImageViewAndSampler: struct{ view: ImageView.Ref, sampler: Sampler.Ref, },

        UniformBufferArray: []const DescriptorSetWriteBufferInfo,
        StorageBufferArray: []const DescriptorSetWriteBufferInfo,
        ImageViewArray: []const ImageView.Ref,
        SamplerArray: []const Sampler.Ref,
        ImageViewAndSamplerArray: []const ImageViewAndSampler,
    },
};

pub const DescriptorSetUpdateInfo = struct {
    writes: []const DescriptorSetUpdateWriteInfo,
};

pub const DescriptorSet = struct {
    pub const Ref = Reference(DescriptorSet);

    platform: GfxState.Platform.DescriptorSet,

    pub fn deinit(self: *DescriptorSet) void {
        self.platform.deinit();
    }

    pub fn update(self: *DescriptorSet, info: DescriptorSetUpdateInfo) !void {
        try self.platform.update(info);
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
        return (try self.allocate_command_buffers(info, 1))[0];
    }

    pub fn allocate_command_buffers(self: *Self, info: CommandBufferInfo, comptime count: usize) ![count]CommandBuffer {
        const platform = try self.platform.allocate_command_buffers(info, count);

        var buffers: [count]CommandBuffer = undefined;
        inline for (platform, 0..) |b, idx| {
            buffers[idx] = CommandBuffer {
                .platform = b,
            };
        }
        return buffers;
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

    pub fn reset(self: *Self) !void {
        try self.platform.reset();
    }

    pub const BeginInfo = packed struct {
        one_time_submit: bool = false,
        render_pass_continue: bool = false,
        simultaneous_use: bool = false,
    };

    pub fn cmd_begin(self: *Self, info: BeginInfo) !void {
        try self.platform.cmd_begin(info);
    }

    pub fn cmd_end(self: *Self) !void {
        try self.platform.cmd_end();
    }

    pub const SubpassContents = enum {
        Inline,
        SecondaryCommandBuffers,
    };

    pub const BeginRenderPassInfo = struct {
        render_pass: RenderPass.Ref,
        framebuffer: FrameBuffer.Ref,
        render_area: Rect,
        subpass_contents: SubpassContents = .Inline,
    };

    pub fn cmd_begin_render_pass(self: *Self, info: BeginRenderPassInfo) void {
        self.platform.cmd_begin_render_pass(info);
    }

    pub const NextSubpassInfo = struct {
        subpass_contents: SubpassContents = .Inline,
    };

    pub fn cmd_next_subpass(self: *Self, info: NextSubpassInfo) void {
        self.platform.cmd_next_subpass(info);
    }

    pub fn cmd_end_render_pass(self: *Self) void {
        self.platform.cmd_end_render_pass();
    }

    pub fn cmd_bind_graphics_pipeline(self: *Self, pipeline: GraphicsPipeline.Ref) void {
        self.platform.cmd_bind_graphics_pipeline(pipeline);
    }

    pub fn cmd_bind_compute_pipeline(self: *Self, pipeline: ComputePipeline.Ref) void {
        self.platform.cmd_bind_compute_pipeline(pipeline);
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
        self.platform.cmd_set_scissors(info);
    }

    pub const BindVertexBuffersInfo = struct {
        first_binding: u32 = 0,
        buffers: []const VertexBufferInput,
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
        first_binding: u32 = 0,
        descriptor_sets: []const DescriptorSet.Ref,
        dynamic_offsets: []const u32 = &.{},
    };

    pub fn cmd_bind_descriptor_sets(self: *Self, info: BindDescriptorSetInfo) void {
        self.platform.cmd_bind_descriptor_sets(info);
    }

    pub const PushConstantsInfo = struct {
        shader_stages: ShaderStageFlags,
        offset: u32,
        data: []const u8,
    };

    pub fn cmd_push_constants(self: *Self, info: PushConstantsInfo) void {
        self.platform.cmd_push_constants(info);
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

    pub const MemoryBarrierInfo = struct {
        src_access_mask: AccessMaskFlags,
        dst_access_mask: AccessMaskFlags,
    };

    pub const BufferMemoryBarrierInfo = struct {
        buffer: Buffer.Ref,
        offset: u64,
        size: u64,
        src_access_mask: AccessMaskFlags,
        dst_access_mask: AccessMaskFlags,
        src_queue: ?QueueFamily = null,
        dst_queue: ?QueueFamily = null,
    };

    pub const ImageMemoryBarrierInfo = struct {
        image: Image.Ref,
        subresource_range: struct {
            //aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            base_mip_level: u32 = 0,
            mip_level_count: u32 = std.math.maxInt(u32),
            base_array_layer: u32 = 0,
            array_layer_count: u32 = std.math.maxInt(u32),
        } = .{},
        src_access_mask: AccessMaskFlags,
        dst_access_mask: AccessMaskFlags,
        old_layout: ?ImageLayout = null,
        new_layout: ?ImageLayout = null,
        src_queue: ?QueueFamily = null,
        dst_queue: ?QueueFamily = null,
    };

    pub const PipelineBarrierInfo = struct {
        src_stage: PipelineStageFlags,
        dst_stage: PipelineStageFlags,
        memory_barriers: []const MemoryBarrierInfo = &.{},
        buffer_barriers: []const BufferMemoryBarrierInfo = &.{},
        image_barriers: []const ImageMemoryBarrierInfo = &.{},
    };

    pub fn cmd_pipeline_barrier(self: *Self, info: PipelineBarrierInfo) void {
        self.platform.cmd_pipeline_barrier(info);
    }

    pub const CopyImageToBufferInfo = struct {
        image: Image.Ref,
        buffer: Buffer.Ref,
        copy_regions: []const CopyRegionInfo,
    };

    pub fn cmd_copy_image_to_buffer(self: *Self, info: CopyImageToBufferInfo) void {
        self.platform.cmd_copy_image_to_buffer(info);
    }

    pub const CopyRegionInfo = struct {
        buffer_offset: u64 = 0,
        buffer_row_length: u32 = 0,
        buffer_image_height: u32 = 0,

        mip_level: u32 = 0,
        base_array_layer: u32 = 0,
        layer_count: u32 = 1,

        image_offset: [3]i32 = .{ 0, 0, 0 },
        image_extent: [3]u32,
    };

    pub const CopyBufferToImageInfo = struct {
        buffer: Buffer.Ref,
        image: Image.Ref,
        copy_regions: []const CopyRegionInfo,
    };

    pub fn cmd_copy_buffer_to_image(self: *Self, info: CopyBufferToImageInfo) void {
        self.platform.cmd_copy_buffer_to_image(info);
    }

    pub const DispatchInfo = struct {
        group_count_x: u32 = 1,
        group_count_y: u32 = 1,
        group_count_z: u32 = 1,
    };

    pub fn cmd_dispatch(self: *Self, info: DispatchInfo) void {
        self.platform.cmd_dispatch(info);
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
        return Semaphore {
            .platform = try GfxState.Platform.Semaphore.init(info),
        };
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
        return Self {
            .platform = try GfxState.Platform.Fence.init(info),
        };
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
