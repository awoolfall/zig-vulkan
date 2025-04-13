const std = @import("std");
pub const zphy = @import("zphysics");
const zm = @import("zmath");
pub const BodyId = zphy.BodyId;
const en = @import("../root.zig");
const engine = en.engine;
const ms = @import("../engine/mesh.zig");
const as = @import("../asset/asset.zig");
const tm = @import("../engine/time.zig");
const Transform = @import("../engine/transform.zig");
const _gfx = @import("../gfx/gfx.zig");

inline fn debug_renderer_enabled() bool {
    return @import("../platform/platform.zig").GfxPlatform == @import("../gfx/platform/d3d11.zig").GfxStateD3D11;
}
const DebugRenderer = if (debug_renderer_enabled()) @import("physics_debug_renderer.zig").D3D11DebugRenderer else void;

pub const PhysicsSystem = struct {
    const Self = @This();
    const UpdateRateHz = 60.0;
    const UpdateRateNs: u64 = std.time.ns_per_s / @as(u64, @intFromFloat(60.0));

    _allocator: std.mem.Allocator,
    _interfaces: struct {
        broad_phase_layer_interface: *BroadPhaseLayerInterface,
        object_vs_broad_phase_layer_filter: *ObjectVsBroadPhaseLayerFilter,
        object_layer_pair_filter: *ObjectLayerPairFilter,
    },
    _debug_renderer: if (debug_renderer_enabled()) *DebugRenderer else void,
    asset_manager: *as.AssetManager,
    zphy: *zphy.PhysicsSystem, 
    last_update_time: std.time.Instant,
    last_update_time_offset: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, asset_manager: *as.AssetManager, gfx: *_gfx.GfxState) !Self {
        try zphy.init(alloc, .{});
        errdefer zphy.deinit();

        const broad_phase_layer_interface = try alloc.create(BroadPhaseLayerInterface);
        errdefer alloc.destroy(broad_phase_layer_interface);
        broad_phase_layer_interface.* = BroadPhaseLayerInterface.init();

        const object_vs_broad_phase_layer_filter = try alloc.create(ObjectVsBroadPhaseLayerFilter);
        errdefer alloc.destroy(object_vs_broad_phase_layer_filter);
        object_vs_broad_phase_layer_filter.* = ObjectVsBroadPhaseLayerFilter {};

        const object_layer_pair_filter = try alloc.create(ObjectLayerPairFilter);
        errdefer alloc.destroy(object_layer_pair_filter);
        object_layer_pair_filter.* = ObjectLayerPairFilter {};

        const physics_system = try zphy.PhysicsSystem.create(
            @as(*const zphy.BroadPhaseLayerInterface, @ptrCast(broad_phase_layer_interface)),
            @as(*const zphy.ObjectVsBroadPhaseLayerFilter, @ptrCast(object_vs_broad_phase_layer_filter)),
            @as(*const zphy.ObjectLayerPairFilter, @ptrCast(object_layer_pair_filter)),
            .{
                .max_bodies = 2048,
                .num_body_mutexes = 0,
                .max_body_pairs = 2048,
                .max_contact_constraints = 1024,
            },
        );
        errdefer physics_system.destroy();

        var debug_renderer: ?*DebugRenderer = null;
        if (debug_renderer_enabled()) {
            debug_renderer = try alloc.create(DebugRenderer);
            debug_renderer.?.* = try DebugRenderer.init(gfx);

            try zphy.DebugRenderer.createSingleton(debug_renderer.?);
            errdefer zphy.DebugRenderer.destroySingleton();
        }
        errdefer if (debug_renderer) |r| alloc.destroy(r);

        return Self {
            ._allocator = alloc,
            ._interfaces = .{
                .broad_phase_layer_interface = broad_phase_layer_interface,
                .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
                .object_layer_pair_filter = object_layer_pair_filter,
            },
            ._debug_renderer = if (debug_renderer_enabled()) debug_renderer.? else undefined,
            .asset_manager = asset_manager,
            .zphy = physics_system,
            .last_update_time = std.time.Instant.now() catch unreachable,
        };
    }

    pub fn deinit(self: *Self) void {
        self.zphy.destroy();
        if (debug_renderer_enabled()) {
            zphy.DebugRenderer.destroySingleton();
            self._debug_renderer.deinit();
            self._allocator.destroy(self._debug_renderer);
        }
        self._allocator.destroy(self._interfaces.broad_phase_layer_interface);
        self._allocator.destroy(self._interfaces.object_vs_broad_phase_layer_filter);
        self._allocator.destroy(self._interfaces.object_layer_pair_filter);
        zphy.deinit();
    }

    pub fn update(self: *Self) void {
        const entity_list = &engine().entities;
        const time = &engine().time;

        // find out how many times we need to update to hit UpdateRateHz
        const ns_since_with_offset = time.frame_start_time.since(self.last_update_time) + self.last_update_time_offset;
        const times_to_update = ns_since_with_offset / UpdateRateNs;

        // if we haven't hit UpdateRateHz yet, return
        if (times_to_update == 0) {
            return;
        }

        // update last_update_time and last_update_time_offset
        // last_update_time_offset accounts for the portion of time between the 
        // last sub-frame physics update and the actual frame time 
        self.last_update_time = time.frame_start_time;
        self.last_update_time_offset = ns_since_with_offset - (times_to_update * UpdateRateNs);

        { // TODO: Speed: change this to only update when something has changed. Hash?
            var entity_iter = entity_list.list.iterator();
            const body_interface = self.zphy.getBodyInterfaceMut();
            while (entity_iter.next()) |entity| {
                if (entity.physics) |physics| {
                    switch (physics) {
                        .Body => |body| {
                            body_interface.setPosition(body.id, zm.vecToArr3(entity.transform.position), .dont_activate);
                            body_interface.setRotation(body.id, entity.transform.rotation, .activate);
                        },
                        .Character => |character| {
                            character.character.setPosition(zm.vecToArr3(entity.transform.position));
                            //character.character.setRotation(entity.transform.rotation);
                        },
                        .CharacterVirtual => |character| {
                            character.virtual.setPosition(zm.vecToArr3(entity.transform.position));
                            //character.virtual.setRotation(entity.transform.rotation);
                        },
                    }
                }
            }
        }

        const delta_time: f32 = (1.0 / UpdateRateHz) * @as(f32, @floatCast(engine().time.time_scale));

        // Update at UpdateRateHz, this may happen zero or more than one times before returning
        for (0..@intCast(times_to_update)) |_| {
            // Run physics update
            self.zphy.update(delta_time, .{}) 
                catch std.log.err("Unable to update physics", .{});

            // After physics update set all entity transforms to match physics bodies
            const body_interface = self.zphy.getBodyInterface();
            for (entity_list.list.data.items) |*it| {
                if (it.item_data) |*e| {
                    if (e.physics) |phys| {
                        switch (phys) {
                            .Body => |body| {
                                const pos = body_interface.getPosition(body.id);
                                e.transform.position = zm.f32x4(pos[0], pos[1], pos[2], 1.0);
                                e.transform.rotation = body_interface.getRotation(body.id);
                            },
                            .Character => |character| {
                                character.character.postSimulation(0.1, true);

                                const pos = character.character.getPosition();
                                e.transform.position = zm.loadArr3(pos);
                                //e.transform.rotation = character.getRotation();
                            },
                            .CharacterVirtual => |character| {
                                // Run update for virtual character
                                if (character.extended_update_settings) |ext| {
                                    character.virtual.extendedUpdate(
                                        delta_time,
                                        self.zphy.getGravity(),
                                        &ext,
                                        .{
                                            .body_filter = if (character.body_filter) |*b| @ptrCast(b) else null,
                                        }
                                    );
                                } else {
                                    character.virtual.update(
                                        delta_time,
                                        self.zphy.getGravity(),
                                        .{
                                            .body_filter = if (character.body_filter) |*b| @ptrCast(b) else null,
                                        }
                                    );
                                }

                                const pos = character.virtual.getPosition();
                                if (character.character) |c| {
                                    c.setPosition(pos);
                                    c.postSimulation(0.05, true);
                                }

                                e.transform.position = zm.loadArr3(pos);
                                e.transform.rotation = character.virtual.getRotation();
                            },
                        }
                    }
                }
            }
        }
    }

    pub fn debug_draw_bodies(self: *Self, rtv: *_gfx.RenderTargetView, width: i32, height: i32, projection: [16]f32, view: [16]f32) void {
        if (debug_renderer_enabled()) {
            self._debug_renderer.draw_bodies(self.zphy, rtv.platform.view, width, height, projection, view);
        }
    }

    pub fn create_shape(self: *const Self, shape: ShapeSettings) !*zphy.Shape {
        var shape_settings = switch (shape.shape) {
            .Capsule => |*c| 
                (try zphy.CapsuleShapeSettings.create(c.half_height, c.radius)).asShapeSettingsMut(),
            .Sphere => |*s| 
                (try zphy.SphereShapeSettings.create(s.radius)).asShapeSettingsMut(),
            .Box => |*b| 
                (try zphy.BoxShapeSettings.create([3]f32{b.width/2.0, b.height/2.0, b.depth/2.0})).asShapeSettingsMut(),
            .ModelCompoundConvexHull => |m|
                (try (try self.asset_manager.get_model(m)).gen_static_compound_physics_shape()).asShapeSettingsMut(),
            };
        defer shape_settings.release();

        if (zm.any(shape.offset_transform.scale != zm.f32x4s(1.0), 3)) {
            const scale_shape = try zphy.DecoratedShapeSettings.createScaled(shape_settings, zm.vecToArr3(shape.offset_transform.scale));

            shape_settings.release();
            shape_settings = scale_shape.asShapeSettingsMut();
        }

        if (zm.any(shape.offset_transform.position != zm.f32x4s(0.0), 3) or zm.any(shape.offset_transform.rotation != zm.qidentity(), 4)) {
            const decorated_shape = try zphy.DecoratedShapeSettings.createRotatedTranslated(
                shape_settings, 
                shape.offset_transform.rotation, 
                zm.vecToArr3(shape.offset_transform.position)
            );

            shape_settings.release();
            shape_settings = decorated_shape.asShapeSettingsMut();
        }

        return try shape_settings.createShape();
    }

    pub const BodyReadLock = struct {
        lock_interface: *const zphy.BodyLockInterface,
        read_lock: zphy.BodyLockRead,
        body: *const zphy.Body,

        pub fn deinit(self: *BodyReadLock) void {
            self.read_lock.unlock();
        }

        pub fn init(body_id: BodyId, physics_system: *PhysicsSystem) !BodyReadLock {
            const lock_interface = physics_system.zphy.getBodyLockInterface();

            var read_lock: zphy.BodyLockRead = .{};
            read_lock.lock(lock_interface, body_id);
            errdefer read_lock.unlock();

            if (read_lock.body) |locked_body| {
                return BodyReadLock {
                    .lock_interface = lock_interface,
                    .read_lock = read_lock,
                    .body = locked_body,
                };
            } else {
                return error.UnableToLockBody;
            }
        }
    };

    pub fn init_body_read_lock(self: *Self, body_id: BodyId) !BodyReadLock {
        return BodyReadLock.init(body_id, self);
    }

    pub const BodyWriteLock = struct {
        lock_interface: *zphy.BodyLockInterface,
        write_lock: zphy.BodyLockWrite,
        body: *zphy.Body,

        pub fn deinit(self: *BodyWriteLock) void {
            self.write_lock.unlock();
        }

        pub fn init(body_id: BodyId, physics_system: *PhysicsSystem) !BodyWriteLock {
            const lock_interface = physics_system.zphy.getBodyLockInterface();

            var write_lock: zphy.BodyLockWrite = .{};
            write_lock.lock(lock_interface, body_id);
            errdefer write_lock.unlock();

            if (write_lock.body) |locked_body| {
                return BodyWriteLock {
                    .lock_interface = @constCast(lock_interface),
                    .write_lock = write_lock,
                    .body = locked_body,
                };
            } else {
                return error.UnableToLockBody;
            }
        }
    };

    pub fn init_body_write_lock(self: *Self, body_id: BodyId) !BodyWriteLock {
        return BodyWriteLock.init(body_id, self);
    }

    pub fn construct_entity_user_data_raw(old_user_data: u64, additional_data: u16) u64 {
        var ret: u64 = 0x00;
        ret |= @as(u64, @intCast(old_user_data & 0xffffffffffff)); // keep generational index entity id
        ret |= @as(u64, @intCast(additional_data)) << (32 + 16);
        return ret;
    }

    pub fn construct_entity_user_data(generational_idx: en.gen.GenerationalIndex, additional_data: u16) u64 {
        var ret: u64 = 0x00;
        ret |= @as(u64, @intCast(generational_idx.index));
        ret |= @as(u64, @intCast(generational_idx.generation)) << 32;
        ret |= @as(u64, @intCast(additional_data)) << (32 + 16);
        return ret;
    }

    pub fn extract_entity_from_user_data(user_data: u64) struct{ entity: en.gen.GenerationalIndex, additional_data: u16 } {
        return .{
            .entity = en.gen.GenerationalIndex {
                .index = @intCast(user_data & 0xffffffff),
                .generation = @intCast((user_data >> 32) & 0xffff),
            },
            .additional_data = @intCast((user_data >> (32 + 16)) & 0xffff),
        };
    }

    pub fn get_raycast_normal(self: *Self, ray: zphy.RRayCast, raycast_result: zphy.RayCastResult) ?zm.F32x4 {
        if (raycast_result.has_hit) {
            const lock_interface = self.zphy.getBodyLockInterface();
            var lock: zphy.BodyLockRead = .{};
            lock.lock(lock_interface, raycast_result.hit.body_id);
            defer lock.unlock();

            if (lock.body) |body| {
                const hit_position = zm.loadArr4(ray.origin) + zm.loadArr4(ray.direction) * zm.f32x4s(raycast_result.hit.fraction);
                const hit_normal = body.getWorldSpaceSurfaceNormal(raycast_result.hit.sub_shape_id, zm.vecToArr3(hit_position));
                return zm.loadArr3(hit_normal);
            }
        }

        return null;
    }
    
    pub fn raycast(self: *const Self, ray: Ray) ?RaycastHit {
        const zphy_ray = ray.to_zphy();
        const r = self.zphy.getNarrowPhaseQuery().castRay(
            zphy_ray,
            .{}
        );
        if (!r.has_hit) return null;
        return RaycastHit.init_from_zphy(r.hit, zphy_ray, self);
    }
};

