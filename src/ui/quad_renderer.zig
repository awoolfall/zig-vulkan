const std = @import("std");
const zm = @import("zmath");
const engine = @import("../root.zig");
const _gfx = engine.gfx;
const ui = @import("ui.zig");
const RectPixels = @import("../root.zig").Rect;

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

pub const QuadRenderer = struct {
    const MAX_QUADS = 500;

    sampler: _gfx.Sampler.Ref,

    vertex_shader: _gfx.VertexShader,
    pixel_shader: _gfx.PixelShader,

    quad_buffer_vertex: _gfx.Buffer.Ref,
    quad_buffer_pixel: _gfx.Buffer.Ref,

    render_pass: _gfx.RenderPass.Ref,
    pipeline: _gfx.GraphicsPipeline.Ref,
    framebuffer: _gfx.FrameBuffer.Ref,

    descriptor_layout: _gfx.DescriptorLayout.Ref,
    descriptor_pool: _gfx.DescriptorPool.Ref,
    descriptor_sets: std.ArrayList(_gfx.DescriptorSet.Ref),

    frame_quads: std.ArrayList(QuadProperties),

    const QUAD_SHADER_HLSL = @embedFile("quad_shader.slang");

    pub fn deinit(self: *QuadRenderer) void {
        defer self.sampler.deinit();

        defer self.vertex_shader.deinit();
        defer self.pixel_shader.deinit();

        defer self.quad_buffer_vertex.deinit();
        defer self.quad_buffer_pixel.deinit();

        defer self.render_pass.deinit();
        defer self.pipeline.deinit();
        defer self.framebuffer.deinit();

        defer self.descriptor_layout.deinit();
        defer self.descriptor_pool.deinit();
        defer {
            for (self.descriptor_sets.items) |s| {
                s.deinit();
            }
            self.descriptor_sets.deinit();
        }

        defer self.frame_quads.deinit();
    }

    pub fn init() !QuadRenderer {
        // create the quad shaders
        const vertex_shader = try _gfx.VertexShader.init_buffer(
            QUAD_SHADER_HLSL,
            "vs_main",
            .{ .bindings = &.{}, .attributes = &.{}, },
            .{},
        );
        errdefer vertex_shader.deinit();

        const pixel_shader = try _gfx.PixelShader.init_buffer(
            QUAD_SHADER_HLSL,
            "ps_main",
            .{},
        );
        errdefer pixel_shader.deinit();

        // create quad constant buffers
        const buffer_vertex = try _gfx.Buffer.init(
            @sizeOf(QuadBufferVertexBuffer) * MAX_QUADS,
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer buffer_vertex.deinit();

        const buffer_pixel = try _gfx.Buffer.init(
            @sizeOf(QuadBufferPixelBuffer) * MAX_QUADS,
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer buffer_pixel.deinit();

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
                .load_op = .Clear,
                .clear_value = zm.f32x4(0.7, 0.0, 0.7, 1.0),
                .initial_layout = .Undefined,
                .final_layout = .ColorAttachmentOptimal,
            },
            _gfx.AttachmentInfo {
                .name = "depth",
                .format = _gfx.GfxState.depth_format,
                .load_op = .Clear,
                .stencil_load_op = .Clear,
                .initial_layout = .Undefined,
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

        const descriptor_layout = try _gfx.DescriptorLayout.init(.{
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
        errdefer descriptor_layout.deinit();

        const graphics_pipeline = try _gfx.GraphicsPipeline.init(.{
            .vertex_shader = &vertex_shader,
            .pixel_shader = &pixel_shader,
            .attachments = attachments,
            .cull_mode = .CullNone, // TODO
            .descriptor_set_layouts = &.{
                descriptor_layout               
            },
            .push_constants = &.{
                _gfx.PushConstantLayoutInfo {
                    .shader_stages = .{ .Vertex = true, .Pixel = true, },
                    .size = 4,
                    .offset = 0,
                },
            },
            .depth_test = .{ .write = true, },
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

        const descriptor_pool = try _gfx.DescriptorPool.init(.{ .max_sets = 16, .strategy = .{ .Layout = descriptor_layout, } });
        errdefer descriptor_pool.deinit();

        var descriptor_sets = std.ArrayList(_gfx.DescriptorSet.Ref).init(engine.get().general_allocator);
        errdefer descriptor_sets.deinit();
        const new_sets = try (try descriptor_pool.get()).allocate_sets(
            engine.get().frame_allocator,
            .{ .layout = descriptor_layout, },
            2
        );
        defer engine.get().frame_allocator.free(new_sets);
        errdefer {
            for (new_sets) |s| { s.deinit(); }
        }
        try descriptor_sets.appendSlice(new_sets);

        for (new_sets) |s| {
            const set = s.get() catch unreachable;
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

        const frame_quads_list = try std.ArrayList(QuadProperties).initCapacity(engine.get().general_allocator, 128);
        errdefer frame_quads_list.deinit();

        return QuadRenderer {
            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,

            .quad_buffer_vertex = buffer_vertex,
            .quad_buffer_pixel = buffer_pixel,
            .sampler = sampler,

            .render_pass = render_pass,
            .pipeline = graphics_pipeline,
            .framebuffer = framebuffer,

            .descriptor_layout = descriptor_layout,
            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,

            .frame_quads = frame_quads_list,
        };
    }

    pub const QuadPropertiesTexture = struct {
        texture_view: _gfx.ImageView.Ref,
        sampler: _gfx.Sampler.Ref,
    };

    pub const QuadProperties = struct {
        rect: RectPixels,
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
        // TODO expand with more buffers if we exceed limit
        if (self.frame_quads.items.len < QuadRenderer.MAX_QUADS) {
            try self.frame_quads.append(props);
        }
    }

    pub fn render_quads(
        self: *QuadRenderer,
        cmd: *_gfx.CommandBuffer,
    ) !void {
        defer self.frame_quads.clearRetainingCapacity();

        // Fill buffers
        { 
            const buffer_vertex = self.quad_buffer_vertex.get() catch unreachable;
            const mapped_vertex = buffer_vertex.map(.{ .write = true, }) catch unreachable;
            defer mapped_vertex.unmap();
            const vertex_data_array = mapped_vertex.data_array(QuadBufferVertexBuffer, QuadRenderer.MAX_QUADS);

            const buffer_pixel = self.quad_buffer_pixel.get() catch unreachable;
            const mapped_pixel = buffer_pixel.map(.{ .write = true, }) catch unreachable;
            defer mapped_pixel.unmap();
            const pixel_data_array = mapped_pixel.data_array(QuadBufferPixelBuffer, QuadRenderer.MAX_QUADS);

            const size = _gfx.GfxState.get().swapchain_size();

            for (self.frame_quads.items, 0..) |q, idx| {
                vertex_data_array[idx] = QuadBufferVertexBuffer {
                    .quad_bounds = Bounds.from_rect(q.rect, @floatFromInt(size[0]), @floatFromInt(size[1])),
                };

                pixel_data_array[idx] = QuadBufferPixelBuffer {
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
            }
        }

        // Render commands
        cmd.cmd_begin_render_pass(_gfx.CommandBuffer.BeginRenderPassInfo {
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffer,
            .render_area = .{
                .left = 0.0,
                .top = 0.0,
                .right = @floatFromInt(_gfx.GfxState.get().swapchain_size()[0]),
                .bottom = @floatFromInt(_gfx.GfxState.get().swapchain_size()[1]),
            },
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.pipeline);

        const swapchain_size = _gfx.GfxState.get().swapchain_size();
        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport() }, });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .{ .left = 0.0, .top = 0.0, .right = @floatFromInt(swapchain_size[0]), .bottom = @floatFromInt(swapchain_size[1]), }, }, } );

        for (self.frame_quads.items, 0..) |_, idx| {
            // TODO update quad image if required
            // todo? seperate image/non-image so we can draw all non-image using instancing
            cmd.cmd_bind_descriptor_sets(_gfx.CommandBuffer.BindDescriptorSetInfo {
                .graphics_pipeline = self.pipeline,
                .descriptor_sets = &.{ self.descriptor_sets.items[0], },
            });

            // push constant the index
            cmd.cmd_push_constants(_gfx.CommandBuffer.PushConstantsInfo {
                .graphics_pipeline = self.pipeline,
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .size = 4,
                .offset = 0,
                .data = std.mem.sliceAsBytes(([_]u32{ @as(u32, @intCast(idx)) })[0..]),
            });

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

