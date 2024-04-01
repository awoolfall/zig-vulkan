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

    pub fn update(self: *Self, time: *tm.TimeState) void {
        // Update at UpdateRateHz, this may happen more than one time before returning
        while (time.frame_start_time_ns > self.next_update_time) {
            self.zphy.update(1.0 / UpdateRateHz, .{}) 
                catch std.log.err("Unable to update physics", .{});

            self.next_update_time += UpdateRateNs;
        }
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

