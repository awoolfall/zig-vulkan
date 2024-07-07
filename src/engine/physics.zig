const std = @import("std");
pub const zphy = @import("zphysics");
const zm = @import("zmath");
pub const BodyId = zphy.BodyId;
const en = @import("../engine.zig");
const tm = @import("../engine/time.zig");
const _gfx = @import("../gfx/gfx.zig");
const debug = @import("physics_debug_renderer.zig");

pub const PhysicsSystem = struct {
    const Self = @This();
    const UpdateRateHz = 60.0;
    const UpdateRateNs: i128 = @intFromFloat((1.0 / 60.0) * @as(f64, @floatFromInt(std.time.ns_per_s)));

    _allocator: std.mem.Allocator,
    _interfaces: struct {
        broad_phase_layer_interface: *BroadPhaseLayerInterface,
        object_vs_broad_phase_layer_filter: *ObjectVsBroadPhaseLayerFilter,
        object_layer_pair_filter: *ObjectLayerPairFilter,
        debug_renderer: *debug.D3D11DebugRenderer,
    },
    zphy: *zphy.PhysicsSystem, 
    next_update_time: i128 = 0,

    pub fn init(alloc: std.mem.Allocator, gfx: *_gfx.GfxState) !Self {
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

        const debug_renderer = try alloc.create(debug.D3D11DebugRenderer);
        errdefer alloc.destroy(debug_renderer);
        debug_renderer.* = try debug.D3D11DebugRenderer.init(gfx);

        try zphy.DebugRenderer.createSingleton(debug_renderer);
        errdefer zphy.DebugRenderer.destroySingleton();

        return Self {
            ._allocator = alloc,
            ._interfaces = .{
                .broad_phase_layer_interface = broad_phase_layer_interface,
                .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
                .object_layer_pair_filter = object_layer_pair_filter,
                .debug_renderer = debug_renderer,
            },
            .zphy = physics_system,
            .next_update_time = std.time.nanoTimestamp() + UpdateRateNs,
        };
    }

    pub fn deinit(self: *Self) void {
        zphy.DebugRenderer.destroySingleton();
        self.zphy.destroy();
        self._interfaces.debug_renderer.deinit();
        self._allocator.destroy(self._interfaces.broad_phase_layer_interface);
        self._allocator.destroy(self._interfaces.object_vs_broad_phase_layer_filter);
        self._allocator.destroy(self._interfaces.object_layer_pair_filter);
        self._allocator.destroy(self._interfaces.debug_renderer);
        zphy.deinit();
    }

    pub fn update(self: *Self, comptime EntityList: type, entity_list: *EntityList, time: *tm.TimeState) void {
        // Update at UpdateRateHz, this may happen zero or more than one times before returning
        while (time.frame_start_time_ns > self.next_update_time) {
            // Run physics update
            self.zphy.update(1.0 / UpdateRateHz, .{}) 
                catch std.log.err("Unable to update physics", .{});

            // After physics update set all entity transforms to match physics bodies
            const body_interface = self.zphy.getBodyInterface();
            for (entity_list.data.items) |*it| {
                if (it.item_data) |*e| {
                    if (e.physics) |phys| {
                        switch (phys) {
                            .Body => |body_id| {
                                const pos = body_interface.getPosition(body_id);
                                e.transform.position = zm.f32x4(pos[0], pos[1], pos[2], 1.0);
                                e.transform.rotation = body_interface.getRotation(body_id);
                            },
                            .Character => |character| {
                                character.postSimulation(0.1, true);

                                const pos = character.getPosition();
                                e.transform.position = zm.f32x4(pos[0], pos[1], pos[2], 1.0);
                                //e.transform.rotation = character.getRotation();
                            },
                            .CharacterVirtual => |character| {
                                // Run update for virtual character
                                if (character.extended_update_settings) |ext| {
                                    character.virtual.extendedUpdate(
                                        1.0 / UpdateRateHz,
                                        self.zphy.getGravity(),
                                        ext,
                                        .{
                                            .body_filter = character.body_filter,
                                        }
                                    );
                                } else {
                                    character.virtual.update(
                                        1.0 / UpdateRateHz,
                                        self.zphy.getGravity(),
                                        .{
                                            .body_filter = character.body_filter,
                                        }
                                    );
                                }

                                const pos = character.virtual.getPosition();
                                if (character.character) |c| {
                                    c.setPosition(pos);
                                    c.postSimulation(0.05, true);
                                }

                                e.transform.position = zm.f32x4(pos[0], pos[1], pos[2], 1.0);
                                e.transform.rotation = character.virtual.getRotation();
                            },
                        }
                    }
                }
            }

            self.next_update_time += UpdateRateNs;
        }
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
                    .lock_interface = lock_interface,
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

    pub fn get_raycast_normal(self: *Self, raycast: zphy.RRayCast, raycast_result: zphy.RayCastResult) ?zm.F32x4 {
        if (raycast_result.has_hit) {
            const lock_interface = self.zphy.getBodyLockInterface();
            var lock: zphy.BodyLockRead = .{};
            lock.lock(lock_interface, raycast_result.hit.body_id);
            defer lock.unlock();

            if (lock.body) |body| {
                const hit_position = zm.loadArr4(raycast.origin) + zm.loadArr4(raycast.direction) * zm.f32x4s(raycast_result.hit.fraction);
                const hit_normal = body.getWorldSpaceSurfaceNormal(raycast_result.hit.sub_shape_id, zm.vecToArr3(hit_position));
                return zm.loadArr3(hit_normal);
            }
        }

        return null;
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

