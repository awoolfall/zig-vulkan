const std = @import("std");
const zm = @import("zmath");
const gf = @import("../gfx.zig");
const wb = @import("../../window.zig");
const path = @import("../../engine/path.zig");
const bloom = @import("../bloom.zig");
const pl = @import("../../platform/platform.zig");

pub const GfxStateNoop = struct {
    const Self = @This();

    pub const VertexShader = VertexShaderNoop;
    pub const PixelShader = PixelShaderNoop;
    pub const Buffer = BufferNoop;
    pub const Texture2D = Texture2DNoop;
    pub const TextureView2D = TextureView2DNoop;
    pub const RenderTargetView = RenderTargetViewNoop;
    pub const DepthStencilView = DepthStencilViewNoop;
    pub const RasterizationState = RasterizationStateNoop;
    pub const Sampler = SamplerNoop;
    pub const BlendState = BlendStateNoop;

    allocator: std.mem.Allocator,
    mapped_data_array: ?[]u8 = null,

    pub fn deinit(self: *Self) void {
        if (self.mapped_data_array) |d| {
            self.allocator.free(d);
        }
    }

    pub fn init(alloc: std.mem.Allocator, window: *pl.Window) !Self {
        _ = window;

        return Self {
            .allocator = alloc,
        };
    }

    pub fn create_texture2d_from_framebuffer(self: *Self, gfx: *gf.GfxState) !gf.Texture2D {
        _ = self;
        return gf.Texture2D {
            .platform = Self.Texture2D {
            },
            .desc = gf.Texture2D.Descriptor {
                .width = @intCast(gfx.swapchain_size.width),
                .height = @intCast(gfx.swapchain_size.height),
                .format = gf.TextureFormat.Rgba8_Unorm_Srgb,
            },
        };
    }

    pub inline fn present(self: *Self) !void {
        _ = self;
    }

    pub inline fn flush(self: *Self) void {
        _ = self;
    }
    
    pub inline fn resize_swapchain(self: *Self, new_width: i32, new_height: i32) void {
        _ = self;
        _ = new_width;
        _ = new_height;
    }

    pub inline fn cmd_clear_render_target(self: *Self, rt: *const gf.RenderTargetView, color: zm.F32x4) void {
        _ = self;
        _ = rt;
        _ = color;
    }

    pub inline fn cmd_clear_depth_stencil_view(self: *Self, dsv: *const gf.DepthStencilView, depth: ?f32, stencil: ?u8) void {
        _ = self;
        _ = dsv;
        _ = depth;
        _ = stencil;
    }

    pub inline fn cmd_set_viewport(self: *Self, viewport: gf.Viewport) void {
        _ = self;
        _ = viewport;
    }

    pub inline fn cmd_set_render_target(self: *Self, rt: *const gf.RenderTargetView, depth_stencil_view: ?*const gf.DepthStencilView) void {
        _ = self;
        _ = rt;
        _ = depth_stencil_view;
    }

    pub inline fn cmd_set_vertex_shader(self: *Self, vs: *const gf.VertexShader) void {
        _ = self;
        _ = vs;
    }

    pub inline fn cmd_set_pixel_shader(self: *Self, ps: *const gf.PixelShader) void {
        _ = self;
        _ = ps;
    }

    pub inline fn cmd_set_vertex_buffers(self: *Self, start_slot: u32, buffers: []const gf.VertexBufferInput) void {
        _ = self;
        _ = start_slot;
        _ = buffers;
    }

    pub inline fn cmd_set_index_buffer(self: *Self, buffer: *gf.Buffer, format: gf.IndexFormat, offset: u32) void {
        _ = self;
        _ = buffer;
        _ = format;
        _ = offset;
    }

    pub inline fn cmd_set_constant_buffers(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, buffers: []const *const gf.Buffer) void {
        _ = self;
        _ = shader_stage;
        _ = start_slot;
        _ = buffers;
    }

    pub inline fn cmd_set_rasterizer_state(self: *Self, rs: *gf.RasterizationState) void {
        _ = self;
        _ = rs;
    }

    pub inline fn cmd_set_blend_state(self: *Self, blend_state: ?*const gf.BlendState) void {
        _ = self;
        _ = blend_state;
    }

    pub inline fn cmd_set_shader_resources(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, views: []const ?*const gf.TextureView2D) void {
        _ = self;
        _ = shader_stage;
        _ = start_slot;
        _ = views;
    }

    pub inline fn cmd_set_samplers(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, sampler: []const *const gf.Sampler) void {
        _ = self;
        _ = shader_stage;
        _ = start_slot;
        _ = sampler;
    }

    pub inline fn cmd_draw(self: *Self, vertex_count: u32, start_vertex: u32) void {
        _ = self;
        _ = vertex_count;
        _ = start_vertex;
    }

    pub inline fn cmd_draw_indexed(self: *Self, index_count: u32, start_index: u32, base_vertex: i32) void {
        _ = self;
        _ = index_count;
        _ = start_index;
        _ = base_vertex;
    }

    pub inline fn cmd_draw_instanced(self: *Self, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) void {
        _ = self;
        _ = vertex_count;
        _ = instance_count;
        _ = start_vertex;
        _ = start_instance;
    }

    pub inline fn cmd_set_topology(self: *Self, topology: gf.Topology) void {
        _ = self;
        _ = topology;
    }

    pub inline fn cmd_copy_texture_to_texture(self: *Self, dst_texture: *const gf.Texture2D, src_texture: *const gf.Texture2D) void {
        _ = self;
        _ = dst_texture;
        _ = src_texture;
    }
};