pub const Ray = struct {
    origin: zm.F32x4,
    direction: zm.F32x4,

    pub fn to_zphy(self: Ray) zphy.RRayCast {
        return zphy.RRayCast {
            .origin = zm.vecToArr4(self.origin),
            .direction = zm.vecToArr4(self.direction),
        };
    }
};

pub const RaycastHit = struct {
    position: zm.F32x4,
    body_id: BodyId,
    _physics_system: *const PhysicsSystem,

    fn init_from_zphy(raycast_result: zphy.RayCastResult, ray: zphy.RRayCast, physics_system: *const PhysicsSystem) RaycastHit {
        return RaycastHit {
            .position = ray.origin + ray.direction * zm.f32x4s(raycast_result.fraction),
            .body_id = raycast_result.body_id,
            ._physics_system = physics_system,
        };
    }

    pub inline fn get_normal(self: *const RaycastHit) ?zm.F32x4 {
        return self._physics_system.get_raycast_normal(self.position, self.body_id);
    }
};


// --- Jolt interfaces ---
pub const object_layers = struct {
    pub const non_moving: zphy.ObjectLayer = 0;
    pub const moving: zphy.ObjectLayer = 1;
    pub const len: u32 = 2;
};

pub const broad_phase_layers = struct {
    pub const non_moving: zphy.BroadPhaseLayer = 0;
    pub const moving: zphy.BroadPhaseLayer = 1;
    pub const len: u32 = 2;
};

