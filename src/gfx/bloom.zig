const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;

// Implements COD: Advanced warfare physically based bloom
// https://learnopengl.com/Guest-Articles/2022/Phys.-Based-Bloom

const Self = @This();
const MIP_LEVELS: u32 = 7;
const BloomShaderSource = @embedFile("bloom.slang");

const PushConstantData = extern struct {
    src_texel_size: [2]f32,
    mip_level: f32,
    filter_radius: f32,
    aspect_ratio: f32,
    blur_amount: f32,
};

sampler: gf.Sampler.Ref,

downsample_render_pass: gf.RenderPass.Ref,
downsample_pipeline: gf.GraphicsPipeline.Ref,
upsample_render_pass: gf.RenderPass.Ref,
upsample_pipeline: gf.GraphicsPipeline.Ref,

bloom_images: [2]gf.Image.Ref,
bloom_layers: [MIP_LEVELS]BloomLayer,

images_descriptor_layout: gf.DescriptorLayout.Ref,
images_descriptor_pool: gf.DescriptorPool.Ref,

hdr_framebuffer: gf.FrameBuffer.Ref,
hdr_descriptor_set: gf.DescriptorSet.Ref,

pub fn deinit(self: *Self) void {
    for (&self.bloom_layers) |*l| {
        l.deinit();
    }
    for (&self.bloom_images) |*i| {
        i.deinit();
    }

    self.hdr_descriptor_set.deinit();
    self.hdr_framebuffer.deinit();

    self.downsample_pipeline.deinit();
    self.downsample_render_pass.deinit();
    self.upsample_pipeline.deinit();
    self.upsample_render_pass.deinit();

    self.images_descriptor_pool.deinit();
    self.images_descriptor_layout.deinit();

    self.sampler.deinit();
}

