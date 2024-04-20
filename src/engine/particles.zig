const std = @import("std");
const zm = @import("zmath");
const w32 = @import("zwin32");
const tf = @import("transform.zig");
const tm = @import("time.zig");
const gf = @import("../gfx/gfx.zig");
const es = @import("../easings.zig");

pub const ParticleSystem = struct {
    const Self = @This();

    const VertexBufferData = extern struct {
        model_matrix: zm.Mat,
        colour: zm.F32x4,
    };
    
    const CameraConstantBuffer = extern struct {
        view_proj_matrix: zm.Mat,
        right_direction: zm.F32x4,
        up_direction: zm.F32x4,
    };

    settings: ParticleSystemSettings,
    particles: []?ParticleData,
    next_particle_index: usize = 0,

    alloc: std.mem.Allocator,
    rand: std.rand.DefaultPrng,

    seconds_to_next_particle: f32 = 0.0,

    vertex_shader: gf.VertexShader,
    pixel_shader: gf.PixelShader,
    model_matrix_vertex_buffer: gf.Buffer,
    camera_constant_buffer: gf.Buffer,
    blend_state: gf.BlendState,

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.particles);

        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.blend_state.deinit();
        self.model_matrix_vertex_buffer.deinit();
        self.camera_constant_buffer.deinit();
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
            })[0..],
            gfx.device
        );
        errdefer vertex_shader.deinit();
        
        const pixel_shader = try gf.PixelShader.init_buffer(
            SHADER_HLSL,
            "ps_main",
            gfx.device
        );
        errdefer pixel_shader.deinit();

        const model_matrix_vertex_buffer = try gf.Buffer.init(
            @sizeOf(VertexBufferData) * max_particles,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
            gfx.device
        );
        errdefer model_matrix_vertex_buffer.deinit();

        const camera_constant_buffer = try gf.Buffer.init(
            @sizeOf(CameraConstantBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx.device
        );
        errdefer camera_constant_buffer.deinit();

        var blend_state = gf.BlendState.init(([_]gf.BlendType{.Simple})[0..], gfx) catch unreachable;
        errdefer blend_state.deinit();

        const particles = try alloc.alloc(?ParticleData, max_particles);
        errdefer alloc.free(particles);
        @memset(particles, null);

        return Self {
            .settings = settings,
            .particles = particles,
            .alloc = alloc,
            .rand = std.rand.DefaultPrng.init(@intCast(std.time.microTimestamp())),
            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,
            .model_matrix_vertex_buffer = model_matrix_vertex_buffer,
            .camera_constant_buffer = camera_constant_buffer,
            .blend_state = blend_state,
        };
    }

    pub fn emit_particle(self: *Self) void {
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
            .transform = tf.Transform {
                .position = self.f32x4_variance(self.settings.spawn_offset, zm.f32x4s(self.settings.spawn_radius)),
                .scale = KeyFrame(zm.F32x4).calc(self.settings.scale[0..], 0.0),
            },
            .velocity = zm.f32x4(0.0, 1.0, 0.0, 0.0),
            .life_remaining = self.f32_variance(self.settings.particle_lifetime, self.settings.particle_lifetime_variance),
        };
    }

    pub fn update(self: *Self, time: *const tm.TimeState) void {
        const delta_time = zm.f32x4s(time.delta_time_f32());
        for (self.particles) |*maybe_particle| {
            if (maybe_particle.*) |*p| {
                p.life_remaining -= delta_time[0];
                if (p.life_remaining <= 0.0) { 
                    maybe_particle.* = null; 
                    continue;
                }
                const t = 1.0 - (p.life_remaining / self.settings.particle_lifetime);

                p.transform.scale = KeyFrame(zm.F32x4).calc(self.settings.scale[0..], t);
                p.colour = KeyFrame(zm.F32x4).hsv_calc(self.settings.colour[0..], t);
                p.transform.position += p.velocity * delta_time;
            }
        }

        self.seconds_to_next_particle -= delta_time[0];
        if (self.settings.spawn_rate != 0.0) {
            while (self.seconds_to_next_particle <= 0.0) {
                for (0..self.settings.burst_count) |_| {
                    self.emit_particle();
                }
                self.seconds_to_next_particle += @max(0.0, self.f32_variance(self.settings.spawn_rate, self.settings.spawn_rate_variance));
            }
        }
    }

    pub fn draw(
        self: *Self, 
        view_proj_matrix: zm.Mat, 
        camera_right: zm.F32x4,
        camera_up: zm.F32x4,
        rtv: *const gf.RenderTargetView, 
        depth_buffer: *const gf.DepthStencilView, 
        gfx: *gf.GfxState
    ) void {
        // update all particle model matrices
        if (self.model_matrix_vertex_buffer.map(VertexBufferData, gfx.context)) |mapped_buffer| {
            defer mapped_buffer.unmap();

            const zero_size = zm.scaling(0.0, 0.0, 0.0);
            for (self.particles, 0..) |*maybe_particle, i| {
                if (maybe_particle.*) |*p| {
                    @as([*c]VertexBufferData, @ptrCast(mapped_buffer.data))[i].model_matrix = p.transform.generate_model_matrix();
                    @as([*c]VertexBufferData, @ptrCast(mapped_buffer.data))[i].colour = p.colour;
                } else {
                    @as([*c]VertexBufferData, @ptrCast(mapped_buffer.data))[i].model_matrix = zero_size;
                    @as([*c]VertexBufferData, @ptrCast(mapped_buffer.data))[i].colour = zm.f32x4s(0.0);
                }
            }
        } else |_| {}

        // update camera constant buffer
        if (self.camera_constant_buffer.map(CameraConstantBuffer, gfx.context)) |mapped_buffer| {
            defer mapped_buffer.unmap();

            mapped_buffer.data.* = CameraConstantBuffer {
                .view_proj_matrix = view_proj_matrix,
                .right_direction = camera_right,
                .up_direction = camera_up,
            };
        } else |_| {}

        gfx.context.PSSetShader(self.pixel_shader.pso, null, 0);

        gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv.view), depth_buffer.view);
        gfx.context.OMSetBlendState(self.blend_state.state, null, 0xffffffff);

        gfx.context.VSSetShader(self.vertex_shader.vso, null, 0);
        gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_constant_buffer.buffer));

        gfx.context.IASetPrimitiveTopology(w32.d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);//
        gfx.context.IASetInputLayout(self.vertex_shader.layout);

        const model_matrix_stride: c_uint = @sizeOf(VertexBufferData);
        var offset: c_uint = 0;
        gfx.context.IASetVertexBuffers(0, 1, @ptrCast(&self.model_matrix_vertex_buffer.buffer), @ptrCast(&model_matrix_stride), @ptrCast(&offset));
        offset = 1 * @sizeOf([4]f32);
        gfx.context.IASetVertexBuffers(1, 1, @ptrCast(&self.model_matrix_vertex_buffer.buffer), @ptrCast(&model_matrix_stride), @ptrCast(&offset));
        offset = 2 * @sizeOf([4]f32);
        gfx.context.IASetVertexBuffers(2, 1, @ptrCast(&self.model_matrix_vertex_buffer.buffer), @ptrCast(&model_matrix_stride), @ptrCast(&offset));
        offset = 3 * @sizeOf([4]f32);
        gfx.context.IASetVertexBuffers(3, 1, @ptrCast(&self.model_matrix_vertex_buffer.buffer), @ptrCast(&model_matrix_stride), @ptrCast(&offset));
        offset = 4 * @sizeOf([4]f32);
        gfx.context.IASetVertexBuffers(4, 1, @ptrCast(&self.model_matrix_vertex_buffer.buffer), @ptrCast(&model_matrix_stride), @ptrCast(&offset));

        gfx.context.DrawInstanced(6, @intCast(self.particles.len), 0, 0);
    }

    fn f32_variance(self: *Self, value: f32, variance: f32) f32 {
        return value + (((self.rand.random().float(f32) - 0.5) * 2.0) * variance);
    }

    fn f32x4_variance(self: *Self, value: zm.F32x4, variance: zm.F32x4) zm.F32x4 {
        const random_v = zm.f32x4(
            self.rand.random().float(f32),
            self.rand.random().float(f32),
            self.rand.random().float(f32),
            self.rand.random().float(f32)
        );
        return value + (((random_v - zm.f32x4s(0.5)) * zm.f32x4s(2.0)) * variance);
    }
};

