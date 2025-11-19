const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const _gfx = eng.gfx;
const ui = eng.ui;
const RectPixels = eng.Rect;

pub const RectEdges = packed struct {
    left: f32 = 0.0,
    right: f32 = 0.0,
    bottom: f32 = 0.0,
    top: f32 = 0.0,

    pub inline fn all(value: f32) RectEdges {
        return RectEdges { .left = value, .right = value, .top = value, .bottom = value, };
    }

    pub inline fn lr_tb(left_right: f32, top_bottom: f32) RectEdges {
        return RectEdges { .left = left_right, .right = left_right, .top = top_bottom, .bottom = top_bottom, };
    }

    pub inline fn from_rect_pixels(rp: RectPixels) RectEdges {
        return .{ 
            .left = @floatCast(rp.left),
            .right = @floatCast(rp.right),
            .top = @floatCast(rp.top),
            .bottom = @floatCast(rp.bottom),
        };
    }
};

pub const CornerRadiiPx = packed struct {
    bottom_left: f32 = 0.0,
    bottom_right: f32 = 0.0,
    top_left: f32 = 0.0,
    top_right: f32 = 0.0,

    pub inline fn all(value: f32) CornerRadiiPx {
        return .{ .top_left = value, .top_right = value, .bottom_left = value, .bottom_right = value, };
    }
};


// -1.0 to 1.0, left and bottom of screen is -1.0, right and top is 1.0
pub const Bounds = extern struct {
    left: f32 = 0.0,
    bottom: f32 = 0.0,
    right: f32 = 0.0,
    top: f32 = 0.0,

    pub fn from_rect(rect: RectPixels, max_width: f32, max_height: f32) Bounds {
        const top_left = ui.position_pixels_to_screen_space(rect.left, rect.top, max_width, max_height);
        const bottom_right = ui.position_pixels_to_screen_space(rect.right, rect.bottom, max_width, max_height);
        return Bounds {
            .left = top_left[0],
            .top = top_left[1],
            .right = bottom_right[0],
            .bottom = bottom_right[1],
        };
    }
};

pub const QuadBufferPixelBuffer = packed struct {
    bg_colour: zm.F32x4,
    border_colour: zm.F32x4,

    corner_radii: CornerRadiiPx,
    border_width_px: RectEdges,

    quad_width_pixels: f32,
    quad_height_pixels: f32,
    flags: u32,
    __padding0: u32 = 0,
};

pub const QuadBufferVertexBuffer = extern struct {
    quad_bounds: Bounds = Bounds {},
};

pub const QuadBufferFlags = packed struct(u32) {
    has_texture: bool = false,
    __unused: u31 = 0,
};

pub const PushConstants = extern struct {
    index: u32,
    z_value: f32,
};

const QuadRenderSet = struct {
    buffer_vertex: _gfx.Buffer.Ref,
    buffer_pixel: _gfx.Buffer.Ref,

    buffers_descriptor_pool: _gfx.DescriptorPool.Ref,
    buffers_descriptor_set: _gfx.DescriptorSet.Ref,

    images_descriptor_pool: _gfx.DescriptorPool.Ref,
    default_images_set: _gfx.DescriptorSet.Ref,
    image_descriptor_sets: std.ArrayList(_gfx.DescriptorSet.Ref),

    pub fn deinit(self: *QuadRenderSet) void {
        self.buffers_descriptor_set.deinit();
        self.buffers_descriptor_pool.deinit();

        self.default_images_set.deinit();
        for (self.image_descriptor_sets.items) |s| { s.deinit(); }
        self.image_descriptor_sets.deinit(eng.get().general_allocator);
        self.images_descriptor_pool.deinit();

        self.buffer_vertex.deinit();
        self.buffer_pixel.deinit();
    }
};

