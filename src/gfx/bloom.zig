const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;

// Implements COD: Advanced warfare physically based bloom
// https://learnopengl.com/Guest-Articles/2022/Phys.-Based-Bloom

const Self = @This();
const MIP_LEVELS: u32 = 5;
const BloomShaderSource = @embedFile("bloom.slang");

const ConstantBufferData = extern struct {
    resolution_or_radius: [4]f32,
};

const PushConstantData = extern struct {
    src_texel_size: [2]f32,
    mip_level: f32,
    filter_radius: f32,
    aspect_ratio: f32,
    blur_amount: f32,
};

full_screen_quad_vertex_shader: gf.VertexShader,
downsample_pixel_shader: gf.PixelShader,
upsample_pixel_shader: gf.PixelShader,

sampler: gf.Sampler.Ref,

downsample_render_pass: gf.RenderPass.Ref,
downsample_pipeline: gf.GraphicsPipeline.Ref,
upsample_render_pass: gf.RenderPass.Ref,
upsample_pipeline: gf.GraphicsPipeline.Ref,

bloom_images: std.BoundedArray(gf.Image.Ref, 2),
bloom_layers: std.BoundedArray(BloomLayer, MIP_LEVELS),

images_descriptor_layout: gf.DescriptorLayout.Ref,
images_descriptor_pool: gf.DescriptorPool.Ref,

hdr_framebuffer: gf.FrameBuffer.Ref,
hdr_descriptor_set: gf.DescriptorSet.Ref,