const BroadPhaseLayerInterface = extern struct {
    usingnamespace zphy.BroadPhaseLayerInterface.Methods(@This());
    __v: *const zphy.BroadPhaseLayerInterface.VTable = &vtable,

    object_to_broad_phase: [object_layers.len]zphy.BroadPhaseLayer = undefined,

    const vtable = zphy.BroadPhaseLayerInterface.VTable{
        .getNumBroadPhaseLayers = _getNumBroadPhaseLayers,
        .getBroadPhaseLayer = _getBroadPhaseLayer,
    };

    fn init() BroadPhaseLayerInterface {
        var layer_interface: BroadPhaseLayerInterface = .{};
        layer_interface.object_to_broad_phase[object_layers.non_moving] = broad_phase_layers.non_moving;
        layer_interface.object_to_broad_phase[object_layers.moving] = broad_phase_layers.moving;
        return layer_interface;
    }

    fn _getNumBroadPhaseLayers(_: *const zphy.BroadPhaseLayerInterface) callconv(.C) u32 {
        return broad_phase_layers.len;
    }

    fn _getBroadPhaseLayer(
        iself: *const zphy.BroadPhaseLayerInterface,
        layer: zphy.ObjectLayer,
    ) callconv(.C) zphy.BroadPhaseLayer {
        const self = @as(*const BroadPhaseLayerInterface, @ptrCast(iself));
        return self.object_to_broad_phase[layer];
    }
};

