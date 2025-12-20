const std = @import("std");
const zm = @import("zmath");
const zn = @import("znoise");
const eng = @import("self");
const Transform = eng.Transform;
const tm = eng.time;
const gf = eng.gfx;
const es = eng.easings;
const ms = eng.mesh;
const sr = eng.serialize;
const Camera = eng.camera.Camera;

pub const ParticleRenderData = extern struct {
    position: zm.F32x4 = zm.f32x4s(0.0),
    colour: zm.F32x4 = zm.f32x4s(0.0),
    velocity: zm.F32x4 = zm.f32x4s(0.0),
    scale: zm.F32x4 = zm.f32x4s(0.0),
};

pub const ParticleExtraData = struct {
    rand: std.Random.DefaultPrng,
    rand_vec: zm.F32x4 = zm.f32x4s(0.0),
    alive_time: f32 = std.math.floatMax(f32),
    life_duration: f32 = 0.0,
    last_curl: zm.F32x4 = zm.f32x4s(0.0),

    pub fn particle_is_alive(self: *const ParticleExtraData) bool {
        return self.alive_time < self.life_duration;
    }
};


pub const ParticleSystem = struct {
    const Self = @This();
    
    alloc: std.mem.Allocator,

    settings: ParticleSystemSettings,
    particles_extra_data: []ParticleExtraData,
    particles_render_data: []ParticleRenderData,
    next_particle_index: usize = 0,

    rand: std.Random.DefaultPrng,
    noise: zn.FnlGenerator,

    seconds_to_next_particle: f32 = 0.0,

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.particles_extra_data);
        self.alloc.free(self.particles_render_data);
        self.settings.deinit(self.alloc);
    }

    pub fn init(alloc: std.mem.Allocator, settings: ParticleSystemSettings) !Self {
        const particles_extra_data = try alloc.alloc(ParticleExtraData, settings.max_particles);
        errdefer alloc.free(particles_extra_data);
        @memset(particles_extra_data, ParticleExtraData {
            .rand = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp())),
        });

        const particles_render_data = try alloc.alloc(ParticleRenderData, settings.max_particles);
        errdefer alloc.free(particles_render_data);
        @memset(particles_render_data, ParticleRenderData {});

        const owned_settings = try settings.clone(alloc);
        errdefer owned_settings.deinit(alloc);

        return Self {
            .settings = owned_settings,
            .particles_extra_data = particles_extra_data,
            .particles_render_data = particles_render_data,
            .alloc = alloc,
            .rand = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp())),
            .noise = zn.FnlGenerator{},
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: ParticleSystem) !std.json.Value {
        return try sr.serialize_value(ParticleSystemSettings, alloc, value.settings);
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !ParticleSystem {
        const settings = try sr.deserialize_value(ParticleSystemSettings, alloc, value);
        return try ParticleSystem.init(alloc, settings);
    }

    pub fn resize(self: *Self, new_particle_count: usize) !void {
        self.settings.max_particles = @truncate(new_particle_count);

        self.particles_extra_data = try self.alloc.realloc(self.particles_extra_data, self.settings.max_particles);
        self.particles_render_data = try self.alloc.realloc(self.particles_render_data, self.settings.max_particles);
    }

    pub fn set_settings(self: *Self, new_settings: *const ParticleSystemSettings) !void {
        const owned_settings = try new_settings.clone(self.alloc);
        errdefer owned_settings.deinit();

        self.settings.deinit(self.alloc);
        self.settings = owned_settings;
        if (self.particles_extra_data.len < self.settings.max_particles) {
            self.resize(self.settings.max_particles);
        }
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
        while (self.particles_extra_data[self.next_particle_index].particle_is_alive()) {
            count += 1;
            self.next_particle_index = (self.next_particle_index + 1) % self.particles_render_data.len;
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

        self.particles_render_data[self.next_particle_index] = ParticleRenderData {
            .position = initial_position,
            .scale = KeyFrame(zm.F32x4).calc(self.settings.scale.items, 0.0),
            .velocity = self.settings.initial_velocity,
            .colour = KeyFrame(zm.F32x4).calc(self.settings.colour.items, 0.0),
        };
        self.particles_extra_data[self.next_particle_index] = ParticleExtraData {
            .rand = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp())),
            .rand_vec = random_v(self.rand.random()),
            .alive_time = 0.0,
            .life_duration = self.f32_variance(self.settings.particle_lifetime, self.settings.particle_lifetime_variance),
            .last_curl = zm.f32x4s(0.0),
        };
    }

    pub fn update(self: *Self, time: *const tm.TimeState) void {
        const delta_time = zm.f32x4s(time.delta_time_f32());
        const current_time = zm.f32x4s(@floatCast(time.time_since_start_of_app()));

        for (self.particles_extra_data, 0..) |_, i| {
            const p_extra = &self.particles_extra_data[i];
            const p_render = &self.particles_render_data[i];

            p_extra.alive_time += delta_time[0];
            if (p_extra.alive_time > p_extra.life_duration) {
                p_render.scale = zm.f32x4s(0.0);
                continue;
            }

            const t = (p_extra.alive_time / p_extra.life_duration);

            for (self.settings.forces.items) |fo| {
                switch (fo) {
                    .Constant => |v| { p_render.velocity += (v * delta_time); },
                    .ConstantRand => |force| { 
                        const noise_vec = zm.f32x4(
                            self.noise.noise2(current_time[0]*100.0, p_extra.rand_vec[0]*1000.0),
                            self.noise.noise2(current_time[0]*100.0, p_extra.rand_vec[1]*1000.0),
                            self.noise.noise2(current_time[0]*100.0, p_extra.rand_vec[2]*1000.0),
                            self.noise.noise2(current_time[0]*100.0, p_extra.rand_vec[3]*1000.0),
                        );
                        p_render.velocity += ((noise_vec - zm.f32x4s(0.5)) * zm.f32x4s(force) * delta_time); 
                    },
                    .Curl => |force| {
                        p_render.velocity += self.compute_curl_frame(p_render, p_extra) * zm.f32x4s(force) * delta_time;
                    },
                    .Drag => |force| {
                        p_render.velocity -= p_render.velocity * zm.f32x4s(force) * delta_time;
                    },
                    .Vortex => |d| {
                        const vec_to_p = p_render.position - self.settings.spawn_origin;
                        // vortex
                        var force = zm.cross3(zm.normalize3(vec_to_p), zm.normalize3(d.axis)) * zm.f32x4s(d.force);
                        // origin pull, @TODO: maybe make this pull to the axis line?
                        force += -zm.normalize3(vec_to_p) * zm.f32x4s(d.origin_pull);

                        p_render.velocity += force * delta_time;
                    },
                }
            }

            p_render.scale = KeyFrame(zm.F32x4).calc(self.settings.scale.items, t);
            p_render.colour = KeyFrame(zm.F32x4).hsv_calc(self.settings.colour.items, t);
            p_render.position += p_render.velocity * zm.f32x4(1.0, 1.0, 1.0, 0.0) * delta_time;
        }


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

    fn compute_curl_frame(self: *Self, p_render: *ParticleRenderData, p_extra: *ParticleExtraData) zm.F32x4 {
        // jitter particle by epsilon so we can get a rate of change reading
        // randomly swap between jitterring by +/- eps so it averages to 0 movement
        const eps: f32 = 0.0001 * (@as(f32, @floatFromInt(@intFromBool(self.rand.random().boolean()))) * 2.0 - 1.0);
        p_render.position += zm.f32x4(eps, eps, eps, 0.0);

        const position = p_render.position * zm.f32x4s(50.0);

        //Find rate of change
        const x1 = self.noise3(zm.f32x4(position[0], position[1], position[2], 0.0));

        const v = zm.f32x4(
            p_extra.last_curl[2] - x1[2] - p_extra.last_curl[1] - x1[1],
            p_extra.last_curl[0] - x1[0] - p_extra.last_curl[2] - x1[2],
            p_extra.last_curl[1] - x1[1] - p_extra.last_curl[0] - x1[0],
            0.0
        );

        p_extra.last_curl = x1;

        //Curl
        const divisor = 1.0 / (0.0002);
        return zm.normalize3(v * zm.f32x4s(divisor));
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

pub const ScaleKeyFrame = KeyFrame(zm.F32x4);
pub const ColourKeyFrame = KeyFrame(zm.F32x4);

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

    scale: std.ArrayList(ScaleKeyFrame) = .empty,
    colour: std.ArrayList(ColourKeyFrame) = .empty,
    forces: std.ArrayList(ForceEnum) = .empty,

    pub fn deinit(self: *ParticleSystemSettings, alloc: std.mem.Allocator) void {
        self.scale.deinit(alloc);
        self.colour.deinit(alloc);
        self.forces.deinit(alloc);
    }

    pub fn clone(self: *const ParticleSystemSettings, alloc: std.mem.Allocator) !ParticleSystemSettings {
        var new_settings = self.*;
        new_settings.scale = .empty;
        new_settings.colour = .empty;
        new_settings.forces = .empty;
        errdefer new_settings.deinit(alloc);

        try new_settings.scale.appendSlice(alloc, self.scale.items);
        try new_settings.colour.appendSlice(alloc, self.colour.items);
        try new_settings.forces.appendSlice(alloc, self.forces.items);

        return new_settings;
    }

    pub fn serialize(alloc: std.mem.Allocator, value: ParticleSystemSettings) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("max_particles", try sr.serialize_value(u32, alloc, value.max_particles));

        try object.put("alignment", try sr.serialize_value(ParticleAlignment, alloc, value.alignment));
        try object.put("shape", try sr.serialize_value(ParticleShape, alloc, value.shape));

        try object.put("spawn_origin", try sr.serialize_value(zm.F32x4, alloc, value.spawn_origin));
        try object.put("spawn_offset", try sr.serialize_value(zm.F32x4, alloc, value.spawn_offset));
        try object.put("spawn_radius", try sr.serialize_value(f32, alloc, value.spawn_radius));
        try object.put("spawn_rate", try sr.serialize_value(f32, alloc, value.spawn_rate));
        try object.put("spawn_rate_variance", try sr.serialize_value(f32, alloc, value.spawn_rate_variance));
        try object.put("burst_count", try sr.serialize_value(u32, alloc, value.burst_count));

        try object.put("particle_lifetime", try sr.serialize_value(f32, alloc, value.particle_lifetime));
        try object.put("particle_lifetime_variance", try sr.serialize_value(f32, alloc, value.particle_lifetime_variance));

        try object.put("initial_velocity", try sr.serialize_value(zm.F32x4, alloc, value.initial_velocity));

        try object.put("scale_keys", try sr.serialize_value([]ScaleKeyFrame, alloc, value.scale.items));
        try object.put("colour_keys", try sr.serialize_value([]ColourKeyFrame, alloc, value.colour.items));
        try object.put("forces", try sr.serialize_value([]ForceEnum, alloc, value.forces.items));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !ParticleSystemSettings {
        var settings = ParticleSystemSettings{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("max_particles")) |v| blk: { settings.max_particles = sr.deserialize_value(u32, alloc, v) catch break :blk; }

        if (object.get("alignment")) |v| blk: { settings.alignment = sr.deserialize_value(ParticleAlignment, alloc, v) catch break :blk; }
        if (object.get("shape")) |v| blk: { settings.shape = sr.deserialize_value(ParticleShape, alloc, v) catch break :blk; }

        if (object.get("spawn_origin")) |v| blk: { settings.spawn_origin = sr.deserialize_value(zm.F32x4, alloc, v) catch break :blk; }
        if (object.get("spawn_offset")) |v| blk: { settings.spawn_offset = sr.deserialize_value(zm.F32x4, alloc, v) catch break :blk; }
        if (object.get("spawn_radius")) |v| blk: { settings.spawn_radius = sr.deserialize_value(f32, alloc, v) catch break :blk; }
        if (object.get("spawn_rate")) |v| blk: { settings.spawn_rate = sr.deserialize_value(f32, alloc, v) catch break :blk; }
        if (object.get("spawn_rate_variance")) |v| blk: { settings.spawn_rate_variance = sr.deserialize_value(f32, alloc, v) catch break :blk; }
        if (object.get("burst_count")) |v| blk: { settings.burst_count = sr.deserialize_value(u32, alloc, v) catch break :blk; }

        if (object.get("particle_lifetime")) |v| blk: { settings.particle_lifetime = sr.deserialize_value(f32, alloc, v) catch break :blk; }
        if (object.get("particle_lifetime_variance")) |v| blk: { settings.particle_lifetime_variance = sr.deserialize_value(f32, alloc, v) catch break :blk; }

        if (object.get("initial_velocity")) |v| blk: { settings.initial_velocity = sr.deserialize_value(zm.F32x4, alloc, v) catch break :blk; }

        if (object.get("scale_keys")) |v| blk: {
            const scale_slice = sr.deserialize_value([]ScaleKeyFrame, alloc, v) catch break :blk;
            defer alloc.free(scale_slice);

            settings.scale.clearRetainingCapacity();
            settings.scale.appendSlice(alloc, scale_slice) catch break :blk;
        }
        if (object.get("colour_keys")) |v| blk: {
            const colour_slice = sr.deserialize_value([]ColourKeyFrame, alloc, v) catch break :blk;
            defer alloc.free(colour_slice);

            settings.colour.clearRetainingCapacity();
            settings.colour.appendSlice(alloc, colour_slice) catch break :blk;
        }
        if (object.get("forces")) |v| blk: {
            const forces_slice = sr.deserialize_value([]ForceEnum, alloc, v) catch break :blk;
            defer alloc.free(forces_slice);

            settings.forces.clearRetainingCapacity();
            settings.forces.appendSlice(alloc, forces_slice) catch break :blk;
        }

        return settings;
    }
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

pub const StatelessPRNG = struct {
    /// Generates a pseudo-random u64 from a seed using a hash-based approach
    pub fn random_u64(seed: u64) u64 {
        return std.Random.SplitMix64.init(seed).next();
    }
    
    /// Generates a pseudo-random u32 from a seed
    pub fn random_u32(seed: u64) u32 {
        return @truncate(random_u64(seed));
    }
    
    /// Generates a pseudo-random f64 in range [0.0, 1.0) from a seed
    pub fn random_f64(seed: u64) f64 {
        const max_u64 = @as(f64, @floatFromInt(std.math.maxInt(u64)));
        return @as(f64, @floatFromInt(random_u64(seed))) / max_u64;
    }
    
    /// Generates a pseudo-random f32 in range [0.0, 1.0) from a seed
    pub fn random_f32(seed: u64) f32 {
        const max_u32 = @as(f32, @floatFromInt(std.math.maxInt(u32)));
        return @as(f32, @floatFromInt(random_u32(seed))) / max_u32;
    }
    
    /// Generates a pseudo-random integer in range [0, max) from a seed
    pub fn random_range(seed: u64, max: u64) u64 {
        if (max == 0) return 0;
        return random_u64(seed) % max;
    }
    
    /// Generates a pseudo-random integer in range [min, max] from a seed
    pub fn random_range_inclusive(seed: u64, min: u64, max: u64) u64 {
        if (max <= min) return min;
        return min + random_range(seed, max - min + 1);
    }
};
