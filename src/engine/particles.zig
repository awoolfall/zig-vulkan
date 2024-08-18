const std = @import("std");
const zm = @import("zmath");
const zn = @import("znoise");
const tf = @import("transform.zig");
const tm = @import("time.zig");
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
    rand: std.rand.DefaultPrng,
    noise: zn.FnlGenerator,

    seconds_to_next_particle: f32 = 0.0,

    vertex_shader: gf.VertexShader,
    pixel_shader: gf.PixelShader,
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
    }

    pub fn init(alloc: std.mem.Allocator, max_particles: u32, settings: ParticleSystemSettings, gfx: *gf.GfxState) !Self {
        const vertex_shader = try gf.VertexShader.init_buffer(
            SHADER_HLSL,
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
            gfx
        );
        errdefer vertex_shader.deinit();
        
        const pixel_shader = try gf.PixelShader.init_buffer(
            SHADER_HLSL,
            "ps_main",
            gfx
        );
        errdefer pixel_shader.deinit();

        const model_matrix_vertex_buffer = try gf.Buffer.init(
            @sizeOf(VertexBufferData) * max_particles,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        errdefer model_matrix_vertex_buffer.deinit();

        const constant_buffer = try gf.Buffer.init(
            @sizeOf(ConstantBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        errdefer constant_buffer.deinit();

        var blend_state = gf.BlendState.init(([_]gf.BlendType{.Simple})[0..], gfx) catch unreachable;
        errdefer blend_state.deinit();

        const particles = try alloc.alloc(?ParticleData, max_particles);
        errdefer alloc.free(particles);
        @memset(particles, null);

        const sort_particles = try alloc.alloc(ArrDat, max_particles);
        errdefer alloc.free(sort_particles);

        return Self {
            .settings = settings,
            .particles = particles,
            .alloc = alloc,
            .rand = std.rand.DefaultPrng.init(@intCast(std.time.microTimestamp())),
            .noise = zn.FnlGenerator{},
            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,
            .model_matrix_vertex_buffer = model_matrix_vertex_buffer,
            .constant_buffer = constant_buffer,
            .blend_state = blend_state,
            .sort_particles = sort_particles,
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

        self.particles[self.next_particle_index] = ParticleData {
            .rand = std.rand.DefaultPrng.init(@intCast(std.time.microTimestamp())),
            .rand_vec = random_v(self.rand.random()),
            .transform = tf.Transform {
                .position = self.f32x4_variance(self.settings.spawn_origin + self.settings.spawn_offset, zm.f32x4s(self.settings.spawn_radius)),
                .scale = KeyFrame(zm.F32x4).calc(self.settings.scale[0..], 0.0),
            },
            .velocity = self.settings.initial_velocity,
            .life_remaining = self.f32_variance(self.settings.particle_lifetime, self.settings.particle_lifetime_variance),
            .last_curl = zm.f32x4s(0.0),
        };
    }

    pub fn update(self: *Self, time: *const tm.TimeState) void {
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

                for (self.settings.forces) |f| {
                    if (f) |fo| {
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
                                var force = zm.cross3(zm.normalize3(vec_to_p), d.axis) * zm.f32x4s(d.force);
                                // origin pull, @TODO: maybe make this pull to the axis line?
                                force += -zm.normalize3(vec_to_p) * zm.f32x4s(d.origin_pull);
                                
                                p.velocity += force * delta_time;
                            },
                        }
                    }
                }

                p.transform.scale = KeyFrame(zm.F32x4).calc(self.settings.scale[0..], t);
                p.colour = KeyFrame(zm.F32x4).hsv_calc(self.settings.colour[0..], t);
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

        gfx.cmd_set_render_target(rtv, depth_view);
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

    fn random_v(rand: std.rand.Random) zm.F32x4 {
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
    rand: std.rand.DefaultPrng,
    rand_vec: zm.F32x4,
    transform: tf.Transform,
    velocity: zm.F32x4 = zm.f32x4s(0.0),
    colour: zm.F32x4 = zm.f32x4s(0.0),
    life_remaining: f32 = 0.0,
    last_curl: zm.F32x4,
};

pub const ParticleSystemSettings = struct {
    alignment: ParticleAlignment = .Transform,
    shape: ParticleShape = .Box,

    spawn_origin: zm.F32x4,
    spawn_offset: zm.F32x4,
    spawn_radius: f32,
    spawn_rate: f32,
    spawn_rate_variance: f32 = 0.0,
    burst_count: u32 = 1,

    particle_lifetime: f32 = 1.0,
    particle_lifetime_variance: f32 = 0.0,

    initial_velocity: zm.F32x4 = zm.f32x4s(0.0),

    scale: [4]?KeyFrame(zm.F32x4) = [1]?KeyFrame(zm.F32x4){null} ** 4,
    colour: [4]?KeyFrame(zm.F32x4) = [1]?KeyFrame(zm.F32x4){null} ** 4,
    forces: [4]?ForceEnum = [1]?ForceEnum{null} ** 4,
};

pub const ParticleAlignment = union(enum) {
    Transform: void,
    Billboard: void,
    VelocityAligned: f32,
};

pub const ParticleShape = union(enum) {
    Box: void,
    Circle: void,
    Texture: *const gf.TextureView2D, // @TODO
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

        pub fn calc(arr: []?KeyFrame(T), t: f32) T {
            for (1..arr.len) |i| {
                if (arr[i] == null) {
                    if (arr[i - 1]) |*v| {
                        return v.value;
                    } else {
                        return default_value();
                    } 
                }
                if (arr[i].?.key_time >= t) {
                    if (i == 0) { 
                        return arr[i].?.value;
                    } else {
                        return arr[i].?.calc_(&arr[i-1].?, t);
                    }
                }
            }
            return default_value();
        }

        pub fn hsv_calc(arr: []?KeyFrame(zm.F32x4), t: f32) zm.F32x4 {
            for (1..arr.len) |i| {
                if (arr[i] == null) {
                    if (arr[i - 1]) |*v| {
                        return v.value;
                    } else {
                        return zm.f32x4s(0.0);
                    } 
                }
                if (arr[i].?.key_time >= t) {
                    if (i == 0) { 
                        return arr[i].?.value;
                    } else {
                        var s = arr[i].?;
                        s.value = zm.rgbToHsv(s.value);
                        var p = arr[i-1].?;
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

const SHADER_HLSL = \\
\\  struct vs_in 
\\  {
\\      float4 rowX : RowX;
\\      float4 rowY : RowY;
\\      float4 rowZ : RowZ;
\\      float4 rowW : RowW;
\\      float4 colour: Colour;
\\      float4 velocity: Velocity;
\\      float4 scale: Scale;
\\  };
\\  
\\  struct vs_out
\\  {
\\      float4 position : SV_POSITION;
\\      float2 uv: TEXCOORD0;
\\      float2 uv_scale: TEXCOORD1;
\\      float4 colour: Colour;
\\  };
\\
\\  cbuffer camera_constant_buffer: register(b0)
\\  {
\\      row_major float4x4 v_matrix;
\\      row_major float4x4 p_matrix;
\\      uint flags;
\\  }
\\  
\\  vs_out vs_main(uint vertId : SV_VertexID, vs_in input)
\\  {
\\      vs_out output = (vs_out) 0;
\\      float4x4 model_matrix = float4x4(input.rowX, input.rowY, input.rowZ, input.rowW);
\\  
\\      float x = float(((uint(vertId) + 2u) / 3u)%2u);
\\      float y = float(((uint(vertId) + 1u) / 3u)%2u);
\\  
\\      float4x4 mv = mul(model_matrix, v_matrix);
\\      float4x4 mv_noscale = mv;
\\      mv_noscale[0] = float4(1.0, 0.0, 0.0, mv[0][3]);
\\      mv_noscale[1] = float4(0.0, 1.0, 0.0, mv[1][3]);
\\      mv_noscale[2] = float4(0.0, 0.0, 1.0, mv[2][3]);
\\      float4x4 mvp = mul(mv, p_matrix);
\\      float4x4 mvp_noscale = mul(mv_noscale, p_matrix);
\\
\\      float4 right_v = float4(1.0, 0.0, 0.0, 0.0);
\\      float4 up_v = float4(0.0, 1.0, 0.0, 0.0);
\\      if ((flags & 2) && length(input.velocity.xyz) > 0.0) {
\\          float4 cam_vel = mul(input.velocity, mvp);
\\          cam_vel = float4(cam_vel.xyz, 0.0) + float4(normalize(cam_vel.xyz), 0.0);
\\          right_v = normalize(float4(cross(normalize(cam_vel.xyz), float3(0.0, 0.0, 1.0)), 0.0));
\\          up_v = cam_vel;
\\      }
\\      float4 pos = right_v * (x - 0.5) * input.scale.x + up_v * (y - 0.5) * input.scale.y;
\\      pos.w = 1.0;
\\
\\      output.position = mul(pos, mvp_noscale);
\\      output.uv = float2(x, y);
\\      output.uv = (output.uv - 0.5) * 2.0;
\\      output.uv_scale = float2(1.0, length(up_v));
\\
\\      output.colour = input.colour;
\\
\\      return output;
\\  }
\\
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      float distance = 0.0;
\\      float2 uv = input.uv;
\\
\\      // is_circle
\\      if (flags & 1) {
\\          // if velocity aligned we want to extend the middle of the circle while keeping
\\          // the ends perfectly circular. Manipulate uvs to create this (saber-like) effect
\\          uv.y = (uv.y * input.uv_scale.y) - (uv.y / abs(uv.y)) * (input.uv_scale.y - 1.0);
\\          if ((uv.y * input.uv.y) < 0.0) {
\\              uv.y = 0.0;
\\          }
\\
\\          distance = uv.x * uv.x + uv.y * uv.y;
\\          distance = sqrt(distance);
\\          distance = smoothstep(0.0, 1.00, distance);
\\      }
\\  
\\      return input.colour * float4(1.0, 1.0, 1.0, 1.0 - distance);
\\  }
;