pub const ParticleData = struct {
    transform: tf.Transform = .{},
    colour: zm.F32x4 = zm.f32x4s(0.0),
    velocity: zm.F32x4 = zm.f32x4s(0.0),
    angular_velocity: zm.F32x4 = zm.f32x4s(0.0),
    life_remaining: f32 = 0.0,
};

pub const ParticleSystemSettings = struct {
    spawn_offset: zm.F32x4,
    spawn_radius: f32,
    spawn_rate: f32,
    spawn_rate_variance: f32 = 0.0,
    burst_count: u32 = 1,

    particle_lifetime: f32 = 1.0,
    particle_lifetime_variance: f32 = 0.0,

    scale: [4]?KeyFrame(zm.F32x4) = [1]?KeyFrame(zm.F32x4){null} ** 4,
    colour: [4]?KeyFrame(zm.F32x4) = [1]?KeyFrame(zm.F32x4){null} ** 4,
};

pub fn KeyFrame(comptime T: type) type {
    return struct {
        easing_into: es.Easing = .OutLinear,
        key_time: f32,
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
            for (0..arr.len) |i| {
                if (arr[i] == null) {
                    break;
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
            for (0..arr.len) |i| {
                if (arr[i] == null) {
                    break;
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
\\  };
\\  
\\  struct vs_out
\\  {
\\      float4 position : SV_POSITION;
\\      float4 colour: Colour;
\\  };
\\
\\  cbuffer camera_constant_buffer: register(b0)
\\  {
\\      row_major float4x4 vp_matrix;
\\      float4 right_direction;
\\      float4 up_direction;
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
\\      float4x4 mvp = mul(model_matrix, vp_matrix);
\\
\\      float4 pos = right_direction * (x - 0.5) + up_direction * (y - 0.5);
\\      pos.w = 1.0;
\\
\\      output.position = mul(pos, mvp);
\\
\\      output.colour = input.colour;
\\  
\\      return output;
\\  }
\\  
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      return input.colour;
\\  }
;