pub const VertexShaderNoop = struct {
    const Self = @This();
    
    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_buffer(
        vs_data: []const u8, 
        vs_func: []const u8, 
        vs_layout: []const gf.VertexInputLayoutEntry,
        gfx: *gf.GfxState,
    ) !Self {
        _ = vs_data;
        _ = vs_func;
        _ = vs_layout;
        _ = gfx;

        return Self {
        };
    }
};

pub const PixelShaderNoop = struct {
    const Self = @This();
    
    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub inline fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8, 
        gfx: *gf.GfxState,
    ) !Self {
        _ = ps_data;
        _ = ps_func;
        _ = gfx;

        return Self {
        };
    }
};

pub const BufferNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init(
        byte_size: u32,
        bind_flags: gf.BindFlag,
        access_flags: gf.AccessFlags,
        gfx: *gf.GfxState,
    ) !Self {
        _ = byte_size;
        _ = bind_flags;
        _ = access_flags;
        _ = gfx;
        
        return Self {
        };
    }
    
    pub inline fn init_with_data(
        data: []const u8,
        bind_flags: gf.BindFlag,
        access_flags: gf.AccessFlags,
        gfx: *gf.GfxState,
    ) !Self {
        _ = data;
        _ = bind_flags;
        _ = access_flags;
        _ = gfx;
        
        return Self {
        };
    }

    pub inline fn map(self: *const Self, comptime OutType: type, gfx: *gf.GfxState) !MappedBuffer(OutType) {
        _ = self;
        var fake_data: OutType = undefined;
        @memset(std.mem.asBytes(&fake_data), 0);
        return MappedBuffer(OutType) {
            .gfx = gfx,
            .fake_data = fake_data,
        };
    }

    pub fn MappedBuffer(comptime T: type) type {
        return struct {
            gfx: *gf.GfxState,
            fake_data: T,

            pub inline fn unmap(self: *const MappedBuffer(T)) void {
                _ = self;
            }
            
            pub inline fn data(self: *const MappedBuffer(T)) *T {
                return @constCast(&self.fake_data);
            }
            
            pub inline fn data_array(self: *const MappedBuffer(T), length: usize) [*]align(1)T {
                if (self.gfx.platform.mapped_data_array) |d| {
                    if (d.len < (@sizeOf(T) * length)) {
                        self.gfx.platform.mapped_data_array = self.gfx.platform.allocator.realloc(d, @sizeOf(T) * length) catch unreachable;
                    }
                } else {
                    self.gfx.platform.mapped_data_array = std.mem.sliceAsBytes(self.gfx.platform.allocator.alloc(T, @sizeOf(T) * length) catch unreachable);
                }

                const slice: []align(1)T = std.mem.bytesAsSlice(T, self.gfx.platform.mapped_data_array.?);
                return slice.ptr;
            }
        };
    }

};

pub const Texture2DNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init(
        desc: gf.Texture2D.Descriptor,
        bind_flags: gf.BindFlag,
        access_flags: gf.AccessFlags,
        data: ?[]const u8,
        gfx: *gf.GfxState
    ) !Self {
        _ = desc;
        _ = bind_flags;
        _ = access_flags;
        _ = data;
        _ = gfx;

        return Self {
        };
    }
};

pub const TextureView2DNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_from_texture2d(texture: *const gf.Texture2D, gfx: *gf.GfxState) !Self {
        _ = texture;
        _ = gfx;

        return Self {
        };
    }
};

pub const RenderTargetViewNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_from_texture2d_mip(texture: *const gf.Texture2D, mip_level: u32, gfx: *gf.GfxState) !Self {
        _ = texture;
        _ = mip_level;
        _ = gfx;

        return Self {
        };
    }
};

pub const DepthStencilViewNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_from_texture2d(
        texture: *const gf.Texture2D, 
        flags: gf.DepthStencilView.Flags,
        gfx: *gf.GfxState
    ) !Self {
        _ = texture;
        _ = flags;
        _ = gfx;

        return Self {
        };
    }
};

pub const RasterizationStateNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init(desc: gf.RasterizationStateDesc, gfx: *gf.GfxState) !Self {
        _ = desc;
        _ = gfx;

        return Self {
        };
    }
};

pub const SamplerNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init(desc: gf.SamplerDescriptor, gfx: *gf.GfxState) !Self {
        _ = desc;
        _ = gfx;

        return Self {
        };
    }
};

pub const BlendStateNoop = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init(render_target_blend_types: []const gf.BlendType, gfx: *const gf.GfxState) !Self {
        _ = render_target_blend_types;
        _ = gfx;

        return Self {
        };
    }
};

