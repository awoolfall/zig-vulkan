const std = @import("std");
pub const zphy = @import("zphysics");
const zm = @import("zmath");
pub const BodyId = zphy.BodyId;
const eng = @import("../root.zig");
const ms = @import("../engine/mesh.zig");
const as = @import("../asset/asset.zig");
const tm = @import("../engine/time.zig");
const Transform = @import("../engine/transform.zig");
const _gfx = @import("../gfx/gfx.zig");
pub const util = @import("util.zig");

inline fn debug_renderer_enabled() bool {
    return true;
}
const DebugRenderer = if (debug_renderer_enabled()) @import("physics_debug_renderer.zig").D3D11DebugRenderer else void;

pub const PhysicsSystem = struct {
    const Self = @This();
    pub const UpdateRateHz = 15;
    pub const UpdateRateS = (1.0 / @as(comptime_float, @floatFromInt(UpdateRateHz)));
    pub const UpdateRateNs = @divFloor(std.time.ns_per_s, UpdateRateHz);

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

    pub fn init(alloc: std.mem.Allocator, asset_manager: *as.AssetManager) !Self {
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
            debug_renderer.?.* = try DebugRenderer.init();

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

    pub fn update(
        self: *Self,
        components_query_iterator: eng.ecs.GenericQueryIterator(.{ eng.ecs.TransformComponent, eng.ecs.PhysicsComponent })
    ) void {
        const time = &eng.get().time;

        // find out how many times we need to update to hit UpdateRateHz
        const ns_since_last_update = time.frame_start_time.since(self.last_update_time) + self.last_update_time_offset;
        const times_to_update = @divFloor(ns_since_last_update, UpdateRateNs);
        
        const physics_delta_time: f32 = UpdateRateS * @as(f32, @floatCast(eng.get().time.time_scale));

        if (times_to_update >= 1) {
            { // TODO: Speed: change this to only update when something has changed. Hash?
                const body_interface = self.zphy.getBodyInterfaceMut();

                components_query_iterator.reset();
                while (components_query_iterator.next()) |components| {
                    const entity_transform: *eng.ecs.TransformComponent,
                    const entity_physics: *eng.ecs.PhysicsComponent = components;

                    switch (entity_physics.runtime_data) {
                        .None => {
                            entity_physics.last_frame_data.position = entity_transform.transform.position;
                            entity_physics.last_frame_data.rotation = entity_transform.transform.rotation;
                        },
                        .Body => |body| {
                            body_interface.setPosition(body.id, zm.vecToArr3(entity_transform.transform.position), .dont_activate);
                            body_interface.setRotation(body.id, entity_transform.transform.rotation, .activate);

                            entity_physics.last_frame_data.position = zm.loadArr3(body_interface.getPosition(body.id));
                            entity_physics.last_frame_data.rotation = zm.loadArr4(body_interface.getRotation(body.id));
                        },
                        .Character => |character| {
                            character.character.setPosition(zm.vecToArr3(entity_transform.transform.position));
                            //character.character.setRotation(entity.transform.rotation);

                            entity_physics.last_frame_data.position = zm.loadArr3(character.character.getPosition());
                            entity_physics.last_frame_data.rotation = entity_transform.transform.rotation;
                        },
                        .CharacterVirtual => |character| {
                            character.virtual.setPosition(zm.vecToArr3(entity_transform.transform.position));
                            //character.virtual.setRotation(entity.transform.rotation);

                            entity_physics.last_frame_data.position = zm.loadArr3(character.virtual.getPosition());
                            entity_physics.last_frame_data.rotation = entity_transform.transform.rotation;
                        },
                    }
                }
            }

            const body_interface = self.zphy.getBodyInterface();

            // Update at UpdateRateHz, this may happen zero or more than one times before returning
            for (0..@intCast(times_to_update)) |_| {
                // Run physics update
                self.zphy.update(physics_delta_time, .{}) 
                    catch std.log.err("Unable to update physics", .{});

                // After physics update set all entity transforms to match physics bodies

                components_query_iterator.reset();
                while (components_query_iterator.next()) |components| {
                    _,
                    const entity_physics: *eng.ecs.PhysicsComponent = components;

                    switch (entity_physics.runtime_data) {
                        .None => {}, 
                        .Body => |_| {},
                        .Character => |character| {
                            character.character.postSimulation(0.1, true);
                        },
                        .CharacterVirtual => |character| {
                            const extended_update_settings = switch (entity_physics.settings) {
                                .CharacterVirtual => |v| v.extended_update_settings,
                                else => null
                            };

                            // Run update for virtual character
                            if (extended_update_settings) |ext| {
                                character.virtual.extendedUpdate(
                                    physics_delta_time,
                                    self.zphy.getGravity(),
                                    &ext,
                                    .{
                                        .body_filter = if (character.body_filter) |*b| @ptrCast(b) else null,
                                    }
                                );
                            } else {
                                character.virtual.update(
                                    physics_delta_time,
                                    self.zphy.getGravity(),
                                    .{
                                        .body_filter = if (character.body_filter) |*b| @ptrCast(b) else null,
                                    }
                                );
                            }

                            const new_pos = character.virtual.getPosition();

                            if (character.character) |c| {
                                c.setPosition(new_pos);
                                c.postSimulation(0.05, true);
                            }
                        },
                    }
                }
            }

            // update last_update_time and last_update_time_offset
            // last_update_time_offset accounts for the portion of time between the 
            // last sub-frame physics update and the actual frame time 
            self.last_update_time = time.frame_start_time;
            self.last_update_time_offset = @mod(ns_since_last_update, UpdateRateNs);

            // update entity transforms to match updated physics
            components_query_iterator.reset();
            while (components_query_iterator.next()) |components| {
                const entity_transform: *eng.ecs.TransformComponent,
                const entity_physics: *eng.ecs.PhysicsComponent = components;
                
                switch (entity_physics.runtime_data) {
                    .None => {}, 
                    .Body => |body| {
                        entity_transform.transform.position = zm.loadArr3(body_interface.getPosition(body.id));
                        entity_transform.transform.rotation = zm.loadArr4(body_interface.getRotation(body.id));
                    },
                    .Character => |character| {
                        entity_transform.transform.position = zm.loadArr3(character.character.getPosition());
                    },
                    .CharacterVirtual => |character| {
                        entity_transform.transform.position = zm.loadArr3(character.virtual.getPosition());
                    },
                }
            }
        }
    }

    pub fn calculate_entity_visual_transform(self: *const Self, entity: eng.ecs.Entity) Transform {
        const transform_component = eng.get().ecs.get_component(eng.ecs.TransformComponent, entity) orelse return .{};
        if (eng.get().ecs.get_component(eng.ecs.PhysicsComponent, entity)) |physics_component| {
            // update positions and rotations of all entities based on current physics info
            const ns_since_last_update = eng.get().time.frame_start_time.since(self.last_update_time) + self.last_update_time_offset;
            const offset_seconds = @as(f32, @floatFromInt(ns_since_last_update)) / @as(f32, @floatFromInt(std.time.ns_per_s));

            const body_interface = self.zphy.getBodyInterface();
            const pos, const rot = switch (physics_component.runtime_data) {
                .None => .{
                    transform_component.transform.position,
                    transform_component.transform.rotation,
                },
                .Body => |body| .{ 
                    zm.loadArr3(body_interface.getPosition(body.id)),
                    zm.loadArr4(body_interface.getRotation(body.id)),
                },
                .Character => |character| .{
                    zm.loadArr3(character.character.getPosition()),
                    transform_component.transform.rotation, // TODO add binding for jolt character GetRotation
                },
                .CharacterVirtual => |character_virtual| .{
                    zm.loadArr3(character_virtual.virtual.getPosition()),
                    transform_component.transform.rotation, // TODO add binding for jolt character GetRotation
                },
            };

            const t = offset_seconds / UpdateRateS;
            return Transform {
                .position = zm.lerp(physics_component.last_frame_data.position, pos, t),
                .rotation = zm.slerp(physics_component.last_frame_data.rotation, rot, t),
                .scale = transform_component.transform.scale,
            };
        } else {
            return transform_component.transform;
        }
    }

    pub fn debug_draw_bodies(self: *Self, cmd: *_gfx.CommandBuffer, projection: zm.Mat, view: zm.Mat) void {
        if (debug_renderer_enabled()) {
            self._debug_renderer.draw_bodies(cmd, projection, view);
        }
    }

    pub fn create_shape(self: *const Self, shape: ShapeSettings) !*zphy.Shape {
        var shape_settings = switch (shape.shape) {
            .Capsule => |*c| 
                (try zphy.CapsuleShapeSettings.create(c.half_height, c.radius)).asShapeSettings(),
            .Sphere => |*s| 
                (try zphy.SphereShapeSettings.create(s.radius)).asShapeSettings(),
            .Box => |*b| 
                (try zphy.BoxShapeSettings.create([3]f32{b.width/2.0, b.height/2.0, b.depth/2.0})).asShapeSettings(),
            .ModelCompoundConvexHull => |m|
                (try (try self.asset_manager.get_asset(as.ModelAsset, m)).gen_static_compound_physics_shape()).asShapeSettings(),
            };
        defer shape_settings.release();

        if (zm.any(shape.offset_transform.scale != zm.f32x4s(1.0), 3)) {
            const scale_shape = try zphy.DecoratedShapeSettings.createScaled(shape_settings, zm.vecToArr3(shape.offset_transform.scale));

            shape_settings.release();
            shape_settings = scale_shape.asShapeSettings();
        }

        if (zm.any(shape.offset_transform.position != zm.f32x4s(0.0), 3) or zm.any(shape.offset_transform.rotation != zm.qidentity(), 4)) {
            const decorated_shape = try zphy.DecoratedShapeSettings.createRotatedTranslated(
                shape_settings, 
                shape.offset_transform.rotation, 
                zm.vecToArr3(shape.offset_transform.position)
            );

            shape_settings.release();
            shape_settings = decorated_shape.asShapeSettings();
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

    const UserDataStruct = packed struct(u64) {
        index: u32,
        generation: u16,
        additional_data: u16,
    };

    pub fn construct_entity_user_data(generational_idx: eng.gen.GenerationalIndex, additional_data: u16) u64 {
        const entity_user_data = UserDataStruct {
            .index = @intCast(generational_idx.index),
            .generation = generational_idx.generation,
            .additional_data = additional_data,
        };
        return @bitCast(entity_user_data);
    }

    pub fn extract_entity_from_user_data(user_data: u64) struct{ entity: eng.gen.GenerationalIndex, additional_data: u16 } {
        const entity_user_data: UserDataStruct = @bitCast(user_data);
        return .{
            .entity = eng.gen.GenerationalIndex {
                .index = @intCast(entity_user_data.index),
                .generation = entity_user_data.generation,
            },
            .additional_data = entity_user_data.additional_data,
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

    fn _getNumBroadPhaseLayers(_: *const zphy.BroadPhaseLayerInterface) callconv(.c) u32 {
        return broad_phase_layers.len;
    }

    fn _getBroadPhaseLayer(
        iself: *const zphy.BroadPhaseLayerInterface,
        layer: zphy.ObjectLayer,
    ) callconv(.c) zphy.BroadPhaseLayer {
        const self = @as(*const BroadPhaseLayerInterface, @ptrCast(iself));
        return self.object_to_broad_phase[layer];
    }
};

const ObjectVsBroadPhaseLayerFilter = extern struct {
    __v: *const zphy.ObjectVsBroadPhaseLayerFilter.VTable = &vtable,

    const vtable = zphy.ObjectVsBroadPhaseLayerFilter.VTable{ .shouldCollide = _shouldCollide };

    fn _shouldCollide(
        _: *const zphy.ObjectVsBroadPhaseLayerFilter,
        layer1: zphy.ObjectLayer,
        layer2: zphy.BroadPhaseLayer,
    ) callconv(.c) bool {
        return switch (layer1) {
            object_layers.non_moving => layer2 == broad_phase_layers.moving,
            object_layers.moving => true,
            else => unreachable,
        };
    }
};

const ObjectLayerPairFilter = extern struct {
    __v: *const zphy.ObjectLayerPairFilter.VTable = &vtable,

    const vtable = zphy.ObjectLayerPairFilter.VTable{ .shouldCollide = _shouldCollide };

    fn _shouldCollide(
        _: *const zphy.ObjectLayerPairFilter,
        object1: zphy.ObjectLayer,
        object2: zphy.ObjectLayer,
    ) callconv(.c) bool {
        return switch (object1) {
            object_layers.non_moving => object2 == object_layers.moving,
            object_layers.moving => true,
            else => unreachable,
        };
    }
};

const ContactListener = extern struct {
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
        var biti = [_]zphy.BodyId{zphy.BodyId.invalid} ** IgnoreIdsBodyFilter.MAX_BODY_IDS_TO_IGNORE;
        @memcpy(biti[0..body_ids_to_ignore.len], body_ids_to_ignore[0..]);
        return IgnoreIdsBodyFilter {
            .body_ids_to_ignore = biti,
            .length = body_ids_to_ignore.len,
        };
    }

    fn _shouldCollide(self: *const zphy.BodyFilter, body_id: *const BodyId) callconv(.c) bool {
        const pself: *const IgnoreIdsBodyFilter = @ptrCast(self);
        for (0..pself.length) |i| {
            if (body_id.* == pself.body_ids_to_ignore[i]) { return false; }
        }
        return true;
    }

    fn _shouldCollideLocked(self: *const zphy.BodyFilter, body: *const zphy.Body) callconv(.c) bool {
        return _shouldCollide(self, &body.getId());
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