pub fn init() !Self {
    const alloc = eng.get().general_allocator;

    const slang_shader = gf.GfxState.FULL_SCREEN_QUAD_VS ++ BloomShaderSource;

    const spirv_shader = try gf.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = slang_shader,
        .shader_entry_points = &.{
            "vs_main",
            "ps_downsample",
            "ps_upsample",
        },
    });
    defer alloc.free(spirv_shader);

    const shader_module = try gf.ShaderModule.init(.{
        .spirv_data = spirv_shader,
    });
    defer shader_module.deinit();

    const vertex_input = try gf.VertexInput.init(.{ .bindings = &.{}, .attributes = &.{}, });
    defer vertex_input.deinit();

    var sampler = try gf.Sampler.init(.{
        .filter_min_mag = .Linear,
        .max_lod = @floatFromInt(MIP_LEVELS - 1),
    });
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
        .max_sets = (MIP_LEVELS * 2) + 2,
        .strategy = .{ .Layout = images_descriptor_layout, },
    });
    errdefer images_descriptor_pool.deinit();
    
    var bloom_images_buffer: [2]gf.Image.Ref = undefined;
    var bloom_images = std.ArrayList(gf.Image.Ref).initBuffer(&bloom_images_buffer);
    errdefer for (bloom_images.items) |i| { i.deinit(); };

    for (0..2) |i| {
        const image = try gf.Image.init(.{
            .match_swapchain_extent = true,
            .format = gf.GfxState.hdr_format,
            .mip_levels = MIP_LEVELS,

            .usage_flags = .{ .ShaderResource = true, .RenderTarget = true, },
            .access_flags = .{ .GpuWrite = true, },
            .dst_layout = if (i == 0) .ColorAttachmentOptimal else .ShaderReadOnlyOptimal,
        }, null);
        errdefer image.deinit();

        try bloom_images.appendBounded(image);
    }

    // Downsample
    const downsample_attachments = &[_]gf.AttachmentInfo {
        gf.AttachmentInfo {
            .name = "colour",
            .format = gf.GfxState.hdr_format,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
        },
    };

    const downsample_render_pass = try gf.RenderPass.init(.{
        .attachments = downsample_attachments,
        .subpasses = &.{
            gf.SubpassInfo {
                .attachments = &.{ "colour" },
                .depth_attachment = null,
            },
            },
        .dependencies = &.{
            gf.SubpassDependencyInfo {
                .src_subpass = null,
                .dst_subpass = 0,
                .src_stage_mask = .{ .color_attachment_output = true, },
                .dst_stage_mask = .{ .color_attachment_output = true, },
                .src_access_mask = .{},
                .dst_access_mask = .{ .color_attachment_write = true, },
            },
            },
        });
    errdefer downsample_render_pass.deinit();

    const downsample_pipeline = try gf.GraphicsPipeline.init(.{
        .render_pass = downsample_render_pass,
        .subpass_index = 0,
        .vertex_shader = .{
            .module = &shader_module,
            .entry_point = "vs_main",
        },
        .vertex_input = &vertex_input,
        .pixel_shader = .{
            .module = &shader_module,
            .entry_point = "ps_downsample"
        },
        .front_face = .Clockwise,
        .descriptor_set_layouts = &.{
            images_descriptor_layout,
        },
        .push_constants = &.{
            gf.PushConstantLayoutInfo {
                .shader_stages = .{ .Pixel = true, },
                .offset = 0,
                .size = @sizeOf(PushConstantData),
            },
            },
        });
    errdefer downsample_pipeline.deinit();

    // Upsample
    const upsample_attachments = &[_]gf.AttachmentInfo {
        gf.AttachmentInfo {
            .name = "colour",
            .format = gf.GfxState.hdr_format,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .Simple,
        },
    };

    const upsample_render_pass = try gf.RenderPass.init(.{
        .attachments = upsample_attachments,
        .subpasses = &.{
            gf.SubpassInfo {
                .attachments = &.{ "colour" },
                .depth_attachment = null,
            },
            },
        .dependencies = &.{
            gf.SubpassDependencyInfo {
                .src_subpass = null,
                .dst_subpass = 0,
                .src_stage_mask = .{ .color_attachment_output = true, },
                .dst_stage_mask = .{ .color_attachment_output = true, },
                .src_access_mask = .{},
                .dst_access_mask = .{ .color_attachment_write = true, },
            },
            },
        });
    errdefer upsample_render_pass.deinit();

    const upsample_pipeline = try gf.GraphicsPipeline.init(.{
        .render_pass = upsample_render_pass,
        .subpass_index = 0,
        .vertex_shader = .{
            .module = &shader_module,
            .entry_point = "vs_main",
        },
        .vertex_input = &vertex_input,
        .pixel_shader = .{
            .module = &shader_module,
            .entry_point = "ps_upsample"
        },
        .front_face = .Clockwise,
        .descriptor_set_layouts = &.{
            images_descriptor_layout,
        },
        .push_constants = &.{
            gf.PushConstantLayoutInfo {
                .shader_stages = .{ .Pixel = true, },
                .offset = 0,
                .size = @sizeOf(PushConstantData),
            },
            },
        });
    errdefer upsample_pipeline.deinit();

    var bloom_layers_buffer: [MIP_LEVELS]BloomLayer = undefined;
    var bloom_layers = std.ArrayList(BloomLayer).initBuffer(&bloom_layers_buffer);
    errdefer for (bloom_layers.items) |*l| { l.deinit(); };

    for (0..MIP_LEVELS) |mip_level| {
        const bloom_layer = try BloomLayer.init(
            &bloom_images_buffer,
            mip_level,
            downsample_render_pass,
            upsample_render_pass,
            sampler,
            images_descriptor_layout,
            images_descriptor_pool
        );
        errdefer bloom_layer.deinit();

        try bloom_layers.appendBounded(bloom_layer);
    }

    const hdr_framebuffer = try gf.FrameBuffer.init(.{
        .render_pass = upsample_render_pass,
        .attachments = &.{
            .SwapchainHDR,
        },
    });
    errdefer hdr_framebuffer.deinit();

    const hdr_descriptor_set = try (try images_descriptor_pool.get()).allocate_set(.{
        .layout = images_descriptor_layout,
    });
    errdefer hdr_descriptor_set.deinit();

    try (try hdr_descriptor_set.get()).update(.{
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

    return Self {
        .sampler = sampler,

        .downsample_render_pass = downsample_render_pass,
        .downsample_pipeline = downsample_pipeline,
        .upsample_render_pass = upsample_render_pass,
        .upsample_pipeline = upsample_pipeline,

        .images_descriptor_layout = images_descriptor_layout,
        .images_descriptor_pool = images_descriptor_pool,

        .bloom_images = bloom_images_buffer,
        .bloom_layers = bloom_layers_buffer,

        .hdr_framebuffer = hdr_framebuffer,
        .hdr_descriptor_set = hdr_descriptor_set,
    };
}

fn transition_image_to_shader_read_only(
    cmd: *gf.CommandBuffer,
    image: gf.Image.Ref,
    base_mip_level: usize,
    mip_count: usize,
) void {
    _ = base_mip_level;
    _ = mip_count;
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .color_attachment_output = true, },
        .dst_stage = .{ .fragment_shader = true, },
        .image_barriers = &.{
            gf.CommandBuffer.ImageMemoryBarrierInfo {
                .image = image,
                .subresource_range = .{
                    //.base_mip_level = @intCast(base_mip_level),
                    //.mip_level_count = @intCast(mip_count),
                },
                .old_layout = .ColorAttachmentOptimal,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .color_attachment_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
        },
    });
}