pub fn deinit(self: *Self) void {
    for (self.bloom_layers.slice()) |*l| {
        l.deinit();
    }
    for (self.bloom_images.slice()) |*i| {
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

    self.full_screen_quad_vertex_shader.deinit();
    self.downsample_pixel_shader.deinit();
    self.upsample_pixel_shader.deinit();
}

pub fn init() !Self {
    var full_screen_quad_vertex_shader = try gf.VertexShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS,
        "vs_main",
        .{ .bindings = &.{}, .attributes = &.{}, },
        .{},
    );
    errdefer full_screen_quad_vertex_shader.deinit();

    var downsample_pixel_shader = try gf.PixelShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS ++ BloomShaderSource,
        "ps_downsample",
        .{},
    );
    errdefer downsample_pixel_shader.deinit();

    var upsample_pixel_shader = try gf.PixelShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS ++ BloomShaderSource,
        "ps_upsample",
        .{},
    );
    errdefer upsample_pixel_shader.deinit();

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
    
    var bloom_images = try std.BoundedArray(gf.Image.Ref, 2).init(0);
    errdefer for (bloom_images.slice()) |i| { i.deinit(); };

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

        try bloom_images.append(image);
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
        .attachments = downsample_attachments,
        .vertex_shader = &full_screen_quad_vertex_shader,
        .pixel_shader = &downsample_pixel_shader,
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
        .attachments = upsample_attachments,
        .vertex_shader = &full_screen_quad_vertex_shader,
        .pixel_shader = &upsample_pixel_shader,
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


    var bloom_layers = try std.BoundedArray(BloomLayer, MIP_LEVELS).init(0);
    errdefer for (bloom_layers.slice()) |*l| { l.deinit(); };

    for (0..MIP_LEVELS) |mip_level| {
        const bloom_layer = try BloomLayer.init(
            bloom_images.slice(),
            mip_level,
            downsample_render_pass,
            upsample_render_pass,
            sampler,
            images_descriptor_layout,
            images_descriptor_pool
        );
        errdefer bloom_layer.deinit();

        try bloom_layers.append(bloom_layer);
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
        .full_screen_quad_vertex_shader = full_screen_quad_vertex_shader,
        .downsample_pixel_shader = downsample_pixel_shader,
        .upsample_pixel_shader = upsample_pixel_shader,

        .sampler = sampler,

        .downsample_render_pass = downsample_render_pass,
        .downsample_pipeline = downsample_pipeline,
        .upsample_render_pass = upsample_render_pass,
        .upsample_pipeline = upsample_pipeline,

        .images_descriptor_layout = images_descriptor_layout,
        .images_descriptor_pool = images_descriptor_pool,

        .bloom_images = bloom_images,
        .bloom_layers = bloom_layers,

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

pub fn render_bloom(
    self: *const Self,
    cmd: *gf.CommandBuffer,
) !void {
    // Transition HDR image to shader resource
    transition_image_to_shader_read_only(cmd, gf.GfxState.get().default.hdr_image, 0, 1);

    // Downsample
    for (1..MIP_LEVELS) |mip_level| {
        const colour_attachment_index = mip_level % 2;
        const shader_index = (mip_level + 1) % 2;

        transition_image_to_colour_attachment(cmd, self.bloom_images.get(colour_attachment_index), mip_level, 1);
        transition_image_to_shader_read_only(cmd, self.bloom_images.get(shader_index), mip_level - 1, 1);

        cmd.cmd_begin_render_pass(.{
            .render_pass = self.downsample_render_pass,
            .framebuffer = self.bloom_layers.get(mip_level).downsample_framebuffers.get(colour_attachment_index),
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
                else self.bloom_layers.get(mip_level - 1).image_descriptor_sets.get(shader_index),
            },
        });

        var size = gf.GfxState.get().swapchain_size();
        size[0] >>= @intCast(mip_level - 1);
        size[1] >>= @intCast(mip_level - 1);

        const push_constants = PushConstantData {
            .mip_level = @floatFromInt(mip_level),
            .aspect_ratio = gf.GfxState.get().swapchain_aspect(),
            .filter_radius = 0.005,
            .src_texel_size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
            .blur_amount = 0.03,
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

        transition_image_to_shader_read_only(cmd, self.bloom_images.get(shader_index), mip_level, 1);
        transition_image_to_colour_attachment(cmd, self.bloom_images.get(colour_attachment_index), mip_level - 1, 1);

        cmd.cmd_begin_render_pass(.{
            .render_pass = self.upsample_render_pass,
            .framebuffer =  self.bloom_layers.get(mip_level - 1).upsample_framebuffers.get(colour_attachment_index),
            .render_area = .full_screen_pixels_mip(mip_level - 1),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.upsample_pipeline);
        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport_mip(mip_level - 1), }, });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels_mip(mip_level - 1), }, });

        cmd.cmd_bind_descriptor_sets(.{
            .graphics_pipeline = self.upsample_pipeline,
            .descriptor_sets = &.{
                self.bloom_layers.get(mip_level).image_descriptor_sets.get(shader_index),
            },
        });

        var size = gf.GfxState.get().swapchain_size();
        size[0] >>= @intCast(mip_level);
        size[1] >>= @intCast(mip_level);

        const push_constants = PushConstantData {
            .mip_level = @floatFromInt(mip_level),
            .aspect_ratio = gf.GfxState.get().swapchain_aspect(),
            .filter_radius = 0.005,
            .src_texel_size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
            .blur_amount = 0.03,
        };

        cmd.cmd_push_constants(.{
            .graphics_pipeline = self.upsample_pipeline,
            .shader_stages = .{ .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constants),
        });

        cmd.cmd_draw(.{ .vertex_count = 6, });
    }

    // TODO merge last bloom frame with hdr buffer. This was in tonemapping but should probs be 
    // moved here.

    // Perform final upscale merging into the hdr buffer
    {
    const mip_level = 1;
    const shader_index = mip_level % 2;
    const colour_attachment_index = (mip_level + 1) % 2;

    transition_image_to_shader_read_only(cmd, self.bloom_images.get(shader_index), mip_level, 1);
    transition_image_to_colour_attachment(cmd, self.bloom_images.get(colour_attachment_index), mip_level - 1, 1);

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
            self.bloom_layers.get(mip_level).image_descriptor_sets.get(shader_index),
        },
        });

    var size = gf.GfxState.get().swapchain_size();
    size[0] >>= @intCast(mip_level);
    size[1] >>= @intCast(mip_level);

    const push_constants = PushConstantData {
        .mip_level = @floatFromInt(mip_level),
        .aspect_ratio = gf.GfxState.get().swapchain_aspect(),
        .filter_radius = 0.005,
        .src_texel_size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
        .blur_amount = 0.03,
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

pub fn render_bloom_texture(
    self: *const Self,
    hdr_source_view: gf.ImageView.Ref,
    filter_radius: f32,
) void {
    const gfx = gf.GfxState.get();

    var hdr_source: gf.ImageView.Ref = hdr_source_view;
    var rtv: [MIP_LEVELS]gf.ImageView.Ref = self.bloom_mip_textures[0].rtv;

    // Downsample
    gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });
    gfx.cmd_set_vertex_shader(&self.full_screen_quad_vertex_shader);
    gfx.cmd_set_pixel_shader(&self.downsample_pixel_shader);
    gfx.cmd_set_samplers(.Pixel, 0, &.{self.sampler});
    gfx.cmd_set_constant_buffers(.Pixel, 0, &.{&self.constant_buffer});
    gfx.cmd_set_topology(.TriangleList);

    for (0..MIP_LEVELS) |mip_level| {
        const mip_level_minus_one = @max(@as(i32, @intCast(mip_level)) - 1, 0);
        {
            var mapped_buffer = self.constant_buffer.map(.{ .write = true, }) catch unreachable;
            defer mapped_buffer.unmap();

            const data = mapped_buffer.data(ConstantBufferData);
            const view_minus_one = rtv[mip_level_minus_one].get() catch unreachable;
            data.resolution_or_radius[0] = 1.0 / @as(f32, @floatFromInt(view_minus_one.size.width));
            data.resolution_or_radius[1] = 1.0 / @as(f32, @floatFromInt(view_minus_one.size.height));
            data.resolution_or_radius[2] = @floatFromInt(mip_level_minus_one);
        }

        const view = rtv[mip_level].get() catch unreachable;
        const viewport = gf.Viewport {
            .width = @floatFromInt(view.size.width),
            .height = @floatFromInt(view.size.height),
            .top_left_x = 0.0,
            .top_left_y = 0.0,
            .min_depth = 0.0,
            .max_depth = 0.0,
        };

        gfx.cmd_set_render_target(&.{rtv[mip_level]}, null);
        gfx.cmd_set_viewport(viewport);
        gfx.cmd_set_shader_resources(.Pixel, 0, &.{hdr_source});

        gfx.cmd_draw(6, 0);

        // unset hdr texture so it can be used as rtv again
        gfx.cmd_set_shader_resources(.Pixel, 0, &.{null});

        hdr_source = self.bloom_mip_textures[mip_level % 2].view;
        rtv = self.bloom_mip_textures[(mip_level + 1) % 2].rtv;
    }

    // Upsample
    gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });
    gfx.cmd_set_vertex_shader(&self.full_screen_quad_vertex_shader);
    gfx.cmd_set_pixel_shader(&self.upsample_pixel_shader);
    gfx.cmd_set_samplers(.Pixel, 0, &.{self.sampler});
    gfx.cmd_set_constant_buffers(.Pixel, 0, &.{&self.constant_buffer});
    gfx.cmd_set_topology(.TriangleList);

    for (1..MIP_LEVELS) |inv_mip_level| {
        const mip_level = MIP_LEVELS - inv_mip_level - 1;

        hdr_source = self.bloom_mip_textures[(mip_level + 1) % 2].view;
        rtv = self.bloom_mip_textures[mip_level % 2].rtv;

        const view = rtv[mip_level].get() catch unreachable;
        const viewport = gf.Viewport {
            .width = @floatFromInt(view.size.width),
            .height = @floatFromInt(view.size.height),
            .top_left_x = 0.0,
            .top_left_y = 0.0,
            .min_depth = 0.0,
            .max_depth = 0.0,
        };
        
        {
            var mapped_buffer = self.constant_buffer.map(.{ .write = true, }) catch unreachable;
            defer mapped_buffer.unmap();
            const data = mapped_buffer.data(ConstantBufferData);
            data.resolution_or_radius[0] = filter_radius;
            data.resolution_or_radius[1] = @floatFromInt(mip_level + 1);
            data.resolution_or_radius[2] = viewport.width / viewport.height;
        }

        gfx.cmd_set_render_target(&.{rtv[mip_level]}, null);
        gfx.cmd_set_viewport(viewport);
        gfx.cmd_set_shader_resources(.Pixel, 0, &.{hdr_source});

        gfx.cmd_draw(6, 0);

        // unset hdr texture so it can be used as rtv again
        gfx.cmd_set_shader_resources(.Pixel, 0, &.{null});
    }
}