const ObjectVsBroadPhaseLayerFilter = extern struct {
    usingnamespace zphy.ObjectVsBroadPhaseLayerFilter.Methods(@This());
    __v: *const zphy.ObjectVsBroadPhaseLayerFilter.VTable = &vtable,

    const vtable = zphy.ObjectVsBroadPhaseLayerFilter.VTable{ .shouldCollide = _shouldCollide };

    fn _shouldCollide(
        _: *const zphy.ObjectVsBroadPhaseLayerFilter,
        layer1: zphy.ObjectLayer,
        layer2: zphy.BroadPhaseLayer,
    ) callconv(.C) bool {
        return switch (layer1) {
            object_layers.non_moving => layer2 == broad_phase_layers.moving,
            object_layers.moving => true,
            else => unreachable,
        };
    }
};

const ObjectLayerPairFilter = extern struct {
    usingnamespace zphy.ObjectLayerPairFilter.Methods(@This());
    __v: *const zphy.ObjectLayerPairFilter.VTable = &vtable,

    const vtable = zphy.ObjectLayerPairFilter.VTable{ .shouldCollide = _shouldCollide };

    fn _shouldCollide(
        _: *const zphy.ObjectLayerPairFilter,
        object1: zphy.ObjectLayer,
        object2: zphy.ObjectLayer,
    ) callconv(.C) bool {
        return switch (object1) {
            object_layers.non_moving => object2 == object_layers.moving,
            object_layers.moving => true,
            else => unreachable,
        };
    }
};