fn transition_image_to_colour_attachment(
    cmd: *gf.CommandBuffer,
    image: gf.Image.Ref,
    base_mip_level: usize,
    mip_count: usize,
) void {
    _ = base_mip_level;
    _ = mip_count;
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .fragment_shader = true, },
        .dst_stage = .{ .color_attachment_output = true, },
        .image_barriers = &.{
            gf.CommandBuffer.ImageMemoryBarrierInfo {
                .image = image,
                .subresource_range = .{
                    // .base_mip_level = @intCast(base_mip_level),
                    // .mip_level_count = @intCast(mip_count),
                },
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .ColorAttachmentOptimal,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .color_attachment_write = true, },
            },
        },
    });
}

const BloomSettings = struct {
    filter_radius: f32 = 0.02,
    blur_amount: f32 = 0.03,
};

pub fn render_bloom(
    self: *const Self,
    cmd: *gf.CommandBuffer,
    settings: BloomSettings,
) !void {
    // Transition HDR image to shader resource
    transition_image_to_shader_read_only(cmd, gf.GfxState.get().default.hdr_image, 0, 1);

    // Downsample
    for (1..MIP_LEVELS) |mip_level| {
        const colour_attachment_index = mip_level % 2;
        const shader_index = (mip_level + 1) % 2;

        transition_image_to_colour_attachment(cmd, self.bloom_images[colour_attachment_index], mip_level, 1);
        transition_image_to_shader_read_only(cmd, self.bloom_images[shader_index], mip_level - 1, 1);

        cmd.cmd_begin_render_pass(.{
            .render_pass = self.downsample_render_pass,
            .framebuffer = self.bloom_layers[mip_level].downsample_framebuffers[colour_attachment_index],
            .render_area = .full_screen_pixels_mip(mip_level),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.downsample_pipeline);
        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport_mip(mip_level), }, });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels_mip(mip_level), }, });

        cmd.cmd_bind_descriptor_sets(.{
            .graphics_pipeline = self.downsample_pipeline,
            .descriptor_sets = &.{
                if (mip_level == 1) self.hdr_descriptor_set
                else self.bloom_layers[mip_level - 1].image_descriptor_sets[shader_index],
            },
        });

        var size = gf.GfxState.get().swapchain_size();
        size[0] >>= @intCast(mip_level - 1);
        size[1] >>= @intCast(mip_level - 1);

        const push_constants = PushConstantData {
            .mip_level = @floatFromInt(mip_level),
            .aspect_ratio = gf.GfxState.get().swapchain_aspect(),
            .filter_radius = settings.filter_radius,
            .src_texel_size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
            .blur_amount = settings.blur_amount,
        };

        cmd.cmd_push_constants(.{
            .graphics_pipeline = self.downsample_pipeline,
            .shader_stages = .{ .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constants),
        });

        cmd.cmd_draw(.{ .vertex_count = 6, });
    }

    // Transition HDR image back to colour attachment
    transition_image_to_colour_attachment(cmd, gf.GfxState.get().default.hdr_image, 0, 1);

    // transition_image_to_shader_read_only(cmd, self.bloom_images.get(0), 0, MIP_LEVELS);
    // transition_image_to_colour_attachment(cmd, self.bloom_images.get(1), 0, MIP_LEVELS);

    // Upsample
    for (1..(MIP_LEVELS - 1)) |inv_mip_level| {
        const mip_level = MIP_LEVELS - inv_mip_level;
        const shader_index = mip_level % 2;
        const colour_attachment_index = (mip_level + 1) % 2;

        transition_image_to_shader_read_only(cmd, self.bloom_images[shader_index], mip_level, 1);
        transition_image_to_colour_attachment(cmd, self.bloom_images[colour_attachment_index], mip_level - 1, 1);

        cmd.cmd_begin_render_pass(.{
            .render_pass = self.upsample_render_pass,
            .framebuffer =  self.bloom_layers[mip_level - 1].upsample_framebuffers[colour_attachment_index],
            .render_area = .full_screen_pixels_mip(mip_level - 1),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.upsample_pipeline);
        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport_mip(mip_level - 1), }, });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels_mip(mip_level - 1), }, });

        cmd.cmd_bind_descriptor_sets(.{
            .graphics_pipeline = self.upsample_pipeline,
            .descriptor_sets = &.{
                self.bloom_layers[mip_level].image_descriptor_sets[shader_index],
            },
        });

        var size = gf.GfxState.get().swapchain_size();
        size[0] >>= @intCast(mip_level);
        size[1] >>= @intCast(mip_level);

        const push_constants = PushConstantData {
            .mip_level = @floatFromInt(mip_level),
            .aspect_ratio = gf.GfxState.get().swapchain_aspect(),
            .filter_radius = settings.filter_radius,
            .src_texel_size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
            .blur_amount = settings.blur_amount,
        };

        cmd.cmd_push_constants(.{
            .graphics_pipeline = self.upsample_pipeline,
            .shader_stages = .{ .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constants),
        });

        cmd.cmd_draw(.{ .vertex_count = 6, });
    }

    // Perform final upscale merging into the hdr buffer
    {
        const mip_level = 1;
        const shader_index = mip_level % 2;
        const colour_attachment_index = (mip_level + 1) % 2;

        transition_image_to_shader_read_only(cmd, self.bloom_images[shader_index], mip_level, 1);
        transition_image_to_colour_attachment(cmd, self.bloom_images[colour_attachment_index], mip_level - 1, 1);

        cmd.cmd_begin_render_pass(.{
            .render_pass = self.upsample_render_pass,
            .framebuffer =  self.hdr_framebuffer,
            .render_area = .full_screen_pixels_mip(0),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.upsample_pipeline);
        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport_mip(0), }, });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels_mip(0), }, });

        cmd.cmd_bind_descriptor_sets(.{
            .graphics_pipeline = self.upsample_pipeline,
            .descriptor_sets = &.{
                self.bloom_layers[mip_level].image_descriptor_sets[shader_index],
            },
            });

        var size = gf.GfxState.get().swapchain_size();
        size[0] >>= @intCast(mip_level);
        size[1] >>= @intCast(mip_level);

        const push_constants = PushConstantData {
            .mip_level = @floatFromInt(mip_level),
            .aspect_ratio = gf.GfxState.get().swapchain_aspect(),
            .filter_radius = settings.filter_radius,
            .src_texel_size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
            .blur_amount = settings.blur_amount,
        };

        cmd.cmd_push_constants(.{
            .graphics_pipeline = self.upsample_pipeline,
            .shader_stages = .{ .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constants),
        });

        cmd.cmd_draw(.{ .vertex_count = 6, });
    }
}