const BloomLayer = struct {
    views: std.BoundedArray(gf.ImageView.Ref, 2),
    image_descriptor_sets: std.BoundedArray(gf.DescriptorSet.Ref, 2),

    downsample_framebuffers: std.BoundedArray(gf.FrameBuffer.Ref, 2),
    upsample_framebuffers: std.BoundedArray(gf.FrameBuffer.Ref, 2),

    pub fn deinit(self: *const BloomLayer) void {
        for (self.downsample_framebuffers.slice()) |*f| {
            f.deinit();
        }
        for (self.upsample_framebuffers.slice()) |*f| {
            f.deinit();
        }

        for (self.image_descriptor_sets.slice()) |*s| {
            s.deinit();
        }
        for (self.views.slice()) |*v| {
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

        var views = try std.BoundedArray(gf.ImageView.Ref, 2).init(0);
        errdefer for (views.slice()) |v| { v.deinit(); };

        var descriptor_sets = try std.BoundedArray(gf.DescriptorSet.Ref, 2).init(0);
        errdefer for (descriptor_sets.slice()) |s| { s.deinit(); };

        var downsample_framebuffers = try std.BoundedArray(gf.FrameBuffer.Ref, 2).init(0);
        errdefer for (downsample_framebuffers.slice()) |f| { f.deinit(); };

        var upsample_framebuffers = try std.BoundedArray(gf.FrameBuffer.Ref, 2).init(0);
        errdefer for (upsample_framebuffers.slice()) |f| { f.deinit(); };

        for (0..2) |i| {
            const view = try gf.ImageView.init(.{
                .image = images[i],
                .base_mip_level = @intCast(mip_level),
                .mip_level_count = 1,
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

            try views.append(view);
            try descriptor_sets.append(set);
            try downsample_framebuffers.append(downsample_framebuffer);
            try upsample_framebuffers.append(upsample_framebuffer);
        }

        return BloomLayer {
            .views = views,
            .image_descriptor_sets = descriptor_sets,

            .downsample_framebuffers = downsample_framebuffers,
            .upsample_framebuffers = upsample_framebuffers,
        };
    }
};

