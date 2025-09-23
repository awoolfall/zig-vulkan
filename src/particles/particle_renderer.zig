const std = @import("std");
const zm = @import("zmath");
const zn = @import("znoise");
const eng = @import("self");
const Transform = eng.Transform;
const tm = eng.time;
const gf = eng.gfx;
const es = eng.easings;
const ms = eng.mesh;
const Camera = eng.camera.Camera;
const ps = @import("particle_system.zig");

pub const ParticleRenderer = struct {
    const Self = @This();
    const MAX_PARTICLES_PER_BUFFER = 4096;

    const ConstantBuffer = extern struct {
        view_matrix: zm.Mat,
        proj_matrix: zm.Mat,
    };

    const ParticleSystemFlags = packed struct(u32) {
        circle_shader: bool = false,
        velocity_aligned: bool = false,
        __unused: u30 = 0,
    };

    const PushConstants = extern struct {
        flags: u32,
    };

    const StagedParticleSet = struct {
        push_constant_data: PushConstants,
        instances_buffer: gf.Buffer.Ref,
        instances_buffer_offset: usize,
        num_instances: usize,
    };

    vertex_shader: gf.VertexShader,
    pixel_shader: gf.PixelShader,
    shader_watcher: eng.assets.FileWatcher,

    instaces_data_buffers: std.ArrayList(gf.Buffer.Ref),

    camera_constant_buffer: gf.Buffer.Ref,

    camera_descriptor_layout: gf.DescriptorLayout.Ref,
    camera_descriptor_pool: gf.DescriptorPool.Ref,
    camera_descriptor_set: gf.DescriptorSet.Ref,

    render_pass: gf.RenderPass.Ref,
    pipeline: gf.GraphicsPipeline.Ref,
    framebuffer: gf.FrameBuffer.Ref,

    staged_particle_sets: std.ArrayList(StagedParticleSet),
    staged_particle_count: usize = 0,

    pub fn deinit(self: *Self) void {
        self.staged_particle_sets.deinit(eng.get().general_allocator);

        self.framebuffer.deinit();
        self.pipeline.deinit();
        self.render_pass.deinit();

        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.shader_watcher.deinit();

        self.camera_descriptor_set.deinit();
        self.camera_descriptor_pool.deinit();
        self.camera_descriptor_layout.deinit();

        for (self.instaces_data_buffers.items) |b| {
            b.deinit();
        }
        self.instaces_data_buffers.deinit(eng.get().general_allocator);

        self.camera_constant_buffer.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !Self {
        const particle_path = try std.fs.path.join(alloc, &[_][]const u8{ @import("build_options").engine_src_path, "particles/particles.slang" });
        defer alloc.free(particle_path);

        const shader_file = std.fs.openFileAbsolute(particle_path, .{}) catch |err| {
            std.log.err("failed to open file: {}", .{err});
            return error.FileNotFound;
        };
        defer shader_file.close();

        const shaders = try init_shaders();
        const vertex_shader = shaders[0];
        const pixel_shader = shaders[1];

        var shader_watcher = try eng.assets.FileWatcher.init(alloc, particle_path, 500);
        errdefer shader_watcher.deinit();

        const camera_constant_buffer = try gf.Buffer.init(
            @sizeOf(ConstantBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer camera_constant_buffer.deinit();

        const camera_descriptor_layout = try gf.DescriptorLayout.init(.{
            .bindings = &.{
                gf.DescriptorBindingInfo {
                    .binding = 0,
                    .shader_stages = .{ .Vertex = true, .Pixel = true, },
                    .binding_type = .UniformBuffer,
                },
            },
        });
        errdefer camera_descriptor_layout.deinit();

        const camera_descriptor_pool = try gf.DescriptorPool.init(.{
            .max_sets = 1,
            .strategy = .{ .Layout = camera_descriptor_layout, },
        });
        errdefer camera_descriptor_pool.deinit();

        const camera_descriptor_set = try (try camera_descriptor_pool.get()).allocate_set(.{
            .layout = camera_descriptor_layout,
        });
        errdefer camera_descriptor_set.deinit();

        try (try camera_descriptor_set.get()).update(.{
            .writes = &.{
                gf.DescriptorSetUpdateWriteInfo {
                    .binding = 0,
                    .data = .{ .UniformBuffer = .{
                        .buffer = camera_constant_buffer,
                    } },
                },
            },
        });
        
        const attachments = [_]gf.AttachmentInfo {
            .{
                .name = "colour",
                .format = gf.GfxState.hdr_format,
                .blend_type = .Simple,
                .initial_layout = .ColorAttachmentOptimal,
                .final_layout = .ColorAttachmentOptimal,
            },
            .{
                .name = "depth",
                .format = gf.GfxState.depth_format,
                .initial_layout = .DepthStencilAttachmentOptimal,
                .final_layout = .DepthStencilAttachmentOptimal,
            },
        };

        var render_pass = try gf.RenderPass.init(.{
            .attachments = attachments[0..],
            .subpasses = &.{
                gf.SubpassInfo {
                    .attachments = &.{
                        "colour",
                    },
                    .depth_attachment = "depth",
                },
            },
            .dependencies = &.{
                gf.SubpassDependencyInfo {
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

        var graphics_pipeline = try gf.GraphicsPipeline.init(.{
            .vertex_shader = &vertex_shader,
            .pixel_shader = &pixel_shader,
            .depth_test = .{ .write = false, },
            .attachments = attachments[0..],
            .render_pass = render_pass,
            .descriptor_set_layouts = &.{
                camera_descriptor_layout,
            },
            .push_constants = &.{
                gf.PushConstantLayoutInfo {
                    .shader_stages = .{ .Vertex = true, .Pixel = true, },
                    .offset = 0,
                    .size = @sizeOf(PushConstants),
                },
            },
        });
        errdefer graphics_pipeline.deinit();

        var framebuffer = try gf.FrameBuffer.init(.{
            .attachments = &.{
                .SwapchainHDR,
                .SwapchainDepth,
            },
            .render_pass = render_pass,
        });
        errdefer framebuffer.deinit();

        return Self {
            .staged_particle_sets = try std.ArrayList(StagedParticleSet).initCapacity(eng.get().general_allocator, 32),

            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,
            .shader_watcher = shader_watcher,

            .render_pass = render_pass,
            .pipeline = graphics_pipeline,
            .framebuffer = framebuffer,

            .instaces_data_buffers = try std.ArrayList(gf.Buffer.Ref).initCapacity(eng.get().general_allocator, 4),
            .camera_constant_buffer = camera_constant_buffer,

            .camera_descriptor_layout = camera_descriptor_layout,
            .camera_descriptor_pool = camera_descriptor_pool,
            .camera_descriptor_set = camera_descriptor_set,
        };
    }

    pub fn init_shaders() !struct {gf.VertexShader, gf.PixelShader} {
        const particle_path = std.fs.path.join(
            eng.get().general_allocator,
            &[_][]const u8{ @import("build_options").engine_src_path, "particles/particles.slang" }
        ) catch |err| {
            std.log.err("failed to join paths: {}", .{err});
            return err;
        };
        defer eng.get().general_allocator.free(particle_path);

        const shader_file = std.fs.openFileAbsolute(particle_path, .{}) catch |err| {
            std.log.err("failed to open file: {}", .{err});
            return err;
        };
        defer shader_file.close();

        const shader_source = shader_file.readToEndAlloc(eng.get().general_allocator, 1024 * 1024) catch |err| {
            std.log.err("failed to read file: {}", .{err});
            return err;
        };
        defer eng.get().general_allocator.free(shader_source);

        const stride: u32 = 
            @sizeOf([4]f32) +   // position
            @sizeOf([4]f32) +   // colour
            @sizeOf([4]f32) +   // velocity
            @sizeOf([4]f32);    // scale
        const vertex_shader = try gf.VertexShader.init_buffer(
            shader_source,
            "vs_main",
            .{
                .bindings = &.{
                    .{ .binding = 0, .stride = stride, .input_rate = .Instance },
                },
                .attributes = &.{
                    .{ .name = "Position",  .location = 0, .binding = 0, .offset = 0 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "Colour",    .location = 1, .binding = 0, .offset = 1 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "Velocity",  .location = 2, .binding = 0, .offset = 2 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "Scale",     .location = 3, .binding = 0, .offset = 3 * @sizeOf([4]f32), .format = .F32x4, },
                },
            },
            .{},
        );
        errdefer vertex_shader.deinit();
        
        const pixel_shader = try gf.PixelShader.init_buffer(
            shader_source,
            "ps_main",
            .{},
        );
        errdefer pixel_shader.deinit();

        return .{
            vertex_shader,
            pixel_shader,
        };
    }

    pub fn clear(self: *Self) void {
        self.staged_particle_sets.clearRetainingCapacity();
        self.staged_particle_count = 0;
    }

    fn push_new_instance_buffer(self: *Self) !void {
        const instance_buffer = try gf.Buffer.init(
            @sizeOf(ps.ParticleRenderData) * Self.MAX_PARTICLES_PER_BUFFER,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer instance_buffer.deinit();

        try self.instaces_data_buffers.append(eng.get().general_allocator, instance_buffer);
    }

    pub fn push_particle_system(self: *Self, particle_system: *const ps.ParticleSystem) !void {
        // create new buffers to support particle count
        while ((self.staged_particle_count + particle_system.particles_render_data.len) > (self.instaces_data_buffers.items.len * Self.MAX_PARTICLES_PER_BUFFER)) {
            std.log.info("creating new paticle instance buffer", .{});
            try self.push_new_instance_buffer();
        }
        
        var staged_particles: usize = 0;
        while (staged_particles < particle_system.particles_render_data.len) {
            const buffer_idx = @divFloor(self.staged_particle_count, Self.MAX_PARTICLES_PER_BUFFER);
            const buffer_ref = self.instaces_data_buffers.items[buffer_idx];
            const buffer = try buffer_ref.get();

            const mapped_buffer = try buffer.map(.{ .write = .EveryFrame, });
            defer mapped_buffer.unmap();

            const data = mapped_buffer.data_array(ps.ParticleRenderData, Self.MAX_PARTICLES_PER_BUFFER);
            const start_idx = @mod(self.staged_particle_count, Self.MAX_PARTICLES_PER_BUFFER);
            const copy_amount = @min(particle_system.particles_render_data.len - staged_particles, Self.MAX_PARTICLES_PER_BUFFER - start_idx);
            const end_idx = start_idx + copy_amount;

            @memcpy(data[start_idx..end_idx], particle_system.particles_render_data[staged_particles..(staged_particles + copy_amount)]);

            const particle_set = StagedParticleSet {
                .push_constant_data = .{
                    .flags = @bitCast(ParticleSystemFlags {
                        .circle_shader = (particle_system.settings.shape == .Circle),
                        .velocity_aligned = (particle_system.settings.alignment == .VelocityAligned) 
                    }),
                },
                .instances_buffer = buffer_ref,
                .instances_buffer_offset = @sizeOf(ps.ParticleRenderData) * start_idx,
                .num_instances = copy_amount,
            };

            try self.staged_particle_sets.append(eng.get().general_allocator, particle_set);

            staged_particles += copy_amount;
            self.staged_particle_count += copy_amount;
        }
    }

    // fn particle_z_sort_func(_: i32, lhs: ArrDat, rhs: ArrDat) bool {
    //     return lhs.z > rhs.z;
    // }
    //
    // const ArrDat = struct {
    //     z: f32,
    //     dat: VertexBufferData,
    // };

    pub fn render(
        self: *Self,
        cmd: *gf.CommandBuffer,
        camera: *const Camera,
    ) !void {
        if (self.shader_watcher.was_modified_since_last_check()) {
            blk: {
                const new_shaders = init_shaders() catch |err| {
                    std.log.err("failed to reload shaders: {}", .{err});
                    break :blk;
                };
                
                self.vertex_shader.deinit();
                self.pixel_shader.deinit();
                self.vertex_shader = new_shaders[0];
                self.pixel_shader = new_shaders[1];
            }
        }

        // update camera constant buffer
        blk: {
            const camera_buffer = self.camera_constant_buffer.get() catch |err| {
                std.log.warn("Unable to get camera buffer: {}", .{err});
                break :blk;
            };

            const mapped_buffer = camera_buffer.map(.{ .write = .EveryFrame, }) catch |err| {
                std.log.warn("Unable to map camera buffer: {}", .{err});
                break :blk;
            };
            defer mapped_buffer.unmap();

            mapped_buffer.data(ConstantBuffer).* = ConstantBuffer {
                .view_matrix = camera.transform.generate_view_matrix(),
                .proj_matrix = camera.generate_perspective_matrix(gf.GfxState.get().swapchain_aspect()),
            };
        }

        cmd.cmd_begin_render_pass(.{
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

        cmd.cmd_bind_graphics_pipeline(self.pipeline);

        cmd.cmd_bind_descriptor_sets(.{
            .graphics_pipeline = self.pipeline,
            .descriptor_sets = &.{
                self.camera_descriptor_set,
            },
        });

        for (self.staged_particle_sets.items) |s| {
            cmd.cmd_bind_vertex_buffers(.{
                .buffers = &.{
                    gf.VertexBufferInput {
                        .buffer = s.instances_buffer,
                        .offset = @intCast(s.instances_buffer_offset),
                    },
                },
            });

            cmd.cmd_push_constants(gf.CommandBuffer.PushConstantsInfo {
                .graphics_pipeline = self.pipeline,
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .offset = 0,
                .data = std.mem.asBytes(&s.push_constant_data),
            });

            cmd.cmd_draw(.{
                .vertex_count = 6,
                .instance_count = @intCast(s.num_instances),
            });
        }
    }
};

