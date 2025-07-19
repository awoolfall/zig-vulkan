const Self = @This();

const std = @import("std");
const eng = @import("../root.zig");
const gf = eng.gfx;
const zm = eng.zmath;
const bloom = @import("bloom.zig");

pub const ToneMappingOptions = packed struct(u32) {
    black_and_white: bool = false,
    __padding: u31 = 0,
};

const ToneMappingShaderSource = @embedFile("tonemapping.slang");

vertex_shader: gf.VertexShader,
pixel_shader: gf.PixelShader,
black_and_white_pixel_shader: gf.PixelShader,
sampler: gf.Sampler.Ref,

bloom_filter: bloom.BloomFilter,

images_descriptor_layout: gf.DescriptorLayout.Ref,
images_descriptor_pool: gf.DescriptorPool.Ref,
images_descriptor_sets: std.ArrayList(gf.DescriptorSet.Ref),

render_pass: gf.RenderPass.Ref,
pipeline: gf.GraphicsPipeline.Ref,
framebuffer: gf.FrameBuffer.Ref,

pub fn deinit(self: *Self) void {
    self.bloom_filter.deinit();
    self.vertex_shader.deinit();
    self.pixel_shader.deinit();
    self.black_and_white_pixel_shader.deinit();
    self.sampler.deinit();

    self.framebuffer.deinit();
    self.pipeline.deinit();
    self.render_pass.deinit();

    for (self.images_descriptor_sets.items) |s| { s.deinit(); }
    self.images_descriptor_sets.deinit();
    self.images_descriptor_pool.deinit();
    self.images_descriptor_layout.deinit();
}

pub fn init() !Self {
    var vertex_shader = try gf.VertexShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS ++ ToneMappingShaderSource,
        "vs_main",
        .{ .bindings = &.{}, .attributes = &.{} },
        .{},
    );
    errdefer vertex_shader.deinit();

    var pixel_shader = try gf.PixelShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS ++ ToneMappingShaderSource,
        "ps_main",
        .{},
    );
    errdefer pixel_shader.deinit();

    var black_and_white_pixel_shader = try gf.PixelShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS ++ ToneMappingShaderSource,
        "ps_main",
        .{
            .defines = &.{
                .{ "BLACK_AND_WHITE", "1" },
            },
        },
    );
    errdefer black_and_white_pixel_shader.deinit();

    var sampler = try gf.Sampler.init(.{});
    errdefer sampler.deinit();

    const images_descriptor_layout = try gf.DescriptorLayout.init(.{
        .bindings = &.{
            gf.DescriptorBindingInfo {
                .binding = 0,
                .shader_stages = .{ .Pixel = true, },
                .binding_type = .ImageView,
            },
            gf.DescriptorBindingInfo {
                .binding = 1,
                .shader_stages = .{ .Pixel = true, },
                .binding_type = .Sampler,
            },
        },
    });
    errdefer images_descriptor_layout.deinit();

    const images_descriptor_pool = try gf.DescriptorPool.init(.{
        .max_sets = gf.GfxState.get().frames_in_flight(),
        .strategy = .{ .Layout = images_descriptor_layout, },
    });
    errdefer images_descriptor_pool.deinit();

    var images_descriptor_sets = try std.ArrayList(gf.DescriptorSet.Ref).initCapacity(eng.get().general_allocator, gf.GfxState.get().frames_in_flight());
    errdefer images_descriptor_sets.deinit();
    errdefer for (images_descriptor_sets.items) |s| { s.deinit(); };

    for (0..gf.GfxState.get().frames_in_flight()) |_| {
        const set = try (try images_descriptor_pool.get()).allocate_set(.{ .layout = images_descriptor_layout, });
        errdefer set.deinit();

        try images_descriptor_sets.append(set);
    }

    const attachments = &[_]gf.AttachmentInfo {
        gf.AttachmentInfo {
            .name = "ldr_colour",
            .format = gf.GfxState.ldr_format,
            .load_op = .Clear,
            .clear_value = zm.f32x4(0.0, 0.0, 0.0, 1.0),
            .initial_layout = .Undefined,
            .final_layout = .ColorAttachmentOptimal,
        },
    };

    const render_pass = try gf.RenderPass.init(.{
        .attachments = attachments,
        .subpasses = &.{
            gf.SubpassInfo {
                .attachments = &.{
                    "ldr_colour",
                },
                .depth_attachment = null,
            },
        },
        .dependencies = &.{
            gf.SubpassDependencyInfo {
                .src_subpass = null,
                .dst_subpass = 0,
                .src_access_mask = .{ .color_attachment_write = true, },
                .dst_access_mask = .{ .color_attachment_write = true, },
                .src_stage_mask = .{ .all_graphics = true, },
                .dst_stage_mask = .{ .color_attachment_output = true, },
            },
        },
    });
    errdefer render_pass.deinit();

    const pipeline = try gf.GraphicsPipeline.init(.{
        .render_pass = render_pass,
        .subpass_index = 0,
        .attachments = attachments,
        .vertex_shader = &vertex_shader,
        .pixel_shader = &pixel_shader,
        .cull_mode = .CullNone,
        .descriptor_set_layouts = &.{
            images_descriptor_layout,
        },
    });
    errdefer pipeline.deinit();

    const framebuffer = try gf.FrameBuffer.init(.{
        .render_pass = render_pass,
        .attachments = &.{
            .SwapchainLDR,
        },
    });
    errdefer framebuffer.deinit();

    var bloom_filter = try bloom.BloomFilter.init();
    errdefer bloom_filter.deinit();

    return Self {
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .black_and_white_pixel_shader = black_and_white_pixel_shader,
        .sampler = sampler,
        .bloom_filter = bloom_filter,

        .images_descriptor_layout = images_descriptor_layout,
        .images_descriptor_pool = images_descriptor_pool,
        .images_descriptor_sets = images_descriptor_sets,

        .render_pass = render_pass,
        .pipeline = pipeline,
        .framebuffer = framebuffer,
    };
}

pub fn apply_filter(
    self: *Self,
    cmd: *gf.CommandBuffer,
) !void {
    cmd.cmd_begin_render_pass(.{
        .render_pass = self.render_pass,
        .framebuffer = self.framebuffer,
        .render_area = .full_screen_pixels(),
    });
    defer cmd.cmd_end_render_pass();

    cmd.cmd_bind_graphics_pipeline(self.pipeline);

    cmd.cmd_set_viewports(.{
        .viewports = &.{ .full_screen_viewport(), },
    });
    cmd.cmd_set_scissors(.{
        .scissors = &.{ .full_screen_pixels(), },
    });

    const set = self.images_descriptor_sets.items[gf.GfxState.get().current_frame_index()];

    // TODO allow setting of images which contain multiple backing vulkan images, such as the hdr image used here
    // we do this every frame since the backing image changes based on the current frame index.
    try (try set.get()).update(.{
        .writes = &.{
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .ImageView = gf.GfxState.get().platform.swapchain.hdr_image_view, },
            },
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 1,
                .data = .{ .Sampler = self.sampler, },
            },
        },
    });

    cmd.cmd_bind_descriptor_sets(.{
        .graphics_pipeline = self.pipeline,
        .descriptor_sets = &.{
            set
        },
    });

    cmd.cmd_draw(.{ .vertex_count = 6, });
}

