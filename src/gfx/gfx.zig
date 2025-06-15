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
const RectPixels = eng.Rect;

pub const GfxState = struct {
    const Self = @This();
    const Platform = pl.GfxPlatform;

    pub const FULL_SCREEN_QUAD_VS = @embedFile("full_screen_quad_vs.hlsl");

    platform: Platform,

    images: gen.GenerationalList(Image),
    image_views: gen.GenerationalList(ImageView),
    samplers: gen.GenerationalList(Sampler),
    graphics_pipelines: gen.GenerationalList(GraphicsPipeline),
    framebuffers: gen.GenerationalList(FrameBuffer),

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

        self.platform.deinit();

        self.images.deinit();
        self.image_views.deinit();
        self.samplers.deinit();
        self.graphics_pipelines.deinit();
        self.framebuffers.deinit();

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
    }

    pub fn init(alloc: std.mem.Allocator, window: *pl.Window) !Self {
        var gfx_platform = try pl.GfxPlatform.init(alloc, window);
        errdefer gfx_platform.deinit();
        
        var gfx_state = Self {
            .platform = gfx_platform,

            .images = gen.GenerationalList(Image).init(alloc),
            .image_views = gen.GenerationalList(ImageView).init(alloc),
            .samplers = gen.GenerationalList(Sampler).init(alloc),
            .graphics_pipelines = gen.GenerationalList(GraphicsPipeline).init(alloc),
            .framebuffers = gen.GenerationalList(FrameBuffer).init(alloc),

            .tone_mapping_filter = undefined,

            .default = .{
                .depth_image = undefined,
                .depth_view = undefined,
                .sampler = undefined,
                .diffuse = undefined,
                .diffuse_view = undefined,
                .normals = undefined,
                .normals_view = undefined,
                .metallic_roughness = undefined,
                .metallic_roughness_view = undefined,
                .ambient_occlusion = undefined,
                .ambient_occlusion_view = undefined,
                .emission = undefined,
                .emission_view = undefined,
            },
        };

        gfx_state.tone_mapping_filter = try ToneMappingAndBloomFilter.init();
        errdefer gfx_state.tone_mapping_filter.deinit();

        gfx_state.default.depth_image = try Image.init(.{
            .format = Self.depth_format,
            .match_swapchain_extent = true,

            .usage_flags = .{ .DepthStencil = true, },
            .access_flags = .{ .GpuWrite = true, },
        }, null);
        errdefer gfx_state.default.depth_image.deinit();

        gfx_state.default.depth_view = try ImageView.init(.{ .image = gfx_state.default.depth_image, });
        errdefer gfx_state.default.depth_view.deinit();

        gfx_state.default.sampler = try Sampler.init(.{});
        errdefer gfx_state.default.sampler.deinit();

        gfx_state.default.diffuse = try init_single_pixel_texture(zm.f32x4s(1.0));
        errdefer gfx_state.default.diffuse.deinit();

        gfx_state.default.diffuse_view = try ImageView.init(.{ .image = gfx_state.default.diffuse, });
        errdefer gfx_state.default.diffuse_view.deinit();

        gfx_state.default.normals = try init_single_pixel_texture(zm.f32x4(0.5, 0.5, 1.0, 1.0));
        errdefer gfx_state.default.normals.deinit();

        gfx_state.default.normals_view = try ImageView.init(.{ .image = gfx_state.default.normals, });
        errdefer gfx_state.default.normals_view.deinit();

        gfx_state.default.metallic_roughness = try init_single_pixel_texture(zm.f32x4(0.0, 1.0, 1.0, 1.0));
        errdefer gfx_state.default.metallic_roughness.deinit();

        gfx_state.default.metallic_roughness_view = try ImageView.init(.{ .image = gfx_state.default.metallic_roughness, });
        errdefer gfx_state.default.metallic_roughness_view.deinit();
        
        gfx_state.default.ambient_occlusion = try init_single_pixel_texture(zm.f32x4s(1.0));
        errdefer gfx_state.default.ambient_occlusion.deinit();

        gfx_state.default.ambient_occlusion_view = try ImageView.init(.{ .image = gfx_state.default.ambient_occlusion, });
        errdefer gfx_state.default.ambient_occlusion_view.deinit();

        gfx_state.default.emission = try init_single_pixel_texture(zm.f32x4(0.0, 0.0, 0.0, 1.0));
        errdefer gfx_state.default.emission.deinit();

        gfx_state.default.emission_view = try ImageView.init(.{ .image = gfx_state.default.emission, });
        errdefer gfx_state.default.emission_view.deinit();

        return gfx_state;
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

    pub fn get_frame_rtv(self: *Self) ImageView.Ref {
        _ = self;
        unreachable;
    }

    pub fn get_frame_hdr_view(self: *Self) ImageView.Ref {
        _ = self;
        unreachable;
    }

    pub fn get_framebuffer(self: *Self) ImageView.Ref {
        _ = self;
        unreachable;
    }

    pub fn present(self: *Self) !void {
        if (self.swapchain_size()[0] * self.swapchain_size()[1] == 0) {
            return error.SwapchainSizeIsZero;
        }
        try self.platform.present();
    }

    pub fn flush(self: *Self) void {
        self.platform.flush();
    }

    pub fn clear_state(self: *Self) void {
        self.platform.clear_state();
    }

    pub fn window_resized(self: *Self, new_width: i32, new_height: i32) void {
        const w = @max(new_width, 1);
        const h = @max(new_height, 1);

        self.clear_state();
        self.flush();

        self.platform.resize_swapchain(w, h);
    }

    pub fn received_window_event(self: *Self, event: *const wb.WindowEvent) void {
        switch (event.*) {
            .RESIZED => |new_size| { 
                self.window_resized(new_size.width, new_size.height);

                // send resize event to children
                self.tone_mapping_filter.framebuffer_resized(self) catch unreachable;
            },
            else => {},
        }
    }

    pub fn cmd_clear_render_target(self: *Self, rt: ImageView.Ref, color: zm.F32x4) void {
        self.platform.cmd_clear_render_target(rt, color);
    }

    pub fn cmd_clear_depth_stencil_view(self: *Self, dsv: ImageView.Ref, depth: ?f32, stencil: ?u8) void {
        self.platform.cmd_clear_depth_stencil_view(dsv, depth, stencil);
    }

    pub fn cmd_set_viewport(self: *Self, viewport: Viewport) void {
        self.platform.cmd_set_viewport(viewport);
    }

    pub fn cmd_set_scissor_rect(self: *Self, scissor: ?RectPixels) void {
        self.platform.cmd_set_scissor_rect(scissor);
    }

    pub fn cmd_set_render_target(self: *Self, rtvs: []const ?ImageView.Ref, depth_stencil_view: ?ImageView.Ref) void {
        self.platform.cmd_set_render_target(rtvs, depth_stencil_view);
    }

    pub fn cmd_set_vertex_shader(self: *Self, vs: *const VertexShader) void {
        self.platform.cmd_set_vertex_shader(vs);
    }

    pub fn cmd_set_pixel_shader(self: *Self, ps: *const PixelShader) void {
        self.platform.cmd_set_pixel_shader(ps);
    }

    pub fn cmd_set_hull_shader(self: *Self, hs: ?*const HullShader) void {
        self.platform.cmd_set_hull_shader(hs);
    }

    pub fn cmd_set_domain_shader(self: *Self, ds: ?*const DomainShader) void {
        self.platform.cmd_set_domain_shader(ds);
    }

    pub fn cmd_set_geometry_shader(self: *Self, gs: ?*const GeometryShader) void {
        self.platform.cmd_set_geometry_shader(gs);
    }

    pub fn cmd_set_compute_shader(self: *Self, cs: ?*const ComputeShader) void {
        self.platform.cmd_set_compute_shader(cs);
    }

    pub fn cmd_set_vertex_buffers(self: *Self, start_slot: u32, buffers: []const VertexBufferInput) void {
        self.platform.cmd_set_vertex_buffers(start_slot, buffers);
    }

    pub fn cmd_set_index_buffer(self: *Self, buffer: *const Buffer, format: IndexFormat, offset: u32) void {
        self.platform.cmd_set_index_buffer(buffer, format, offset);
    }

    pub fn cmd_set_constant_buffers(self: *Self, shader_stage: ShaderStage, start_slot: u32, buffers: []const *const Buffer) void {
        self.platform.cmd_set_constant_buffers(shader_stage, start_slot, buffers);
    }

    pub fn cmd_set_rasterizer_state(self: *Self, rs: RasterizationStateDesc) void {
        self.platform.cmd_set_rasterizer_state(rs);
    }

    pub fn cmd_set_shader_resources(self: *Self, shader_stage: ShaderStage, start_slot: u32, views: []const ?ImageView.Ref) void {
        self.platform.cmd_set_shader_resources(shader_stage, start_slot, views);
    }

    pub fn cmd_set_samplers(self: *Self, shader_stage: ShaderStage, start_slot: u32, sampler: []const Sampler.Ref) void {
        self.platform.cmd_set_samplers(shader_stage, start_slot, sampler);
    }

    pub fn cmd_draw(self: *Self, vertex_count: u32, start_vertex: u32) void {
        self.platform.cmd_draw(vertex_count, start_vertex);
    }

    pub fn cmd_draw_indexed(self: *Self, index_count: u32, start_index: u32, base_vertex: i32) void {
        self.platform.cmd_draw_indexed(index_count, start_index, base_vertex);
    }

    pub fn cmd_draw_instanced(self: *Self, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) void {
        self.platform.cmd_draw_instanced(vertex_count, instance_count, start_vertex, start_instance);
    }

    pub fn cmd_set_topology(self: *Self, topology: Topology) void {
        self.platform.cmd_set_topology(topology);
    }

    pub fn cmd_set_topology_patch_list_count(self: *Self, patch_list_count: u32) void {
        self.platform.cmd_set_topology_patch_list_count(patch_list_count);
    }

    pub fn cmd_set_unordered_access_views(self: *Self, shader_stage: ShaderStage, start_slot: u32, views: anytype) void {
        var uavs: [8]?*const pl.GfxPlatform.UnorderedAccessView = [_]?*const pl.GfxPlatform.UnorderedAccessView{null} ** 8;
        inline for (views, 0..) |v, i| {
            uavs[i] = if (@TypeOf(v) != @TypeOf(null)) v.unordered_access_view() else null;
        }
        self.platform.cmd_set_unordered_access_views(shader_stage, start_slot, &uavs);
    }

    pub fn cmd_dispatch_compute(self: *Self, num_groups_x: u32, num_groups_y: u32, num_groups_z: u32) void {
        self.platform.cmd_dispatch_compute(num_groups_x, num_groups_y, num_groups_z);
    }

    pub fn cmd_copy_texture_to_texture(self: *Self, dst_texture: Image.Ref, src_texture: Image.Ref) void {
        self.platform.cmd_copy_texture_to_texture(dst_texture, src_texture);
    }
};