const ContactListener = extern struct {
    usingnamespace zphy.ContactListener.Methods(@This());
    __v: *const zphy.ContactListener.VTable = &vtable,

    const vtable = zphy.ContactListener.VTable{ .onContactValidate = _onContactValidate };

    fn _onContactValidate(
        self: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        base_offset: *const [3]zphy.Real,
        collision_result: *const zphy.CollideShapeResult,
    ) callconv(.C) zphy.ValidateResult {
        _ = self;
        _ = body1;
        _ = body2;
        _ = base_offset;
        _ = collision_result;
        return .accept_all_contacts;
    }
};

pub const IgnoreIdsBodyFilter = extern struct { 
    usingnamespace zphy.BodyFilter.Methods(@This());

    __v: *const zphy.BodyFilter.VTable = &vtable,
    body_ids_to_ignore: [IgnoreIdsBodyFilter.MAX_BODY_IDS_TO_IGNORE]zphy.BodyId,
    length: usize = 0,

    const vtable = zphy.BodyFilter.VTable{
        .shouldCollide = _shouldCollide,
        .shouldCollideLocked = _shouldCollideLocked,
    };
    const MAX_BODY_IDS_TO_IGNORE = 8;

    pub fn init(body_ids_to_ignore: []const zphy.BodyId) IgnoreIdsBodyFilter {
        std.debug.assert(body_ids_to_ignore.len <= IgnoreIdsBodyFilter.MAX_BODY_IDS_TO_IGNORE);
        var biti = [_]zphy.BodyId{0} ** IgnoreIdsBodyFilter.MAX_BODY_IDS_TO_IGNORE;
        @memcpy(biti[0..body_ids_to_ignore.len], body_ids_to_ignore[0..]);
        return IgnoreIdsBodyFilter {
            .body_ids_to_ignore = biti,
            .length = body_ids_to_ignore.len,
        };
    }

    fn _shouldCollide(self: *const zphy.BodyFilter, body_id: *const BodyId) callconv(.C) bool {
        const pself: *const IgnoreIdsBodyFilter = @ptrCast(self);
        for (0..pself.length) |i| {
            if (body_id.* == pself.body_ids_to_ignore[i]) { return false; }
        }
        return true;
    }

    fn _shouldCollideLocked(self: *const zphy.BodyFilter, body: *const zphy.Body) callconv(.C) bool {
        return self.shouldCollide(&body.getId());
    }
};

pub const ShapeSettingsEnum = enum {
    Capsule,
    Sphere,
    Box,
    ModelCompoundConvexHull,
};

