const std = @import("std");
const builtin = @import("builtin");
const zm = @import("zmath");
const wb = @import("../window.zig");
const path = @import("../engine/path.zig");
const bloom = @import("bloom.zig");
const pl = @import("../platform/platform.zig");

inline fn is_dbg() bool {
    return (builtin.mode == std.builtin.Mode.Debug);
}

pub const GfxState = struct {
    const Self = @This();
    pub const FULL_SCREEN_QUAD_VS = @embedFile("full_screen_quad_vs.hlsl");

    platform: pl.GfxPlatform,

    framebuffer_rtv: RenderTargetView,
    hdr_rtv: RenderTargetView,
    hdr_texture: Texture2D,
    hdr_texture_view: TextureView2D,

    swapchain_size: struct{width: i32, height: i32},

    rasterization_states_array: [8]?RasterizationState = [_]?RasterizationState{null} ** 8,

    tone_mapping_filter: ToneMappingAndBloomFilter,

    default: struct {
        sampler: Sampler,
        diffuse: TextureView2D,
        normals: TextureView2D,
        metallic_roughness: TextureView2D,
        ambient_occlusion: TextureView2D,
        emission: TextureView2D,

        vertex_shader: *const VertexShader = undefined,
        pixel_shader: *const PixelShader = undefined,
        constant_buffers: std.BoundedArray(ConstantBufferItem, 8) = undefined,
    },

    // @TODO: add rasterization state map, blend state map, and sampler map so we can just use them at 
    // draw time instead of creating new objects each time at init. Be aggressive for JIT (Just in Time) gfx object creation

    const enable_debug_layers = true;
    const swapchain_buffer_count: u32 = 3;
    pub const hdr_format = TextureFormat.Rgba16_Float;
    pub const ldr_format = TextureFormat.Rgba8_Unorm;

    pub fn deinit(self: *Self) void {
        std.log.debug("D3D11 deinit", .{});

        for (self.rasterization_states_array) |r| {
            if (r) |*rs| {
                rs.deinit();
            }
        }

        self.default.sampler.deinit();
        self.default.diffuse.deinit();
        self.default.normals.deinit();
        self.default.metallic_roughness.deinit();
        self.default.ambient_occlusion.deinit();
        self.default.emission.deinit();

        self.tone_mapping_filter.deinit();

        self.hdr_rtv.deinit();
        self.hdr_texture_view.deinit();
        self.hdr_texture.deinit();

        self.framebuffer_rtv.deinit();

        self.platform.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, window: *pl.Window) !Self {
        var gfx_platform = try pl.GfxPlatform.init(alloc, window);
        errdefer gfx_platform.deinit();
        
        const window_size = try window.get_client_size();

        var gfx_state = Self {
            .platform = gfx_platform,
            .swapchain_size = .{
                .width = @intCast(window_size.width), 
                .height = @intCast(window_size.height)
            },
            .framebuffer_rtv = undefined,
            .hdr_rtv = undefined,
            .hdr_texture = undefined,
            .hdr_texture_view = undefined,
            .tone_mapping_filter = undefined,
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

        gfx_state.hdr_texture = try gfx_state.create_hdr_rtv_texture2d_from_framebuffer();
        errdefer gfx_state.hdr_texture.deinit();

        gfx_state.hdr_rtv = try RenderTargetView.init_from_texture2d(&gfx_state.hdr_texture, &gfx_state);
        errdefer gfx_state.hdr_rtv.deinit();

        gfx_state.hdr_texture_view = try TextureView2D.init_from_texture2d(&gfx_state.hdr_texture, &gfx_state);
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

    fn create_texture2d_from_framebuffer(self: *Self) !Texture2D {
        return try self.platform.create_texture2d_from_framebuffer(self);
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
        if (self.swapchain_size.width * self.swapchain_size.height == 0) {
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

    pub fn swapchain_aspect(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.swapchain_size.width)) / @as(f32, @floatFromInt(self.swapchain_size.height));
    }

    fn get_rasterization_state(self: *Self, desc: RasterizationStateDesc) RasterizationState {
        const index: usize = @intCast(@as(u3, @bitCast(desc)));
        if (self.rasterization_states_array[index]) |r| {
            return r;
        } else {
            const r = RasterizationState.init(desc, self) catch unreachable;
            self.rasterization_states_array[index] = r;
            return r;
        }
    }

    pub fn window_resized(self: *Self, new_width: i32, new_height: i32) void {
        const w = @max(new_width, 1);
        const h = @max(new_height, 1);

        self.clear_state();
        self.flush();

        // Release help render target view before we update the swapchain.
        // If we dont do this swapchain resize buffers will fail.
        self.hdr_rtv.deinit();
        self.hdr_texture_view.deinit();
        self.hdr_texture.deinit();
        self.framebuffer_rtv.deinit();

        self.platform.resize_swapchain(w, h);

        // Update swapchain size variables
        self.swapchain_size.width = w;
        self.swapchain_size.height = h;

        // Reacquire render target view from new swapchain
        var framebuffer_texture = self.create_texture2d_from_framebuffer() catch unreachable;
        defer framebuffer_texture.deinit();

        self.framebuffer_rtv = RenderTargetView.init_from_texture2d(&framebuffer_texture, self)
            catch unreachable;

        self.hdr_texture = self.create_hdr_rtv_texture2d_from_framebuffer() catch unreachable;
        errdefer self.hdr_texture.deinit();

        self.hdr_rtv = RenderTargetView.init_from_texture2d(&self.hdr_texture, self)
            catch unreachable;

        self.hdr_texture_view = TextureView2D.init_from_texture2d(&self.hdr_texture, self)
            catch unreachable;
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

    pub fn cmd_clear_render_target(self: *Self, rt: *const RenderTargetView, color: zm.F32x4) void {
        self.platform.cmd_clear_render_target(rt, color);
    }

    pub fn cmd_clear_depth_stencil_view(self: *Self, dsv: *const DepthStencilView, depth: ?f32, stencil: ?u8) void {
        self.platform.cmd_clear_depth_stencil_view(dsv, depth, stencil);
    }

    pub fn cmd_set_viewport(self: *Self, viewport: Viewport) void {
        self.platform.cmd_set_viewport(viewport);
    }

    pub fn cmd_set_render_target(self: *Self, rtvs: []const ?*const RenderTargetView, depth_stencil_view: ?*const DepthStencilView) void {
        self.platform.cmd_set_render_target(rtvs, depth_stencil_view);
    }

    pub fn cmd_set_vertex_shader(self: *Self, vs: *const VertexShader) void {
        self.platform.cmd_set_vertex_shader(vs);
    }

    pub fn cmd_set_pixel_shader(self: *Self, ps: *const PixelShader) void {
        self.platform.cmd_set_pixel_shader(ps);
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

    pub fn cmd_set_index_buffer(self: *Self, buffer: *Buffer, format: IndexFormat, offset: u32) void {
        self.platform.cmd_set_index_buffer(buffer, format, offset);
    }

    pub fn cmd_set_constant_buffers(self: *Self, shader_stage: ShaderStage, start_slot: u32, buffers: []const *const Buffer) void {
        self.platform.cmd_set_constant_buffers(shader_stage, start_slot, buffers);
    }

    pub fn cmd_set_rasterizer_state(self: *Self, rs: RasterizationStateDesc) void {
        var rasterization_state = self.get_rasterization_state(rs);
        self.platform.cmd_set_rasterizer_state(&rasterization_state);
    }

    pub fn cmd_set_blend_state(self: *Self, blend_state: ?*const BlendState) void {
        self.platform.cmd_set_blend_state(blend_state);
    }

    pub fn cmd_set_shader_resources(self: *Self, shader_stage: ShaderStage, start_slot: u32, views: anytype) void {
        var srvs: [8]?*const pl.GfxPlatform.ShaderResourceView = [_]?*const pl.GfxPlatform.ShaderResourceView{null} ** 8;
        inline for (views, 0..) |v, i| {
            srvs[i] = if (@TypeOf(v) != @TypeOf(null)) v.shader_resource_view() else null;
        }
        self.platform.cmd_set_shader_resources(shader_stage, start_slot, &srvs);
    }

    pub fn cmd_set_samplers(self: *Self, shader_stage: ShaderStage, start_slot: u32, sampler: []const *const Sampler) void {
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

    pub fn cmd_dispatch_compute(self: *Self, num_groups_x: u32, num_groups_y: u32, num_groups_z: u32) void {
        self.platform.cmd_dispatch_compute(num_groups_x, num_groups_y, num_groups_z);
    }

    pub fn cmd_copy_texture_to_texture(self: *Self, dst_texture: *const Texture2D, src_texture: *const Texture2D) void {
        self.platform.cmd_copy_texture_to_texture(dst_texture, src_texture);
    }
};

pub const ConstantBufferItem = struct { 
    stages: ShaderStageFlags = .{}, 
    buffer: ?*const Buffer = null,
};

pub const ConstantBufferArray = std.BoundedArray(ConstantBufferItem, 4);

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
        gfx: *GfxState,
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

        return init_buffer(vs_buf, vs_func, vs_layout, modified_options, gfx);
    }

    pub fn init_buffer(
        vs_data: []const u8, 
        vs_func: []const u8, 
        vs_layout: []const VertexInputLayoutEntry,
        options: VertexShaderOptions,
        gfx: *GfxState,
    ) !VertexShader {
        const platform = pl.GfxPlatform.VertexShader.init_buffer(vs_data, vs_func, vs_layout, options, gfx) catch |err| {
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
        gfx: *GfxState,
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

        return init_buffer(ps_buf, ps_func, modified_options, gfx);
    }

    pub fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8,
        options: PixelShaderOptions,
        gfx: *GfxState,
    ) !PixelShader {
        const platform = pl.GfxPlatform.PixelShader.init_buffer(ps_data, ps_func, options, gfx) catch |err| {
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
        gfx: *GfxState,
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

        return init_buffer(buf, gs_func, modified_options, gfx);
    }

    pub fn init_buffer(
        gs_data: []const u8, 
        gs_func: []const u8,
        options: GeometryShaderOptions,
        gfx: *GfxState,
    ) !GeometryShader {
        const platform = pl.GfxPlatform.GeometryShader.init_buffer(gs_data, gs_func, options, gfx) catch |err| {
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
        gfx: *GfxState,
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

        return init_buffer(cs_buf, cs_func, modified_options, gfx);
    }

    pub fn init_buffer(
        cs_data: []const u8, 
        cs_func: []const u8, 
        options: ComputeShaderOptions,
        gfx: *GfxState,
    ) !ComputeShader {
        const platform = pl.GfxPlatform.ComputeShader.init_buffer(cs_data, cs_func, options, gfx) catch |err| {
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
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        gfx: *GfxState,
    ) !Buffer {
        return Buffer {
            .platform = try pl.GfxPlatform.Buffer.init(byte_size, bind_flags, access_flags, gfx),
        };
    }
    
    pub fn init_with_data(
        data: []const u8,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        gfx: *GfxState,
    ) !Buffer {
        return Buffer {
            .platform = try pl.GfxPlatform.Buffer.init_with_data(data, bind_flags, access_flags, gfx),
        };
    }

    pub fn map(self: *const Buffer, comptime OutType: type, gfx: *GfxState) !MappedBuffer(OutType) {
        return MappedBuffer(OutType) {
            .platform = self.platform.map(OutType, gfx) catch unreachable,
        };
    }

    pub fn MappedBuffer(comptime T: type) type {
        return struct {
            platform: pl.GfxPlatform.Buffer.MappedBuffer(T),

            pub fn unmap(self: *const MappedBuffer(T)) void {
                self.platform.unmap();
            }
            
            pub fn data(self: *const MappedBuffer(T)) *T {
                return self.platform.data();
            }

            pub fn data_array(self: *const MappedBuffer(T), length: usize) [*]align(1)T {
                return self.platform.data_array(length);
            }
        };
    }
};

pub const Texture2D = struct {
    platform: pl.GfxPlatform.Texture2D,
    desc: Descriptor,
    bind_flags: BindFlag,
    access_flags: AccessFlags,

    pub fn deinit(self: *const Texture2D) void {
        self.platform.deinit();
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

        return Texture2D {
            .platform = try pl.GfxPlatform.Texture2D.init(desc, bind_flags, access_flags, data, gfx),
            .desc = desc,
            .bind_flags = bind_flags,
            .access_flags = access_flags,
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

    pub fn map(self: *const Texture2D, comptime OutType: type, gfx: *GfxState) !MappedTexture(OutType) {
        return MappedTexture(OutType) {
            .platform = try self.platform.map_read(OutType, gfx),
        };
    }

    pub fn map_write_discard(self: *const Texture2D, comptime OutType: type, gfx: *GfxState) !MappedTexture(OutType) {
        return MappedTexture(OutType) {
            .platform = try self.platform.map_write_discard(OutType, gfx),
        };
    }

    pub fn MappedTexture(comptime T: type) type {
        return struct {
            platform: pl.GfxPlatform.Texture2D.MappedTexture(T),

            pub fn unmap(self: *const MappedTexture(T)) void {
                self.platform.unmap();
            }
            
            pub fn data(self: *const MappedTexture(T)) [*]align(1)T {
                return self.platform.data();
            }
        };
    }
};

pub const TextureView2D = struct {
    platform: pl.GfxPlatform.TextureView2D,
    desc: Texture2D.Descriptor,
    bind_flags: BindFlag,
    access_flags: AccessFlags,

    pub fn deinit(self: *const TextureView2D) void {
        self.platform.deinit();
    }

    pub fn init_from_texture2d(texture: *const Texture2D, gfx: *GfxState) !TextureView2D {
        return TextureView2D {
            .platform = try pl.GfxPlatform.TextureView2D.init_from_texture2d(texture, gfx),
            .desc = texture.desc,
            .bind_flags = texture.bind_flags,
            .access_flags = texture.access_flags,
        };
    }

    pub fn shader_resource_view(self: *const TextureView2D) *const pl.GfxPlatform.ShaderResourceView {
        std.debug.assert(self.bind_flags.ShaderResource);
        return self.platform.shader_resource_view();
    }

    pub fn unordered_access_view(self: *const TextureView2D) *const pl.GfxPlatform.UnorderedAccessView {
        std.debug.assert(self.bind_flags.UnorderedAccess);
        return self.platform.unordered_access_view();
    }
};

pub const Texture3D = struct {
    platform: pl.GfxPlatform.Texture3D,
    desc: Descriptor,
    bind_flags: BindFlag,
    access_flags: AccessFlags,

    pub fn deinit(self: *const Texture3D) void {
        self.platform.deinit();
    }

    pub fn init(
        desc: Descriptor,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        data: ?[]const u8,
        gfx: *GfxState
    ) !Texture3D {
        if (data) |d| {
            if (d.len < (desc.width * desc.height * desc.depth * desc.format.byte_width())) {
                return error.NotEnoughDataToFillTexture;
            }
        } else {
            if (!access_flags.CpuWrite and !access_flags.GpuWrite) { 
                return error.DataNotSuppliedToImmutableTexture; 
            }
        }

        return Texture3D {
            .platform = try pl.GfxPlatform.Texture3D.init(desc, bind_flags, access_flags, data, gfx),
            .desc = desc,
            .bind_flags = bind_flags,
            .access_flags = access_flags,
        };
    }

    pub fn init_colour(
        desc: Descriptor,
        bind_flags: BindFlag,
        access_flags: AccessFlags,
        colour: [4]u8,
        gfx: *GfxState
    ) !Texture3D {
        if (desc.format.byte_width() != 4) { return error.FormatByteWidthMustBe4; }

        const data = try std.heap.page_allocator.alloc(u8, desc.width * desc.height * desc.depth * 4);
        defer std.heap.page_allocator.free(data);

        const data_u32: *const align(1) []u32 = @ptrCast(&data);
        const colour_u32: *const align(1) u32 = @ptrCast(&colour);

        @memset(data_u32.*[0..(data.len / 4)], colour_u32.*);

        return init(desc, bind_flags, access_flags, data, gfx);
    }

    pub const Descriptor = struct {
        width: u32,
        height: u32,
        depth: u32,
        format: TextureFormat,
        mip_levels: u32 = 1,
    };

    pub fn map(self: *const Texture3D, comptime OutType: type, gfx: *GfxState) !MappedTexture(OutType) {
        return MappedTexture(OutType) {
            .platform = try self.platform.map(OutType, gfx),
        };
    }

    pub fn MappedTexture(comptime T: type) type {
        return struct {
            platform: pl.GfxPlatform.Texture3D.MappedTexture(T),

            pub fn unmap(self: *const MappedTexture(T)) void {
                self.platform.unmap();
            }
            
            pub fn data(self: *const MappedTexture(T)) [*]align(1)T {
                return self.platform.data();
            }
        };
    }
};

pub const TextureView3D = struct {
    platform: pl.GfxPlatform.TextureView3D,
    desc: Texture3D.Descriptor,
    bind_flags: BindFlag,
    access_flags: AccessFlags,

    pub fn deinit(self: *const TextureView3D) void {
        self.platform.deinit();
    }

    pub fn init_from_texture3d(texture: *const Texture3D, gfx: *GfxState) !TextureView3D {
        return TextureView3D {
            .platform = try pl.GfxPlatform.TextureView3D.init_from_texture3d(texture, gfx),
            .desc = texture.desc,
            .bind_flags = texture.bind_flags,
            .access_flags = texture.access_flags,
        };
    }

    pub fn shader_resource_view(self: *const TextureView3D) *const pl.GfxPlatform.ShaderResourceView {
        std.debug.assert(self.bind_flags.ShaderResource);
        return self.platform.shader_resource_view();
    }

    pub fn unordered_access_view(self: *const TextureView3D) *const pl.GfxPlatform.UnorderedAccessView {
        std.debug.assert(self.bind_flags.UnorderedAccess);
        return self.platform.unordered_access_view();
    }
};

pub const RenderTargetView = struct {
    platform: pl.GfxPlatform.RenderTargetView,
    size: struct { width: u32, height: u32, depth: u32, },

    pub fn deinit(self: *const RenderTargetView) void {
        self.platform.deinit();
    }

    pub fn init_from_texture2d(texture: *const Texture2D, gfx: *GfxState) !RenderTargetView {
        return init_from_texture2d_mip(texture, 0, gfx);
    }

    pub fn init_from_texture2d_mip(texture: *const Texture2D, mip_level: u32, gfx: *GfxState) !RenderTargetView {
        return RenderTargetView {
            .platform = try pl.GfxPlatform.RenderTargetView.init_from_texture2d_mip(texture, mip_level, gfx),
            .size = .{
                .width = texture.desc.width / std.math.pow(u32, 2, mip_level),
                .height = texture.desc.height / std.math.pow(u32, 2, mip_level),
                .depth = 1,
            },
        };
    }

    pub fn init_from_texture3d(texture: *const Texture3D, gfx: *GfxState) !RenderTargetView {
        return RenderTargetView {
            .platform = try pl.GfxPlatform.RenderTargetView.init_from_texture3d(texture, gfx),
            .size = .{
                .width = texture.desc.width,
                .height = texture.desc.height,
                .depth = texture.desc.depth,
            },
        };
    }
};

pub const DepthStencilView = struct {
    platform: pl.GfxPlatform.DepthStencilView,

    pub const Flags = packed struct(u2) {
        read_only_depth: bool = false,
        read_only_stencil: bool = false,
    };

    pub fn deinit(self: *const DepthStencilView) void {
        self.platform.deinit();
    }

    pub fn init_from_texture2d(
        texture: *const Texture2D, 
        flags: Flags,
        gfx: *GfxState
    ) !DepthStencilView {
        if (!texture.desc.format.is_depth()) { return error.NotADepthFormat; }

        return DepthStencilView {
            .platform = try pl.GfxPlatform.DepthStencilView.init_from_texture2d(texture, flags, gfx),
        };
    }
};

pub const TextureFormat = enum {
    Unknown,
    Rgba8_Unorm_Srgb,
    Rgba8_Unorm,
    Bgra8_Unorm,
    R32_Float,
    Rgba16_Float,
    Rgba32_Float,
    Rg11b10_Float,
    R24X8_Unorm_Uint,
    D24S8_Unorm_Uint,

    pub fn byte_width(self: TextureFormat) usize {
        switch (self) {
            .Unknown => return 0,
            .R32_Float => return 4,
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

pub const RasterizationState = struct {
    platform: pl.GfxPlatform.RasterizationState,

    pub fn deinit(self: *const RasterizationState) void {
        self.platform.deinit();
    }

    pub fn init(desc: RasterizationStateDesc, gfx: *GfxState) !RasterizationState {
        return RasterizationState {
            .platform = try pl.GfxPlatform.RasterizationState.init(desc, gfx),
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
};

pub const Sampler = struct {
    platform: pl.GfxPlatform.Sampler,

    pub fn deinit(self: *const Sampler) void {
        self.platform.deinit();
    }

    pub fn init(desc: SamplerDescriptor, gfx: *GfxState) !Sampler {
        return Sampler {
            .platform = try pl.GfxPlatform.Sampler.init(desc, gfx),
        };
    }
};

pub const BlendType = enum {
    None,
    Simple,
};

pub const BlendState = struct {
    platform: pl.GfxPlatform.BlendState,

    pub fn deinit(self: *const BlendState) void {
        self.platform.deinit();
    }

    pub fn init(render_target_blend_types: []const BlendType, gfx: *const GfxState) !BlendState {
        if (render_target_blend_types.len > 8) {
            return error.Maximum8BlendStates;
        }
        return BlendState {
            .platform = try pl.GfxPlatform.BlendState.init(render_target_blend_types, gfx),
        };
    }
};

const ToneMappingAndBloomFilter = struct {
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
            GfxState.FULL_SCREEN_QUAD_VS,
            "vs_main",
            ([0]VertexInputLayoutEntry {})[0..],
            .{},
            gfx
        );
        errdefer vertex_shader.deinit();

        var pixel_shader = try PixelShader.init_buffer(
            GfxState.FULL_SCREEN_QUAD_VS ++ HLSL,
            "ps_main",
            .{},
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
            mapped_buffer.data().exposure = exposure;
        } else |_| {}

        const viewport = Viewport {
            .width = @floatFromInt(rtv.size.width),
            .height = @floatFromInt(rtv.size.height),
            .top_left_x = 0,
            .top_left_y = 0,
            .min_depth = 0,
            .max_depth = 0,
        };

        gfx.cmd_set_blend_state(null);
        gfx.cmd_set_render_target(&.{rtv}, null);

        gfx.cmd_set_viewport(viewport);
        gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });

        gfx.cmd_set_vertex_shader(&self.vertex_shader);

        gfx.cmd_set_pixel_shader(&self.pixel_shader);
        gfx.cmd_set_samplers(.Pixel, 0, &.{&self.sampler});
        gfx.cmd_set_shader_resources(.Pixel, 0, &.{hdr_buffer, self.bloom_filter.get_bloom_view()});
        gfx.cmd_set_constant_buffers(.Pixel, 0, &.{&self.buffer});

        gfx.cmd_set_topology(.TriangleList);

        gfx.cmd_draw(6, 0);
        
        // unset hdr texture so it can be used as rtv again
        gfx.cmd_set_shader_resources(.Pixel, 0, &.{null, null});
    }

    pub fn framebuffer_resized(self: *ToneMappingAndBloomFilter, gfx: *GfxState) !void {
        self.bloom_filter.framebuffer_resized(gfx);
    }
};
