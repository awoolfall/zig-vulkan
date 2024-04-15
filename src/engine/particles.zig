const std = @import("std");
const zm = @import("zmath");
const w32 = @import("zwin32");
const tf = @import("transform.zig");
const tm = @import("time.zig");
const gf = @import("../gfx/gfx.zig");

pub const ParticleSystem = struct {
    const Self = @This();

    const VertexBufferData = extern struct {
        model_matrix: zm.Mat,
    };
    
    const CameraConstantBuffer = extern struct {
        view_proj_matrix: zm.Mat,
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

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.particles);

        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
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
        std.log.info("found free particle in {} iterations", .{count});

        var random_v = zm.f32x4(
            self.rand.random().float(f32),
            self.rand.random().float(f32),
            self.rand.random().float(f32),
            self.rand.random().float(f32)
        );
        random_v = (random_v - zm.f32x4s(0.5)) * zm.f32x4s(2.0);

        self.particles[self.next_particle_index] = ParticleData {
            .transform = tf.Transform {
                .position = self.settings.spawn_offset + zm.f32x4s(self.settings.spawn_radius) * random_v,
                .scale = zm.f32x4s(0.1),
            },
            .velocity = zm.f32x4(0.0, 1.0, 0.0, 0.0),
            .life_remaining = 1.0,
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

                p.transform.position += p.velocity * delta_time;
            }
        }

        self.seconds_to_next_particle -= delta_time[0];
        while (self.seconds_to_next_particle <= 0.0) {
            self.emit_particle();
            self.seconds_to_next_particle += self.settings.spawn_rate + self.settings.spawn_rate_variance * (self.rand.random().float(f32) - 0.5);
        }
    }

    pub fn draw(self: *Self, view_proj_matrix: zm.Mat, rtv: *const gf.RenderTargetView, gfx: *gf.GfxState) void {
        // update all particle model matrices
        if (self.model_matrix_vertex_buffer.map(VertexBufferData, gfx.context)) |mapped_buffer| {
            defer mapped_buffer.unmap();

            const zero_size = zm.scaling(0.0, 0.0, 0.0);
            for (self.particles, 0..) |*maybe_particle, i| {
                if (maybe_particle.*) |*p| {
                    @as([*c]VertexBufferData, @ptrCast(mapped_buffer.data))[i].model_matrix = p.transform.generate_model_matrix();
                } else {
                    @as([*c]VertexBufferData, @ptrCast(mapped_buffer.data))[i].model_matrix = zero_size;
                }
            }
        } else |_| {}

        // update camera constant buffer
        if (self.camera_constant_buffer.map(CameraConstantBuffer, gfx.context)) |mapped_buffer| {
            defer mapped_buffer.unmap();

            mapped_buffer.data.view_proj_matrix = view_proj_matrix;
        } else |_| {}

        gfx.context.PSSetShader(self.pixel_shader.pso, null, 0);

        gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv.view), null);
        gfx.context.OMSetBlendState(null, null, 0xffffffff);

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

        gfx.context.DrawInstanced(6, @intCast(self.particles.len), 0, 0);
    }
};

pub const ParticleData = struct {
    transform: tf.Transform = .{},
    velocity: zm.F32x4 = zm.f32x4s(0.0),
    life_remaining: f32 = 0.0,
};

pub const ParticleSystemSettings = struct {
    spawn_offset: zm.F32x4,
    spawn_radius: f32,
    spawn_rate: f32,
    spawn_rate_variance: f32,
};

const SHADER_HLSL = \\
\\  struct vs_in 
\\  {
\\      float4 rowX : RowX;
\\      float4 rowY : RowY;
\\      float4 rowZ : RowZ;
\\      float4 rowW : RowW;
\\  };
\\  
\\  struct vs_out
\\  {
\\      float4 position : SV_POSITION;
\\  };
\\
\\  cbuffer camera_constant_buffer: register(b0)
\\  {
\\      row_major float4x4 vp_matrix;
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
\\      output.position = mul(float4(x, y, 0.0, 1.0), mvp);
\\  
\\      return output;
\\  }
\\  
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      return float4(0.0, 0.0, 0.0, 1.0);
\\  }
;
