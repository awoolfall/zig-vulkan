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

pub const ParticleSystem = struct {
    const Self = @This();

    const VertexBufferData = extern struct {
        model_matrix: zm.Mat,
        colour: zm.F32x4,
        velocity: zm.F32x4,
        scale: zm.F32x4,
    };
    
    const ConstantBuffer = extern struct {
        view_matrix: zm.Mat,
        proj_matrix: zm.Mat,
        flags: u32,
    };

    const ConstantBufferFlags = packed struct(u32) {
        circle_shader: bool = false,
        velocity_aligned: bool = false,
        __unused: u30 = 0,
    };

    settings: ParticleSystemSettings,
    particles: []?ParticleData,
    next_particle_index: usize = 0,

    alloc: std.mem.Allocator,
    rand: std.Random.DefaultPrng,
    noise: zn.FnlGenerator,

    seconds_to_next_particle: f32 = 0.0,

    vertex_shader: gf.VertexShader,
    pixel_shader: gf.PixelShader,
    shader_watcher: eng.assets.FileWatcher,

    model_matrix_vertex_buffer: gf.Buffer.Ref,
    camera_constant_buffer: gf.Buffer.Ref,

    camera_descriptor_layout: gf.DescriptorLayout.Ref,
    camera_descriptor_pool: gf.DescriptorPool.Ref,
    camera_descriptor_set: gf.DescriptorSet.Ref,

    render_pass: gf.RenderPass.Ref,
    pipeline: gf.GraphicsPipeline.Ref,
    framebuffer: gf.FrameBuffer.Ref,

    sort_particles: []ArrDat,

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.particles);
        self.alloc.free(self.sort_particles);

        self.framebuffer.deinit();
        self.pipeline.deinit();
        self.render_pass.deinit();

        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.shader_watcher.deinit();

        self.camera_descriptor_set.deinit();
        self.camera_descriptor_pool.deinit();
        self.camera_descriptor_layout.deinit();

        self.model_matrix_vertex_buffer.deinit();
        self.camera_constant_buffer.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, settings: ParticleSystemSettings) !Self {
        const particle_path = try std.fs.path.join(alloc, &[_][]const u8{ @import("build_options").engine_src_path, "engine/particles.slang" });
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

        const model_matrix_vertex_buffer = try gf.Buffer.init(
            @sizeOf(VertexBufferData) * settings.max_particles,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer model_matrix_vertex_buffer.deinit();

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

        const particles = try alloc.alloc(?ParticleData, settings.max_particles);
        errdefer alloc.free(particles);
        @memset(particles, null);

        const sort_particles = try alloc.alloc(ArrDat, settings.max_particles);
        errdefer alloc.free(sort_particles);

        return Self {
            .settings = settings,
            .particles = particles,
            .alloc = alloc,
            .rand = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp())),
            .noise = zn.FnlGenerator{},
            .sort_particles = sort_particles,

            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,
            .shader_watcher = shader_watcher,

            .render_pass = render_pass,
            .pipeline = graphics_pipeline,
            .framebuffer = framebuffer,

            .model_matrix_vertex_buffer = model_matrix_vertex_buffer,
            .camera_constant_buffer = camera_constant_buffer,

            .camera_descriptor_layout = camera_descriptor_layout,
            .camera_descriptor_pool = camera_descriptor_pool,
            .camera_descriptor_set = camera_descriptor_set,
        };
    }

    pub fn init_shaders() !struct {gf.VertexShader, gf.PixelShader} {
        const particle_path = std.fs.path.join(eng.get().general_allocator, &[_][]const u8{ @import("build_options").engine_src_path, "engine/particles.slang" }) catch |err| {
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
            @sizeOf([16]f32) +  // matrix
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
                    .{ .name = "RowX",      .location = 0, .binding = 0, .offset = 0 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "RowY",      .location = 1, .binding = 0, .offset = 1 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "RowZ",      .location = 2, .binding = 0, .offset = 2 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "RowW",      .location = 3, .binding = 0, .offset = 3 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "Colour",    .location = 4, .binding = 0, .offset = 4 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "Velocity",  .location = 5, .binding = 0, .offset = 5 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "Scale",     .location = 6, .binding = 0, .offset = 6 * @sizeOf([4]f32), .format = .F32x4, },
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

    pub fn emit_particle_burst(self: *Self) void {
        for (0..self.settings.burst_count) |_| {
            self.emit_particle();
        }
    }

    fn emit_particle(self: *Self) void {
        // find free particle
        const check_idx = self.next_particle_index;
        var count: u32 = 0;
        while (self.particles[self.next_particle_index] != null) {
            count += 1;
            self.next_particle_index = (self.next_particle_index + 1) % self.particles.len;
            if (self.next_particle_index == check_idx) {
                std.log.err("failed to find free particle", .{});
                return;
            }
        }

        const spawn_direction = zm.normalize3(random_v(self.rand.random()) * zm.f32x4s(2.0) - zm.f32x4s(1.0));
        const initial_position = 
            self.settings.spawn_origin +
            self.settings.spawn_offset +
            spawn_direction * zm.f32x4s(self.settings.spawn_radius * self.rand.random().float(f32));

        self.particles[self.next_particle_index] = ParticleData {
            .rand = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp())),
            .rand_vec = random_v(self.rand.random()),
            .transform = Transform {
                .position = initial_position,
                .scale = KeyFrame(zm.F32x4).calc(self.settings.scale.slice(), 0.0),
            },
            .velocity = self.settings.initial_velocity,
            .life_remaining = self.f32_variance(self.settings.particle_lifetime, self.settings.particle_lifetime_variance),
            .last_curl = zm.f32x4s(0.0),
        };
    }

    pub fn update(self: *Self, time: *const tm.TimeState) void {
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

        const delta_time = zm.f32x4s(time.delta_time_f32());
        const current_time = zm.f32x4s(@floatCast(time.time_since_start_of_app()));
        for (self.particles, 0..) |*maybe_particle, i| {
            if (maybe_particle.*) |*p| {
                p.life_remaining -= delta_time[0];
                if (p.life_remaining <= 0.0) { 
                    maybe_particle.* = null; 
                    continue;
                }
                const t = 1.0 - (p.life_remaining / self.settings.particle_lifetime);

                for (self.settings.forces.slice()) |fo| {
                        switch (fo) {
                            .Constant => |v| { p.velocity += (v * delta_time); },
                            .ConstantRand => |force| { 
                                const noise_vec = zm.f32x4(
                                    self.noise.noise2(current_time[0]*100.0, p.rand_vec[0]*1000.0),
                                    self.noise.noise2(current_time[0]*100.0, p.rand_vec[1]*1000.0),
                                    self.noise.noise2(current_time[0]*100.0, p.rand_vec[2]*1000.0),
                                    self.noise.noise2(current_time[0]*100.0, p.rand_vec[3]*1000.0),
                                );
                                p.velocity += ((noise_vec - zm.f32x4s(0.5)) * zm.f32x4s(force) * delta_time); 
                            },
                            .Curl => |force| {
                                p.velocity += self.compute_curl_frame(p) * zm.f32x4s(force) * delta_time;
                            },
                            .Drag => |force| {
                                p.velocity -= p.velocity * zm.f32x4s(force) * delta_time;
                            },
                            .Vortex => |d| {
                                const vec_to_p = p.transform.position - self.settings.spawn_origin;
                                // vortex
                                var force = zm.cross3(zm.normalize3(vec_to_p), zm.normalize3(d.axis)) * zm.f32x4s(d.force);
                                // origin pull, @TODO: maybe make this pull to the axis line?
                                force += -zm.normalize3(vec_to_p) * zm.f32x4s(d.origin_pull);
                                
                                p.velocity += force * delta_time;
                            },
                    }
                }

                p.transform.scale = KeyFrame(zm.F32x4).calc(self.settings.scale.slice(), t);
                p.colour = KeyFrame(zm.F32x4).hsv_calc(self.settings.colour.slice(), t);
                p.transform.position += p.velocity * zm.f32x4(1.0, 1.0, 1.0, 0.0) * delta_time;
            }

            // render prep
            if (maybe_particle.*) |*p| {
                self.sort_particles[i].dat.model_matrix = p.transform.generate_model_matrix();
                self.sort_particles[i].dat.colour = p.colour;
                self.sort_particles[i].dat.velocity = p.velocity * zm.f32x4(1.0, 1.0, 1.0, 0.0);
                self.sort_particles[i].dat.scale = p.transform.scale;
                if (self.settings.alignment == .VelocityAligned) {
                    self.sort_particles[i].dat.velocity *= zm.f32x4s(self.settings.alignment.VelocityAligned);
                }
            } else {
                const zero_size = zm.scaling(0.0, 0.0, 0.0);
                self.sort_particles[i].dat.model_matrix = zero_size;
                self.sort_particles[i].dat.colour = zm.f32x4s(0.0);
                self.sort_particles[i].dat.velocity = zm.f32x4s(0.0);
                self.sort_particles[i].dat.scale = zm.f32x4s(0.0);
            }
            //self.sort_particles[i].z = zm.mul(zm.f32x4(0.0, 0.0, 0.0, 1.0), zm.mul(self.sort_particles[i].dat.model_matrix, zm.mul(view_matrix, proj_matrix)))[2];
        }
        //std.mem.sort(ArrDat, self.sort_particles[0..], @as(i32, @intCast(0)), particle_z_sort_func);


        self.seconds_to_next_particle -= delta_time[0];
        if (self.settings.spawn_rate != 0.0) {
            while (self.seconds_to_next_particle <= 0.0) {
                self.emit_particle_burst();
                self.seconds_to_next_particle += @max(0.0, self.f32_variance(self.settings.spawn_rate, self.settings.spawn_rate_variance));
            }
        }
    }

    fn noise3(self: *Self, pos: zm.F32x4) zm.F32x4 {
        return zm.f32x4(
            self.noise.noise3(pos[0], pos[1], pos[2]),
            self.noise.noise3(pos[1] - 42.8, pos[2] + 77.3, pos[0] + 91.2),
            self.noise.noise3(pos[2] + 97.3, pos[0] - 149.5, pos[1] + 129.4),
            0.0//self.noise.noise3(pos[0] - 82.1, pos[1] + 32.8, pos[2] - 17.1),
        );
    }

    fn compute_curl_frame(self: *Self, p: *ParticleData) zm.F32x4 {
        // jitter particle by epsilon so we can get a rate of change reading
        // randomly swap between jitterring by +/- eps so it averages to 0 movement
        const eps: f32 = 0.0001 * (@as(f32, @floatFromInt(@intFromBool(self.rand.random().boolean()))) * 2.0 - 1.0);
        p.transform.position += zm.f32x4(eps, eps, eps, 0.0);

        const position = p.transform.position * zm.f32x4s(50.0);

        //Find rate of change
        const x1 = self.noise3(zm.f32x4(position[0], position[1], position[2], 0.0));

        const v = zm.f32x4(
            p.last_curl[2] - x1[2] - p.last_curl[1] - x1[1],
            p.last_curl[0] - x1[0] - p.last_curl[2] - x1[2],
            p.last_curl[1] - x1[1] - p.last_curl[0] - x1[0],
            0.0
        );

        p.last_curl = x1;

        //Curl
        const divisor = 1.0 / (0.0002);
        return zm.normalize3(v * zm.f32x4s(divisor));
    }

    fn particle_z_sort_func(_: i32, lhs: ArrDat, rhs: ArrDat) bool {
        return lhs.z > rhs.z;
    }

    const ArrDat = struct {
        z: f32,
        dat: VertexBufferData,
    };

    pub fn draw(
        self: *Self,
        cmd: *gf.CommandBuffer,
        camera: *const Camera,
    ) !void {
        // update all particle model matrices
        blk: {
            const model_matrix_buffer = self.model_matrix_vertex_buffer.get() catch |err| {
                std.log.warn("Unable to get model matrix buffer: {}", .{err});
                break :blk;
            };

            const mapped_buffer = model_matrix_buffer.map(.{ .write = .EveryFrame, }) catch |err| {
                std.log.warn("Unable to map model matrix buffer: {}", .{err});
                break :blk;
            };
            defer mapped_buffer.unmap();

            const data = mapped_buffer.data_array(VertexBufferData, self.sort_particles.len);
            for (self.sort_particles, 0..) |*p, i| {
                data[i] = p.dat;
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
                .flags = @bitCast(ConstantBufferFlags { 
                    .circle_shader = (self.settings.shape == .Circle),
                    .velocity_aligned = (self.settings.alignment == .VelocityAligned) 
                }),
            };
        }

        // TODO perform draw commands only once for all particle systems
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

        cmd.cmd_bind_vertex_buffers(.{
            .buffers = &.{
                gf.VertexBufferInput {
                    .buffer = self.model_matrix_vertex_buffer,
                },
                },
            });

        cmd.cmd_bind_descriptor_sets(.{
            .graphics_pipeline = self.pipeline,
            .descriptor_sets = &.{
                self.camera_descriptor_set,
            },
            });

        cmd.cmd_draw(.{
            .vertex_count = 6,
            .instance_count = @intCast(self.particles.len),
        });
    }

    fn random_v(rand: std.Random) zm.F32x4 {
        return zm.f32x4(
            rand.float(f32),
            rand.float(f32),
            rand.float(f32),
            rand.float(f32)
        );
    }

    fn f32_variance(self: *Self, value: f32, variance: f32) f32 {
        return value + (((self.rand.random().float(f32) - 0.5) * 2.0) * variance);
    }

    fn f32x4_variance(self: *Self, value: zm.F32x4, variance: zm.F32x4) zm.F32x4 {
        return value + (((random_v(self.rand.random()) - zm.f32x4s(0.5)) * zm.f32x4s(2.0)) * variance);
    }
};