pub const QuadRenderer = struct {
    const MAX_QUADS_PER_BUFFER = 500;

    alloc: std.mem.Allocator,

    sampler: _gfx.Sampler.Ref,

    render_pass: _gfx.RenderPass.Ref,
    pipeline: _gfx.GraphicsPipeline.Ref,
    framebuffer: _gfx.FrameBuffer.Ref,

    buffers_descriptor_layout: _gfx.DescriptorLayout.Ref,
    image_descriptor_layout: _gfx.DescriptorLayout.Ref,

    frame_quads: std.ArrayList(QuadProperties),

    quad_render_sets: std.ArrayList(QuadRenderSet),

    pub fn deinit(self: *QuadRenderer) void {
        defer self.sampler.deinit();

        defer self.render_pass.deinit();
        defer self.pipeline.deinit();
        defer self.framebuffer.deinit();

        defer self.buffers_descriptor_layout.deinit();
        defer self.image_descriptor_layout.deinit();

        defer self.frame_quads.deinit(self.alloc);

        defer self.quad_render_sets.deinit(self.alloc);
        defer for (self.quad_render_sets.items) |*s| { s.deinit(); };
    }

    pub fn init(alloc: std.mem.Allocator) !QuadRenderer {
        // create the quad shaders
        const spirv_shader = try _gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
            .shader_data = @embedFile("quad_shader.slang"),
            .shader_entry_points = &.{
                "vs_main",
                "ps_main",
            }
        });
        defer alloc.free(spirv_shader);

        const shader_module = try _gfx.ShaderModule.init(.{ .spirv_data = spirv_shader, });
        defer shader_module.deinit();

        const vertex_input = try _gfx.VertexInput.init(.{
            .bindings = &.{},
            .attributes = &.{},
        });
        defer vertex_input.deinit();

        // create sampler
        const sampler = try _gfx.Sampler.init(
            .{
                .filter_min_mag = .Linear,
                .filter_mip = .Point,
                .border_mode = .Wrap,
            },
        );
        errdefer sampler.deinit();

        const attachments = &[_]_gfx.AttachmentInfo {
            _gfx.AttachmentInfo {
                .name = "colour",
                .format = _gfx.GfxState.ldr_format,
                .initial_layout = .ColorAttachmentOptimal,
                .final_layout = .ColorAttachmentOptimal,
                .blend_type = .PremultipliedAlpha,
            },
            _gfx.AttachmentInfo {
                .name = "depth",
                .format = _gfx.GfxState.depth_format,
                .load_op = .Clear,
                .stencil_load_op = .Clear,
                .initial_layout = .DepthStencilAttachmentOptimal,
                .final_layout = .DepthStencilAttachmentOptimal,
            },
        };

        const render_pass = try _gfx.RenderPass.init(.{
            .attachments = attachments,
            .subpasses = &[_]_gfx.SubpassInfo {
                .{
                    .attachments = &.{ "colour" },
                    .depth_attachment = "depth",
                },
            },
            .dependencies = &.{
                _gfx.SubpassDependencyInfo {
                    .src_subpass = null,
                    .dst_subpass = 0,
                    .src_stage_mask = .{ .color_attachment_output = true, },
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .color_attachment_output = true, },
                    .dst_access_mask = .{ .color_attachment_write = true, },
                },
            },
        });
        errdefer render_pass.deinit();

        const buffers_descriptor_layout = try _gfx.DescriptorLayout.init(.{
            .bindings = &[_]_gfx.DescriptorBindingInfo {
                _gfx.DescriptorBindingInfo {
                    .binding = 0,
                    .binding_type = .UniformBuffer,
                    .shader_stages = .{ .Vertex = true, },
                },
                _gfx.DescriptorBindingInfo {
                    .binding = 1,
                    .binding_type = .UniformBuffer,
                    .shader_stages = .{ .Pixel = true, },
                },
            },
        });
        errdefer buffers_descriptor_layout.deinit();

        const image_descriptor_layout = try _gfx.DescriptorLayout.init(.{
            .bindings = &.{
                _gfx.DescriptorBindingInfo {
                    .binding = 0,
                    .binding_type = .ImageView,
                    .shader_stages = .{ .Pixel = true, },
                },
                _gfx.DescriptorBindingInfo {
                    .binding = 1,
                    .binding_type = .Sampler,
                    .shader_stages = .{ .Pixel = true, },
                }
            },
        });

        const graphics_pipeline = try _gfx.GraphicsPipeline.init(.{
            .vertex_shader = .{
                .module = &shader_module,
                .entry_point = "vs_main",
            },
            .vertex_input = &vertex_input,
            .pixel_shader = .{
                .module = &shader_module,
                .entry_point = "ps_main",
            },
            .cull_mode = .CullNone, // TODO
            .descriptor_set_layouts = &.{
                buffers_descriptor_layout,
                image_descriptor_layout,
            },
            .push_constants = &.{
                _gfx.PushConstantLayoutInfo {
                    .shader_stages = .{ .Vertex = true, .Pixel = true, },
                    .size = @sizeOf(PushConstants),
                    .offset = 0,
                },
            },
            .depth_test = .{ .write = true, }, //.compare_op = .Always, },
            .render_pass = render_pass,
            .subpass_index = 0,
        });
        errdefer graphics_pipeline.deinit();

        const framebuffer = try _gfx.FrameBuffer.init(.{
            .render_pass = render_pass,
            .attachments = &.{
                .SwapchainLDR,
                .SwapchainDepth,
            },
        });
        errdefer framebuffer.deinit();

        const frame_quads_list = try std.ArrayList(QuadProperties).initCapacity(alloc, 128);
        errdefer frame_quads_list.deinit();

        const quad_render_sets = std.ArrayList(QuadRenderSet).empty;
        errdefer quad_render_sets.deinit();

        return QuadRenderer {
            .alloc = alloc,

            .sampler = sampler,

            .render_pass = render_pass,
            .pipeline = graphics_pipeline,
            .framebuffer = framebuffer,

            .buffers_descriptor_layout = buffers_descriptor_layout,
            .image_descriptor_layout = image_descriptor_layout,

            .frame_quads = frame_quads_list,
            .quad_render_sets = quad_render_sets,
        };
    }

    fn create_new_sets_for_rendering(self: *QuadRenderer) !void {
        while (@divFloor(self.frame_quads.items.len, QuadRenderer.MAX_QUADS_PER_BUFFER) + 1 > self.quad_render_sets.items.len) {
            const buffer_vertex = _gfx.Buffer.init(
                @sizeOf(QuadBufferVertexBuffer) * MAX_QUADS_PER_BUFFER,
                .{ .ConstantBuffer = true, },
                .{ .CpuWrite = true, },
            ) catch |err| {
                std.log.warn("failed to create new quad renderer constant buffer: {}", .{err});
                return err;
            };
            errdefer buffer_vertex.deinit();

            const buffer_pixel = _gfx.Buffer.init(
                @sizeOf(QuadBufferPixelBuffer) * MAX_QUADS_PER_BUFFER,
                .{ .ConstantBuffer = true, },
                .{ .CpuWrite = true, },
            ) catch |err| {
                std.log.warn("failed to create new quad renderer constant buffer: {}", .{err});
                return err;
            };
            errdefer buffer_pixel.deinit();

            const buffers_descriptor_pool = try _gfx.DescriptorPool.init(.{
                .max_sets = 1,
                .strategy = .{ .Layout = self.buffers_descriptor_layout, },
            });
            errdefer buffers_descriptor_pool.deinit();

            const images_descriptor_pool = try _gfx.DescriptorPool.init(.{
                .max_sets = QuadRenderer.MAX_QUADS_PER_BUFFER + 1,
                .strategy = .{ .Layout = self.image_descriptor_layout, },
            });
            errdefer images_descriptor_pool.deinit();

            const buffers_descriptor_sets = try (buffers_descriptor_pool.get() catch unreachable).allocate_sets(
                eng.get().frame_allocator,
                .{ .layout = self.buffers_descriptor_layout, },
                1,
            );
            defer eng.get().frame_allocator.free(buffers_descriptor_sets);

            const buffers_descriptor_set = buffers_descriptor_sets[0];
            errdefer buffers_descriptor_set.deinit();

            {
                const set = buffers_descriptor_set.get() catch unreachable;
                set.update(.{
                    .writes = &.{
                        .{
                            .binding = 0,
                            .data = .{ .UniformBuffer = .{
                                .buffer = buffer_vertex,
                            } },
                        },
                        .{
                            .binding = 1,
                            .data = .{ .UniformBuffer = .{
                                .buffer = buffer_pixel,
                            } },
                        },
                        },
                    }) catch |err| {
                    std.log.warn("Unable to update set: {}", .{err});
                };
            }

            const new_image_sets = try (images_descriptor_pool.get() catch unreachable).allocate_sets(
                eng.get().frame_allocator,
                .{ .layout = self.image_descriptor_layout, },
                QuadRenderer.MAX_QUADS_PER_BUFFER + 1
            );
            defer eng.get().frame_allocator.free(new_image_sets);
            errdefer for (new_image_sets) |s| { s.deinit(); };

            const default_images_set = new_image_sets[0];
            (default_images_set.get() catch unreachable).update(.{
                .writes = &.{
                    .{
                        .binding = 0,
                        .data = .{ .ImageView = _gfx.GfxState.get().default.diffuse_view, },
                    },
                    .{
                        .binding = 1,
                        .data = .{ .Sampler = _gfx.GfxState.get().default.sampler, },
                    },
                },
            }) catch |err| {
                std.log.warn("Unable to update set: {}", .{err});
            };

            var images_descriptor_sets = std.ArrayList(_gfx.DescriptorSet.Ref).empty;
            errdefer images_descriptor_sets.deinit(self.alloc);

            try images_descriptor_sets.appendSlice(self.alloc, new_image_sets[1..]);

            try self.quad_render_sets.append(self.alloc, QuadRenderSet {
                .buffer_vertex = buffer_vertex,
                .buffer_pixel = buffer_pixel,
                .buffers_descriptor_set = buffers_descriptor_set,
                .buffers_descriptor_pool = buffers_descriptor_pool,
                .image_descriptor_sets = images_descriptor_sets,
                .default_images_set = default_images_set,
                .images_descriptor_pool = images_descriptor_pool,
            });
        }
    }

    pub const QuadPropertiesTexture = struct {
        texture_view: _gfx.ImageView.Ref,
        sampler: _gfx.Sampler.Ref,
    };

    pub const QuadProperties = struct {
        rect: RectPixels,
        z_value: f32,
        scissor: ?RectPixels = null,
        colour: zm.F32x4 = zm.f32x4(0.0, 0.0, 0.0, 1.0),
        border_colour: zm.F32x4 = zm.f32x4s(0.0),
        border_width_px: RectEdges = .{},
        corner_radii_px: CornerRadiiPx = .{},
        texture: ?QuadPropertiesTexture = null,
        wireframe: bool = false,
    };

    pub fn submit_quad(
        self: *QuadRenderer,
        props: QuadProperties,
    ) !void {
        try self.frame_quads.append(self.alloc, props);
    }

    pub fn render_quads(
        self: *QuadRenderer,
        cmd: *_gfx.CommandBuffer,
    ) !void {
        defer self.frame_quads.clearRetainingCapacity();

        self.create_new_sets_for_rendering() catch |err| {
            std.log.err("Failed to create new quad rendering sets: {}", .{err});
            self.frame_quads.shrinkRetainingCapacity(self.quad_render_sets.items.len * QuadRenderer.MAX_QUADS_PER_BUFFER);
        };

        // Fill buffers
        for (self.quad_render_sets.items, 0..) |render_set, idx| { 
            if (QuadRenderer.MAX_QUADS_PER_BUFFER * idx >= self.frame_quads.items.len) {
                break;
            }

            const buffer_vertex = render_set.buffer_vertex.get() catch unreachable;
            const mapped_vertex = buffer_vertex.map(.{ .write = .EveryFrame, }) catch unreachable;
            defer mapped_vertex.unmap();
            const vertex_data_array = mapped_vertex.data_array(QuadBufferVertexBuffer, QuadRenderer.MAX_QUADS_PER_BUFFER);

            const buffer_pixel = render_set.buffer_pixel.get() catch unreachable;
            const mapped_pixel = buffer_pixel.map(.{ .write = .EveryFrame, }) catch unreachable;
            defer mapped_pixel.unmap();
            const pixel_data_array = mapped_pixel.data_array(QuadBufferPixelBuffer, QuadRenderer.MAX_QUADS_PER_BUFFER);

            const size = _gfx.GfxState.get().swapchain_size();

            const quad_chunk_start = idx * QuadRenderer.MAX_QUADS_PER_BUFFER;
            const quad_chunk_end = @min(quad_chunk_start + QuadRenderer.MAX_QUADS_PER_BUFFER, self.frame_quads.items.len);

            for (self.frame_quads.items[quad_chunk_start..quad_chunk_end], 0..) |q, q_idx| {
                vertex_data_array[q_idx] = QuadBufferVertexBuffer {
                    .quad_bounds = Bounds.from_rect(q.rect, @floatFromInt(size[0]), @floatFromInt(size[1])),
                };

                pixel_data_array[q_idx] = QuadBufferPixelBuffer {
                    .bg_colour = q.colour,
                    .border_colour = q.border_colour,
                    .border_width_px = q.border_width_px,
                    .quad_width_pixels = q.rect.width(),
                    .quad_height_pixels = q.rect.height(),
                    .corner_radii = q.corner_radii_px,
                    .flags = @bitCast(QuadBufferFlags{
                        .has_texture = (q.texture != null),
                    }),
                };

                if (q.texture) |image| {
                    // TODO only update if needed
                    const image_set: *_gfx.DescriptorSet = render_set.image_descriptor_sets.items[q_idx].get() catch unreachable;
                    image_set.update(.{
                        .writes = &.{
                            .{
                                .binding = 0,
                                .data = .{ .ImageView = image.texture_view, },
                            },
                            .{
                                .binding = 1,
                                .data = .{ .Sampler = _gfx.GfxState.get().default.sampler, },
                            }
                        },
                    }) catch |err| {
                        std.log.warn("Unable to update quad image set: {}", .{err});
                    };
                }
            }
        }

        // Render commands
        cmd.cmd_begin_render_pass(_gfx.CommandBuffer.BeginRenderPassInfo {
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffer,
            .render_area = .full_screen_pixels(),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.pipeline);

        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport() }, });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels(), }, } );

        for (self.frame_quads.items, 0..) |q, idx| {
            const render_set: usize = @divFloor(idx, QuadRenderer.MAX_QUADS_PER_BUFFER);
            const q_idx: usize = @mod(idx, QuadRenderer.MAX_QUADS_PER_BUFFER);

            cmd.cmd_set_scissors(.{ .scissors = &.{ q.scissor orelse .full_screen_pixels() } });

            // TODO update quad image if required
            cmd.cmd_bind_descriptor_sets(_gfx.CommandBuffer.BindDescriptorSetInfo {
                .graphics_pipeline = self.pipeline,
                .descriptor_sets = &.{
                    self.quad_render_sets.items[render_set].buffers_descriptor_set,
                    if (q.texture) |_| self.quad_render_sets.items[render_set].image_descriptor_sets.items[q_idx]
                    else self.quad_render_sets.items[render_set].default_images_set,
                },
            });

            const push_constants = PushConstants {
                .index = @intCast(idx),
                .z_value = q.z_value,
            };

            // push constant the index
            cmd.cmd_push_constants(_gfx.CommandBuffer.PushConstantsInfo {
                .graphics_pipeline = self.pipeline,
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .offset = 0,
                .data = std.mem.asBytes(&push_constants),
            });

            // TODO instancing
            cmd.cmd_draw(.{
                .vertex_count = 6,
            });
        }
    }

    pub fn render_quad(
        self: *QuadRenderer,
        rect_pixels: RectPixels,
        props: QuadProperties,
        rtv: _gfx.ImageView.Ref, 
    ) void {
        const gfx = _gfx.GfxState.get();

        { // Setup quad vertex info buffer
            const mapped_buffer = self.quad_buffer_vertex.map(.{ .write = true, }) catch unreachable;
            defer mapped_buffer.unmap();

            const view = rtv.get() catch unreachable;
            mapped_buffer.data(QuadBufferVertexBuffer).* = QuadBufferVertexBuffer {
                .quad_bounds = Bounds.from_rect(rect_pixels, @floatFromInt(view.size.width), @floatFromInt(view.size.height)),
            };
        }
        { // Setup quad pixel info buffer
            const mapped_buffer = self.quad_buffer_pixel.map(.{ .write = true, }) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data(QuadBufferPixelBuffer).* = QuadBufferPixelBuffer {
                .bg_colour = props.colour,
                .border_colour = props.border_colour,
                .border_width_px = props.border_width_px,
                .quad_width_pixels = rect_pixels.width(),
                .quad_height_pixels = rect_pixels.height(),
                .corner_radii = props.corner_radii_px,
                .flags = @bitCast(QuadBufferFlags{
                    .has_texture = (props.texture != null),
                }),
            };
        }

        const view = rtv.get() catch unreachable;
        const viewport = _gfx.Viewport {
            .width = @floatFromInt(view.size.width),
            .height = @floatFromInt(view.size.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
            .top_left_x = 0,
            .top_left_y = 0,
        };
        gfx.cmd_set_viewport(viewport);

        gfx.cmd_set_pixel_shader(&self.quad_pso);

        gfx.cmd_set_render_target(&.{rtv}, null);

        gfx.cmd_set_vertex_shader(&self.quad_vso);

        gfx.cmd_set_topology(.TriangleList);
        if (props.wireframe) {
            @branchHint(.unlikely);
            gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FillFront = false, .FrontCounterClockwise = true, });
        } else {
            @branchHint(.likely);
            gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });
        }

        gfx.cmd_set_constant_buffers(.Vertex, 0, &.{&self.quad_buffer_vertex});
        gfx.cmd_set_constant_buffers(.Pixel, 1, &.{&self.quad_buffer_pixel});

        if (props.texture) |texture_props| {
            gfx.cmd_set_samplers(.Pixel, 0, &.{texture_props.sampler});
            gfx.cmd_set_shader_resources(.Pixel, 0, &.{texture_props.texture_view});
        } else {
            gfx.cmd_set_samplers(.Pixel, 0, &.{gfx.default.sampler});
            gfx.cmd_set_shader_resources(.Pixel, 0, &.{gfx.default.diffuse_view});
        }

        gfx.cmd_draw(6, 0);
    }
};

