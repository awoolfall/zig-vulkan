const std = @import("std");
const zm = @import("zmath");
const gfx = @import("../gfx/gfx.zig");
const Camera = @import("../engine/camera.zig").Camera;
const engine = @import("../engine.zig");

pub const Debug = struct {
    const Self = @This();
    const MAX_LINES = 1024;

    const LineDetails = extern struct {
        start_point: zm.F32x4,
        end_point: zm.F32x4,
        colour: zm.F32x4,
    };
    
    const CameraData = extern struct {
        view: zm.Mat,
        projection: zm.Mat,
    };

    render_pass: gfx.RenderPass.Ref,
    lines_pipeline: gfx.GraphicsPipeline.Ref,
    framebuffer: gfx.FrameBuffer.Ref,

    lines: std.BoundedArray(DebugLine, MAX_LINES),
    lines_vertex_shader: gfx.VertexShader,
    lines_pixel_shader: gfx.PixelShader,
    lines_instance_buffer: gfx.Buffer.Ref,

    camera_buffer: gfx.Buffer.Ref,
    camera_descriptor_layout: gfx.DescriptorLayout.Ref,
    camera_descriptor_pool: gfx.DescriptorPool.Ref,
    camera_descriptor_set: gfx.DescriptorSet.Ref,

    pub fn deinit(self: *Self) void {
        self.framebuffer.deinit();
        self.lines_pipeline.deinit();
        self.render_pass.deinit();

        self.lines_vertex_shader.deinit();
        self.lines_pixel_shader.deinit();
        self.lines_instance_buffer.deinit();

        self.camera_descriptor_set.deinit();
        self.camera_descriptor_pool.deinit();
        self.camera_descriptor_layout.deinit();
        self.camera_buffer.deinit();
    }

    pub fn init(allocator: std.mem.Allocator) !Self {
        _ = allocator;

        const lines_vertex_shader = try gfx.VertexShader.init_buffer(
            LINES_HLSL,
            "vs_main",
            .{
                .bindings = &.{
                    .{ .binding = 0, .stride = 3 * @sizeOf([4]f32), .input_rate = .Instance, },
                },
                .attributes = &.{
                    .{ .name = "TEXCOORD0", .location = 0, .binding = 0, .offset = 0 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "TEXCOORD1", .location = 1, .binding = 0, .offset = 1 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "COLOR",     .location = 2, .binding = 0, .offset = 2 * @sizeOf([4]f32), .format = .F32x4, },
                },
            },
            .{},
        );
        errdefer lines_vertex_shader.deinit();

        const lines_pixel_shader = try gfx.PixelShader.init_buffer(
            LINES_HLSL,
            "ps_main",
            .{},
        );
        errdefer lines_pixel_shader.deinit();

        const lines_instance_buffer = try gfx.Buffer.init(
            @sizeOf(LineDetails) * MAX_LINES,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer lines_instance_buffer.deinit();

        const camera_buffer = try gfx.Buffer.init(
            @sizeOf(CameraData),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer camera_buffer.deinit();

        const camera_descriptor_layout = try gfx.DescriptorLayout.init(.{
            .bindings = &.{
                gfx.DescriptorBindingInfo {
                    .binding = 0,
                    .shader_stages = .{ .Vertex = true, },
                    .binding_type = .UniformBuffer,
                },
            },
        });
        errdefer camera_descriptor_layout.deinit();

        const camera_descriptor_pool = try gfx.DescriptorPool.init(.{
            .max_sets = 1,
            .strategy = .{ .Layout = camera_descriptor_layout, },
        });
        errdefer camera_descriptor_pool.deinit();

        const camera_descriptor_set = try (try camera_descriptor_pool.get()).allocate_set(gfx.DescriptorSetInfo {
            .layout = camera_descriptor_layout,
        });
        errdefer camera_descriptor_set.deinit();

        try (try camera_descriptor_set.get()).update(.{
            .writes = &.{
                gfx.DescriptorSetUpdateWriteInfo {
                    .binding = 0,
                    .data = .{ .UniformBuffer = .{
                        .buffer = camera_buffer,
                    } },
                },
            },
        });

        const attachments = &[_]gfx.AttachmentInfo {
            gfx.AttachmentInfo {
                .name = "colour",
                .format = gfx.GfxState.ldr_format,
                .initial_layout = .ColorAttachmentOptimal,
                .final_layout = .ColorAttachmentOptimal,
            },
            gfx.AttachmentInfo {
                .name = "depth",
                .format = gfx.GfxState.depth_format,
                .initial_layout = .Undefined,
                .final_layout = .DepthStencilAttachmentOptimal,
                .load_op = .Clear,
                .stencil_load_op = .Clear,
            },
        };

        const render_pass = try gfx.RenderPass.init(.{
            .attachments = attachments,
            .subpasses = &.{
                gfx.SubpassInfo {
                    .attachments = &.{ "colour" },
                    .depth_attachment = "depth",
                },
            },
            .dependencies = &.{
                gfx.SubpassDependencyInfo {
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

        const lines_pipeline = try gfx.GraphicsPipeline.init(.{
            .render_pass = render_pass,
            .attachments = attachments,
            .vertex_shader = &lines_vertex_shader,
            .pixel_shader = &lines_pixel_shader,
            .cull_mode = .CullNone,
            .depth_test = .{ .write = true, },
            .descriptor_set_layouts = &.{
                camera_descriptor_layout,
            },
        });
        errdefer lines_pipeline.deinit();

        const framebuffer = try gfx.FrameBuffer.init(.{
            .render_pass = render_pass,
            .attachments = &.{
                .SwapchainLDR,
                .SwapchainDepth,
            },
        });
        errdefer framebuffer.deinit();

        return Self{
            .lines = try std.BoundedArray(DebugLine, MAX_LINES).init(0),
            .lines_vertex_shader = lines_vertex_shader,
            .lines_pixel_shader = lines_pixel_shader,
            .lines_instance_buffer = lines_instance_buffer,
            
            .render_pass = render_pass,
            .lines_pipeline = lines_pipeline,
            .framebuffer = framebuffer,

            .camera_buffer = camera_buffer,
            .camera_descriptor_layout = camera_descriptor_layout,
            .camera_descriptor_pool = camera_descriptor_pool,
            .camera_descriptor_set = camera_descriptor_set,
        };
    }

    pub fn draw_line(self: *Self, debug_line: DebugLine) void {
        self.lines.append(debug_line) catch |err| {
            std.log.warn("Failed to append debug line: {s}", .{@errorName(err)});
        };
    }

    pub fn draw_point(self: *Self, debug_point: DebugPoint) void {
        const size = debug_point.size;
        self.draw_line(DebugLine{
            .p0 = debug_point.point - zm.f32x4(size, 0.0, 0.0, 0.0),
            .p1 = debug_point.point + zm.f32x4(size, 0.0, 0.0, 0.0),
            .colour = debug_point.colour,
        });
        self.draw_line(DebugLine{
            .p0 = debug_point.point - zm.f32x4(0.0, size, 0.0, 0.0),
            .p1 = debug_point.point + zm.f32x4(0.0, size, 0.0, 0.0),
            .colour = debug_point.colour,
        });
        self.draw_line(DebugLine{
            .p0 = debug_point.point - zm.f32x4(0.0, 0.0, size, 0.0),
            .p1 = debug_point.point + zm.f32x4(0.0, 0.0, size, 0.0),
            .colour = debug_point.colour,
        });
    }

    pub fn render_cmd(self: *Self, cmd: *gfx.CommandBuffer, camera: *const Camera) !void {
        defer self.lines.clear();

        cmd.cmd_begin_render_pass(gfx.CommandBuffer.BeginRenderPassInfo {
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffer,
            .render_area = .full_screen_pixels(),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_set_viewports(.{
            .viewports = &.{ .full_screen_viewport(), },
        });
        cmd.cmd_set_scissors(.{
            .scissors = &.{ .full_screen_pixels(), },
        });

        cmd.cmd_bind_graphics_pipeline(self.lines_pipeline);

        cmd.cmd_bind_vertex_buffers(gfx.CommandBuffer.BindVertexBuffersInfo {
            .buffers = &.{
                gfx.VertexBufferInput {
                    .buffer = self.lines_instance_buffer,
                },
            },
        });

        {
            const mapped_camera_buffer = try (try self.camera_buffer.get()).map(.{ .write = .EveryFrame, });
            defer mapped_camera_buffer.unmap();

            mapped_camera_buffer.data(CameraData).* = CameraData {
                .view = camera.transform.generate_view_matrix(),
                .projection = camera.generate_perspective_matrix(gfx.GfxState.get().swapchain_aspect()),
            };
        }

        cmd.cmd_bind_descriptor_sets(gfx.CommandBuffer.BindDescriptorSetInfo {
            .graphics_pipeline = self.lines_pipeline,
            .descriptor_sets = &.{ self.camera_descriptor_set, },
        });

        const lines_slice = self.lines.constSlice();

        {
            const mapped_lines_buffer = try (try self.lines_instance_buffer.get()).map(.{ .write = .EveryFrame, });
            defer mapped_lines_buffer.unmap();

            const mapped_slice = mapped_lines_buffer.data_array(LineDetails, Self.MAX_LINES);
            for (lines_slice, 0..) |line, idx| {
                mapped_slice[idx] = LineDetails {
                    .start_point = line.p0,
                    .end_point = line.p1,
                    .colour = line.colour,
                };
            }
        }

        cmd.cmd_draw(gfx.CommandBuffer.DrawInfo {
            .vertex_count = 6,
            .instance_count = @intCast(lines_slice.len),
        });
    }

    pub fn render(self: *Self, camera_buffer: *const gfx.Buffer, rtv: gfx.ImageView.Ref) void {
        const gfx_state = &@import("../root.zig").get().gfx;

        const lines_slice = self.lines.constSlice();

        {
            var mapped_buffer = self.lines_instance_buffer.map(.{ .write = true, }) catch unreachable;
            defer mapped_buffer.unmap();

            for (lines_slice, 0..) |line, i| {
                mapped_buffer.data_array(LineDetails, MAX_LINES)[i] = LineDetails {
                    .start_point = zm.f32x4(line.p0[0], line.p0[1], line.p0[2], 1.0),
                    .end_point = zm.f32x4(line.p1[0], line.p1[1], line.p1[2], 1.0),
                    .colour = line.colour,
                };
            }
        }

        gfx_state.cmd_set_render_target(&.{rtv}, null);
        gfx_state.cmd_set_topology(.TriangleList);
        gfx_state.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });
        gfx_state.cmd_set_constant_buffers(.Vertex, 0, &[_]*const gfx.Buffer{camera_buffer});
        gfx_state.cmd_set_vertex_buffers(0, &[_]gfx.VertexBufferInput{
            .{ .buffer = &self.lines_instance_buffer, .stride = @sizeOf(LineDetails), .offset = @sizeOf(zm.F32x4) * 0, },
            .{ .buffer = &self.lines_instance_buffer, .stride = @sizeOf(LineDetails), .offset = @sizeOf(zm.F32x4) * 1, },
            .{ .buffer = &self.lines_instance_buffer, .stride = @sizeOf(LineDetails), .offset = @sizeOf(zm.F32x4) * 2, },
        });
        gfx_state.cmd_set_vertex_shader(&self.lines_vertex_shader);
        gfx_state.cmd_set_pixel_shader(&self.lines_pixel_shader);
        gfx_state.cmd_draw_instanced(6, @intCast(lines_slice.len), 0, 0);

        // Clear lines buffer
        self.lines.resize(0) catch unreachable;
    }
};

pub const DebugLine = struct {
    p0: zm.F32x4,
    p1: zm.F32x4,
    colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
};

pub const DebugPoint = struct {
    point: zm.F32x4,
    colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
    size: f32 = 1.0,
};

const LINES_HLSL = @embedFile("lines.slang");

