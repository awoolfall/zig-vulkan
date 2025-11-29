const Self = @This();

const std = @import("std");
const eng = @import("../root.zig");
const gf = eng.gfx;
const zm = eng.zmath;

pub const ToneMappingOptions = packed struct(u32) {
    black_and_white: bool = false,
    __padding: u31 = 0,
};

const ToneMappingShaderSource = @embedFile("tonemapping.slang");

sampler: gf.Sampler.Ref,

images_descriptor_layout: gf.DescriptorLayout.Ref,
images_descriptor_pool: gf.DescriptorPool.Ref,
images_descriptor_set: gf.DescriptorSet.Ref,

render_pass: gf.RenderPass.Ref,
pipeline: gf.GraphicsPipeline.Ref,
framebuffer: gf.FrameBuffer.Ref,

pub fn deinit(self: *Self) void {
    self.sampler.deinit();

    self.framebuffer.deinit();
    self.pipeline.deinit();
    self.render_pass.deinit();

    self.images_descriptor_set.deinit();
    self.images_descriptor_pool.deinit();
    self.images_descriptor_layout.deinit();
}

pub fn init() !Self {
    const alloc = eng.get().general_allocator;

    const slang_shader = gf.GfxState.FULL_SCREEN_QUAD_VS ++ ToneMappingShaderSource;

    const colour_spirv_shader = try gf.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = slang_shader,
        .shader_entry_points = &.{
            "vs_main",
            "ps_main",
        },
    });
    defer alloc.free(colour_spirv_shader);

    const colour_shader_module = try gf.ShaderModule.init(.{ .spirv_data = colour_spirv_shader });
    defer colour_shader_module.deinit();

    const black_and_white_spirv_shader = try gf.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = slang_shader,
        .shader_entry_points = &.{
            "vs_main",
            "ps_main",
        },
        .preprocessor_macros = &.{
            .{ "BLACK_AND_WHITE", "1" },
        },
    });
    defer alloc.free(black_and_white_spirv_shader);

    const black_and_white_shader_module = try gf.ShaderModule.init(.{ .spirv_data = black_and_white_spirv_shader });
    defer black_and_white_shader_module.deinit();

    const vertex_input = try gf.VertexInput.init(.{
        .attributes = &.{},
        .bindings = &.{},
    });
    defer vertex_input.deinit();

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

    const images_descriptor_set = try (try images_descriptor_pool.get()).allocate_set(.{ .layout = images_descriptor_layout, });
    errdefer images_descriptor_set.deinit();

    try (try images_descriptor_set.get()).update(.{
        .writes = &.{
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .ImageView = gf.GfxState.get().default.hdr_image_view, },
            },
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 1,
                .data = .{ .Sampler = sampler, },
            },
        },
    });

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
                .src_access_mask = .{},
                .dst_access_mask = .{ .color_attachment_write = true, },
                .src_stage_mask = .{ .color_attachment_output = true, },
                .dst_stage_mask = .{ .color_attachment_output = true, },
            },
        },
    });
    errdefer render_pass.deinit();

    const pipeline = try gf.GraphicsPipeline.init(.{
        .render_pass = render_pass,
        .subpass_index = 0,
        .vertex_shader = .{
            .module = &colour_shader_module,
            .entry_point = "vs_main",
        },
        .vertex_input = &vertex_input,
        .pixel_shader = .{
            .module = &colour_shader_module,
            .entry_point = "ps_main",
        },
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

    return Self {
        .sampler = sampler,

        .images_descriptor_layout = images_descriptor_layout,
        .images_descriptor_pool = images_descriptor_pool,
        .images_descriptor_set = images_descriptor_set,

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

    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.images_descriptor_set
        },
    });

    cmd.cmd_draw(.{ .vertex_count = 6, });
}