pub const ParticleData = struct {
    rand: std.Random.DefaultPrng,
    rand_vec: zm.F32x4,
    transform: Transform,
    velocity: zm.F32x4 = zm.f32x4s(0.0),
    colour: zm.F32x4 = zm.f32x4s(0.0),
    life_remaining: f32 = 0.0,
    last_curl: zm.F32x4,
};

pub const MAX_KEYFRAMES: usize = 6;
pub const ScaleKeyFrame = KeyFrame(zm.F32x4);
pub const ColourKeyFrame = KeyFrame(zm.F32x4);
pub const ScaleKeyFrameArray = std.BoundedArray(ScaleKeyFrame, MAX_KEYFRAMES);
pub const ColourKeyFrameArray = std.BoundedArray(ColourKeyFrame, MAX_KEYFRAMES);
pub const MAX_FORCES: usize = 6;
pub const ForceArray = std.BoundedArray(ForceEnum, MAX_FORCES);

pub const ParticleSystemSettings = struct {
    max_particles: u32 = 1000,

    alignment: ParticleAlignment = .Transform,
    shape: ParticleShape = .Box,

    spawn_origin: zm.F32x4 = zm.f32x4s(0.0),
    spawn_offset: zm.F32x4 = zm.f32x4s(0.0),
    spawn_radius: f32 = 1.0,
    spawn_rate: f32 = 1.0,
    spawn_rate_variance: f32 = 0.0,
    burst_count: u32 = 1,

    particle_lifetime: f32 = 1.0,
    particle_lifetime_variance: f32 = 0.0,

    initial_velocity: zm.F32x4 = zm.f32x4s(0.0),

    scale: ScaleKeyFrameArray = .{},
    colour: ColourKeyFrameArray = .{},
    forces: ForceArray = .{},
};

