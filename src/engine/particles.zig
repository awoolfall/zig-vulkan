const std = @import("std");
const zm = @import("zmath");
const zn = @import("znoise");
const Transform = @import("transform.zig");
const tm = @import("time.zig");
const en = @import("../root.zig");
const gf = @import("../gfx/gfx.zig");
const es = @import("../easings.zig");
const ms = @import("../engine/mesh.zig");

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
    shader_watcher: en.assets.FileWatcher,

    model_matrix_vertex_buffer: gf.Buffer,
    constant_buffer: gf.Buffer,
    blend_state: gf.BlendState,

    sort_particles: []ArrDat,

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.particles);
        self.alloc.free(self.sort_particles);

        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.blend_state.deinit();
        self.model_matrix_vertex_buffer.deinit();
        self.constant_buffer.deinit();
        self.shader_watcher.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, settings: ParticleSystemSettings) !Self {
        const particle_path = try std.fs.path.join(alloc, &[_][]const u8{ @import("build_options").engine_src_path, "engine/particles.hlsl" });
        defer alloc.free(particle_path);

        const shader_file = std.fs.openFileAbsolute(particle_path, .{}) catch |err| {
            std.log.err("failed to open file: {}", .{err});
            return error.FileNotFound;
        };
        defer shader_file.close();

        const shader_hlsl = shader_file.readToEndAlloc(en.engine().general_allocator, 1024 * 1024) catch |err| {
            std.log.err("failed to read file: {}", .{err});
            return error.UnableToRead;
        };
        defer en.engine().general_allocator.free(shader_hlsl);

        const shaders = try init_shaders(shader_hlsl);
        const vertex_shader = shaders[0];
        const pixel_shader = shaders[1];

        var shader_watcher = try en.assets.FileWatcher.init(alloc, particle_path, 500);
        errdefer shader_watcher.deinit();

        const model_matrix_vertex_buffer = try gf.Buffer.init(
            @sizeOf(VertexBufferData) * settings.max_particles,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
            &en.engine().gfx
        );
        errdefer model_matrix_vertex_buffer.deinit();

        const constant_buffer = try gf.Buffer.init(
            @sizeOf(ConstantBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            &en.engine().gfx
        );
        errdefer constant_buffer.deinit();

        var blend_state = gf.BlendState.init(([_]gf.BlendType{.Simple})[0..], &en.engine().gfx) catch unreachable;
        errdefer blend_state.deinit();

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
            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,
            .shader_watcher = shader_watcher,
            .model_matrix_vertex_buffer = model_matrix_vertex_buffer,
            .constant_buffer = constant_buffer,
            .blend_state = blend_state,
            .sort_particles = sort_particles,
        };
    }

    pub fn init_shaders(hlsl: []const u8) !struct {gf.VertexShader, gf.PixelShader} {
        const vertex_shader = try gf.VertexShader.init_buffer(
            hlsl,
            "vs_main",
            ([_]gf.VertexInputLayoutEntry {
                .{ .name = "RowX", .slot = 0, .format = .F32x4, .per = .Instance },
                .{ .name = "RowY", .slot = 1, .format = .F32x4, .per = .Instance },
                .{ .name = "RowZ", .slot = 2, .format = .F32x4, .per = .Instance },
                .{ .name = "RowW", .slot = 3, .format = .F32x4, .per = .Instance },
                .{ .name = "Colour", .slot = 4, .format = .F32x4, .per = .Instance },
                .{ .name = "Velocity", .slot = 5, .format = .F32x4, .per = .Instance },
                .{ .name = "Scale", .slot = 6, .format = .F32x4, .per = .Instance },
            })[0..],
            .{},
            &en.engine().gfx
        );
        errdefer vertex_shader.deinit();
        
        const pixel_shader = try gf.PixelShader.init_buffer(
            hlsl,
            "ps_main",
            .{},
            &en.engine().gfx
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
                const particle_path = std.fs.path.join(en.engine().general_allocator, &[_][]const u8{ @import("build_options").engine_src_path, "engine/particles.hlsl" }) catch |err| {
                    std.log.err("failed to join paths: {}", .{err});
                    break :blk;
                };
                defer en.engine().general_allocator.free(particle_path);

                const shader_file = std.fs.openFileAbsolute(particle_path, .{}) catch |err| {
                    std.log.err("failed to open file: {}", .{err});
                    break :blk;
                };
                defer shader_file.close();

                const shader_hlsl = shader_file.readToEndAlloc(en.engine().general_allocator, 1024 * 1024) catch |err| {
                    std.log.err("failed to read file: {}", .{err});
                    break :blk;
                };
                defer en.engine().general_allocator.free(shader_hlsl);

                const new_shaders = init_shaders(shader_hlsl) catch |err| {
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
        view_matrix: zm.Mat, 
        proj_matrix: zm.Mat, 
        rtv: *const gf.RenderTargetView, 
        depth_view: *const gf.DepthStencilView, 
        gfx: *gf.GfxState
    ) void {
        // update all particle model matrices
        if (self.model_matrix_vertex_buffer.map(VertexBufferData, gfx)) |mapped_buffer| {
            defer mapped_buffer.unmap();

            const data = mapped_buffer.data_array(self.sort_particles.len);
            for (self.sort_particles, 0..) |*p, i| {
                data[i] = p.dat;
            }
        } else |_| {}

        // update camera constant buffer
        if (self.constant_buffer.map(ConstantBuffer, gfx)) |mapped_buffer| {
            defer mapped_buffer.unmap();

            mapped_buffer.data().* = ConstantBuffer {
                .view_matrix = view_matrix,
                .proj_matrix = proj_matrix,
                .flags = @bitCast(ConstantBufferFlags { 
                    .circle_shader = (self.settings.shape == .Circle),
                    .velocity_aligned = (self.settings.alignment == .VelocityAligned) 
                }),
            };
        } else |_| {}

        gfx.cmd_set_rasterizer_state(.{ .FillBack = true, });
        gfx.cmd_set_pixel_shader(&self.pixel_shader);

        gfx.cmd_set_render_target(&.{rtv}, depth_view);
        gfx.cmd_set_blend_state(&self.blend_state);

        gfx.cmd_set_vertex_shader(&self.vertex_shader);
        gfx.cmd_set_constant_buffers(.Vertex, 0, &.{&self.constant_buffer});
        gfx.cmd_set_constant_buffers(.Pixel, 0, &.{&self.constant_buffer});

        gfx.cmd_set_topology(.TriangleList);

        const model_matrix_stride: c_uint = @sizeOf(VertexBufferData);
        gfx.cmd_set_vertex_buffers(0, &.{
            .{ .buffer = &self.model_matrix_vertex_buffer, .stride = model_matrix_stride, .offset = 0 * @sizeOf([4]f32) },
            .{ .buffer = &self.model_matrix_vertex_buffer, .stride = model_matrix_stride, .offset = 1 * @sizeOf([4]f32) },
            .{ .buffer = &self.model_matrix_vertex_buffer, .stride = model_matrix_stride, .offset = 2 * @sizeOf([4]f32) },
            .{ .buffer = &self.model_matrix_vertex_buffer, .stride = model_matrix_stride, .offset = 3 * @sizeOf([4]f32) },
            .{ .buffer = &self.model_matrix_vertex_buffer, .stride = model_matrix_stride, .offset = 4 * @sizeOf([4]f32) },
            .{ .buffer = &self.model_matrix_vertex_buffer, .stride = model_matrix_stride, .offset = 5 * @sizeOf([4]f32) },
            .{ .buffer = &self.model_matrix_vertex_buffer, .stride = model_matrix_stride, .offset = 6 * @sizeOf([4]f32) },
        });

        gfx.cmd_draw_instanced(6, @intCast(self.particles.len), 0, 0);
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

const SHADER_HLSL = @embedFile("particles.hlsl");