pub const ShapeSettings = struct {
    shape: union(ShapeSettingsEnum) {
        Capsule: struct {
            half_height: f32,
            radius: f32,
        },
        Sphere: struct {
            radius: f32,
        },
        Box: struct {
            width: f32,
            height: f32,
            depth: f32,
        },
        ModelCompoundConvexHull: as.ModelAssetId,
    } = .{ .Box = .{ .width = 1.0, .height = 1.0, .depth = 1.0 } },
    offset_transform: Transform = .{},
};

pub const CharacterBaseSettings = struct {
    up: [4]f32 = [4]f32{ 0.0, 1.0, 0.0, 0.0 },
    supporting_volume: [4]f32 = [4]f32{ 0.0, 1.0, 0.0, -1.0e10 },
    max_slope_angle: f32 = std.math.degreesToRadians(50.0),
    shape: ShapeSettings = .{},
};

pub const CharacterSettings = struct {
    base: CharacterBaseSettings = .{},

    layer: zphy.ObjectLayer = object_layers.moving,
    mass: f32 = 80.0,
    friction: f32 = 0.2,
    gravity_factor: f32 = 1.0,

    pub fn create_zphy(self: CharacterSettings, phys: *PhysicsSystem) !*zphy.CharacterSettings {
        var ret = try zphy.CharacterSettings.create();
        errdefer ret.release();

        ret.base.up = self.base.up;
        ret.base.supporting_volume = self.base.supporting_volume;
        ret.base.max_slope_angle = self.base.max_slope_angle;
        ret.base.shape = try phys.create_shape(self.base.shape);

        ret.layer = self.layer;
        ret.mass = self.mass;
        ret.friction = self.friction;
        ret.gravity_factor = self.gravity_factor;

        return ret;
    }

    pub fn create_character(self: CharacterSettings, transform: Transform, phys: *PhysicsSystem) !*zphy.Character {
        const settings = try self.create_zphy(phys);
        defer settings.release();

        return try zphy.Character.create(
            settings,
            zm.vecToArr3(transform.position),
            transform.rotation,
            0,
            phys.zphy 
        );
    }
};

pub const CharacterVirtualSettings = struct {
    base: CharacterBaseSettings = .{},

    mass: f32 = 70.0,
    max_strength: f32 = 100.0,
    shape_offset: [4]f32 = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
    back_face_mode: zphy.BackFaceMode = .collide_with_back_faces,
    predictive_contact_distance: f32 = 0.1,
    max_collision_iterations: u32 = 5,
    max_constraint_iterations: u32 = 15,
    min_time_remaining: f32 = 1.0e-4,
    collision_tolerance: f32 = 1.0e-3,
    character_padding: f32 = 0.02,
    max_num_hits: u32 = 256,
    hit_reduction_cos_max_angle: f32 = 0.999,
    penetration_recovery_speed: f32 = 1.0,

    pub fn create_zphy(self: CharacterVirtualSettings, phys: *PhysicsSystem) !*zphy.CharacterVirtualSettings {
        var ret = try zphy.CharacterVirtualSettings.create();
        errdefer ret.release();

        ret.base.up = self.base.up;
        ret.base.supporting_volume = self.base.supporting_volume;
        ret.base.max_slope_angle = self.base.max_slope_angle;
        ret.base.shape = try phys.create_shape(self.base.shape);

        ret.mass = self.mass;
        ret.max_strength = self.max_strength;
        ret.shape_offset = self.shape_offset;
        ret.back_face_mode = self.back_face_mode;
        ret.predictive_contact_distance = self.predictive_contact_distance;
        ret.max_collision_iterations = self.max_collision_iterations;
        ret.max_constraint_iterations = self.max_constraint_iterations;
        ret.min_time_remaining = self.min_time_remaining;
        ret.collision_tolerance = self.collision_tolerance;
        ret.character_padding = self.character_padding;
        ret.max_num_hits = self.max_num_hits;
        ret.hit_reduction_cos_max_angle = self.hit_reduction_cos_max_angle;
        ret.penetration_recovery_speed = self.penetration_recovery_speed;

        return ret;
    }

    pub fn create_character_virtual(self: CharacterVirtualSettings, transform: Transform, phys: *PhysicsSystem) !*zphy.CharacterVirtual {
        const settings = try self.create_zphy(phys);
        defer settings.release();

        return try zphy.CharacterVirtual.create(
            settings,
            zm.vecToArr3(transform.position),
            transform.rotation,
            phys.zphy 
        );
    }
};