const BloomLayer = struct {
    views: [2]gf.ImageView.Ref,
    image_descriptor_sets: [2]gf.DescriptorSet.Ref,

    downsample_framebuffers: [2]gf.FrameBuffer.Ref,
    upsample_framebuffers: [2]gf.FrameBuffer.Ref,

    pub fn deinit(self: *const BloomLayer) void {
        for (&self.downsample_framebuffers) |*f| {
            f.deinit();
        }
        for (&self.upsample_framebuffers) |*f| {
            f.deinit();
        }

        for (&self.image_descriptor_sets) |*s| {
            s.deinit();
        }
        for (&self.views) |*v| {
            v.deinit();
        }
    }

    pub fn init(
        images: []gf.Image.Ref,
        mip_level: usize,
        downsample_render_pass: gf.RenderPass.Ref,
        upsample_render_pass: gf.RenderPass.Ref,
        sampler: gf.Sampler.Ref,
        images_descriptor_layout: gf.DescriptorLayout.Ref,
        images_descriptor_pool: gf.DescriptorPool.Ref,
    ) !BloomLayer {
        std.debug.assert(images.len >= 2);

        var bloom_layer = BloomLayer {
            .views = undefined,
            .image_descriptor_sets = undefined,
            .downsample_framebuffers = undefined,
            .upsample_framebuffers = undefined,
        };

        var views = std.ArrayList(gf.ImageView.Ref).initBuffer(&bloom_layer.views);
        errdefer for (views.items) |v| { v.deinit(); };

        var descriptor_sets = std.ArrayList(gf.DescriptorSet.Ref).initBuffer(&bloom_layer.image_descriptor_sets);
        errdefer for (descriptor_sets.items) |s| { s.deinit(); };

        var downsample_framebuffers = std.ArrayList(gf.FrameBuffer.Ref).initBuffer(&bloom_layer.downsample_framebuffers);
        errdefer for (downsample_framebuffers.items) |f| { f.deinit(); };

        var upsample_framebuffers = std.ArrayList(gf.FrameBuffer.Ref).initBuffer(&bloom_layer.upsample_framebuffers);
        errdefer for (upsample_framebuffers.items) |f| { f.deinit(); };

        for (0..2) |i| {
            const view = try gf.ImageView.init(.{
                .image = images[i],
                .view_type = .ImageView2D,
                .mip_levels = .{
                    .base_mip_level = @intCast(mip_level),
                    .mip_level_count = 1,
                },
            });
            errdefer view.deinit();

            const set = try (try images_descriptor_pool.get()).allocate_set(.{ .layout = images_descriptor_layout, });
            errdefer set.deinit();

            try (try set.get()).update(.{
                .writes = &.{
                    gf.DescriptorSetUpdateWriteInfo {
                        .binding = 0,
                        .data = .{ .ImageView = view, },
                    },
                    gf.DescriptorSetUpdateWriteInfo {
                        .binding = 1,
                        .data = .{ .Sampler = sampler, },
                    },
                },
            });

            // Downsample
            const downsample_framebuffer = try gf.FrameBuffer.init(.{
                .render_pass = downsample_render_pass,
                .attachments = &.{
                    .{ .View = view, },
                },
                });
            errdefer downsample_framebuffer.deinit();

            // Upsample
            const upsample_framebuffer = try gf.FrameBuffer.init(.{
                .render_pass = upsample_render_pass,
                .attachments = &.{
                    .{ .View = view, },
                },
                });
            errdefer upsample_framebuffer.deinit();

            try views.appendBounded(view);
            try descriptor_sets.appendBounded(set);
            try downsample_framebuffers.appendBounded(downsample_framebuffer);
            try upsample_framebuffers.appendBounded(upsample_framebuffer);
        }

        return bloom_layer;
    }
};