pub const ParticleAlignment = union(enum) {
    Transform: void,
    Billboard: void,
    VelocityAligned: f32,
};

pub const ParticleShape = union(enum) {
    Box: void,
    Circle: void,
    //Texture: *const gf.TextureView2D, // @TODO
};

pub const ForceEnum = union(enum) {
    Constant: zm.F32x4,
    ConstantRand: f32,
    Curl: f32,
    Drag: f32,
    Vortex: struct { axis: zm.F32x4, force: f32, origin_pull: f32 },
};

pub fn KeyFrame(comptime T: type) type {
    return struct {
        easing_into: es.Easing = .OutLinear,
        key_time: f32 = 0.0,
        value: T,

        fn calc_(self: *const KeyFrame(T), prev: *const KeyFrame(T), t: f32) T {
            const ft = self.easing_into.func()((t - prev.key_time) / (self.key_time - prev.key_time));
            if (T == zm.F32x4) {
                return prev.value + zm.f32x4s(ft) * (self.value - prev.value);
            } else {
                return prev.value + ft * (self.value - prev.value);
            }
        }

        pub fn calc(arr: []KeyFrame(T), t: f32) T {
            if (arr.len == 0) return default_value();
            if (arr.len == 1) return arr[0].value;
            for (1..arr.len) |i| {
                if (arr[i].key_time >= t) {
                    if (i == 0) { 
                        return arr[i].value;
                    } else {
                        return arr[i].calc_(&arr[i-1], t);
                    }
                }
            }
            return default_value();
        }

        pub fn hsv_calc(arr: []KeyFrame(zm.F32x4), t: f32) zm.F32x4 {
            if (arr.len == 0) return zm.f32x4s(0.0);
            if (arr.len == 1) return arr[0].value;
            for (1..arr.len) |i| {
                if (arr[i].key_time >= t) {
                    if (i == 0) { 
                        return arr[i].value;
                    } else {
                        var s = arr[i];
                        s.value = zm.rgbToHsv(s.value);
                        var p = arr[i-1];
                        p.value = zm.rgbToHsv(p.value);
                        return zm.hsvToRgb(s.calc_(&p, t));
                    }
                }
            }
            return zm.f32x4s(0.0);
        }

        pub fn default_value() T {
            if (T == zm.F32x4) {
                return zm.f32x4s(0.0);
            } else {
                return 0.0;
            }
        }
    };
}

pub fn ValueTimeline(comptime T: type) type {
    return struct {
        easing: es.Easing = .Constant,
        start: T,
        end: T = default_value(),

        pub fn calc(self: *const ValueTimeline(T), t: f32) T {
            const ft = self.easing.func()(t);
            if (T == zm.F32x4) {
                return self.start + zm.f32x4s(ft) * (self.end - self.start);
            } else {
                return self.start + ft * (self.end - self.start);
            }
        }

        fn default_value() T {
            if (T == zm.F32x4) {
                return zm.f32x4s(0.0);
            } else {
                return 0.0;
            }
        }
    };
}