pub const VertexBufferInput = struct {
    buffer: *const Buffer,
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
    top_left_x: f32,
    top_left_y: f32,
    min_depth: f32,
    max_depth: f32,
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

pub const Buffer = struct {
    platform: pl.GfxPlatform.Buffer,

    pub fn deinit(self: *const Buffer) void {
        self.platform.deinit();
    }

    pub fn init(
        byte_size: u32,
        usage_flags: BufferUsageFlags,
        access_flags: AccessFlags,
    ) !Buffer {
        return Buffer {
            .platform = try pl.GfxPlatform.Buffer.init(byte_size, usage_flags, access_flags),
        };
    }
    
    pub fn init_with_data(
        data: []const u8,
        usage_flags: BufferUsageFlags,
        access_flags: AccessFlags,
    ) !Buffer {
        return Buffer {
            .platform = try pl.GfxPlatform.Buffer.init_with_data(data, usage_flags, access_flags),
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

pub const ShaderResourceView = *const pl.GfxPlatform.ShaderResourceView;
pub const UnorderedAccessView = *const pl.GfxPlatform.UnorderedAccessView;

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
                Image => &GfxState.get().images,
                else => unreachable,
            };
        }
    };
}

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
        const platform = try GfxState.Platform.Image.init(info, data);
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

        const alloc = eng.get().frame_allocator;

        const data = try alloc.alloc(u8, info.width * info.height * info.depth * 4);
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

        return try Image.init(info, data);
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
        std.debug.assert(info.base_mip_level > 0);
        std.debug.assert(info.base_array_layer > 0);

        const platform = try GfxState.Platform.ImageView.init(info);
        errdefer platform.deinit();

        const image = try info.image.get();

        const image_view = ImageView {
            .platform = platform,
            .info = info,
            .size = .{
                .width = @divFloor(image.info.width, std.math.pow(u32, info.base_mip_level - 1, 2)),
                .height = @divFloor(image.info.height, std.math.pow(u32, info.base_mip_level - 1, 2)),
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

// pub const RenderTargetView = struct {
//     platform: pl.GfxPlatform.RenderTargetView,
//     size: struct { width: u32, height: u32, depth: u32, },
//
//     pub fn deinit(self: *const RenderTargetView) void {
//         self.platform.deinit();
//     }
//
//     pub fn init(image: Image.Ref) !RenderTargetView {
//         return init_mip(image, 0);
//     }
//
//     pub fn init_mip(image: Image.Ref, mip_level: u32) !RenderTargetView {
//         return RenderTargetView {
//             .platform = try pl.GfxPlatform.RenderTargetView.init(image, mip_level),
//             .size = .{
//                 .width = image.get().?.desc.width / std.math.pow(u32, 2, mip_level),
//                 .height = image.get().?.desc.height / std.math.pow(u32, 2, mip_level),
//                 .depth = 1,
//             },
//         };
//     }
// };
//
// pub const DepthStencilView = struct {
//     platform: pl.GfxPlatform.DepthStencilView,
//
//     pub const Flags = packed struct(u2) {
//         read_only_depth: bool = false,
//         read_only_stencil: bool = false,
//     };
//
//     pub fn deinit(self: *const DepthStencilView) void {
//         self.platform.deinit();
//     }
//
//     pub fn init(
//         image: Image.Ref,
//         flags: Flags,
//     ) !DepthStencilView {
//         if (!image.get().?.desc.format.is_depth()) { return error.NotADepthFormat; }
//
//         return DepthStencilView {
//             .platform = try pl.GfxPlatform.DepthStencilView.init(image, flags),
//         };
//     }
// };

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
};

pub const Sampler = struct {
    pub const Ref = Reference(Sampler);

    platform: GfxState.Platform.Sampler,
    desc: SamplerDescriptor,

    pub fn deinit(self: *const Sampler) void {
        self.platform.deinit();
    }

    pub fn init(desc: SamplerDescriptor) !Sampler.Ref {
        const platform = try pl.GfxPlatform.Sampler.init(desc);
        errdefer platform.deinit();

        const sampler = Sampler {
            .platform = platform,
            .desc = desc,
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
};

pub const SubpassInfo = struct {
    attachments: []const []const u8,
    depth_attachment: ?[]const u8 = null,
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
    subpasses: []const SubpassInfo,
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
    graphics_pipeline: GraphicsPipeline.Ref,
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
