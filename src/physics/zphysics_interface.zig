const std = @import("std");
const eng = @import("self");
const zphys = @import("zphysics");

const ObjectLayers = @import("physics.zig").ObjectLayer;
const BroadPhaseLayers = @import("physics.zig").BroadPhaseLayer;

const Self = @This();

alloc: std.mem.Allocator,

broad_phase_layer_interface: *BroadPhaseLayerInterface,
object_vs_broad_phase_layer_filter: *ObjectVsBroadPhaseLayerFilter,
object_layer_pair_filter: *ObjectLayerPairFilter,

system: *zphys.PhysicsSystem,

pub fn deinit(self: *Self) void {
    self.system.destroy();

    self.alloc.destroy(self.broad_phase_layer_interface);
    self.alloc.destroy(self.object_vs_broad_phase_layer_filter);
    self.alloc.destroy(self.object_layer_pair_filter);

    zphys.deinit();
}

pub fn init(
    alloc: std.mem.Allocator
) !Self {
    try zphys.init(alloc, .{});
    errdefer zphys.deinit();

    const broad_phase_layer_interface = try alloc.create(BroadPhaseLayerInterface);
    errdefer alloc.destroy(broad_phase_layer_interface);
    broad_phase_layer_interface.* = BroadPhaseLayerInterface.init();

    const object_vs_broad_phase_layer_filter = try alloc.create(ObjectVsBroadPhaseLayerFilter);
    errdefer alloc.destroy(object_vs_broad_phase_layer_filter);
    object_vs_broad_phase_layer_filter.* = ObjectVsBroadPhaseLayerFilter {};

    const object_layer_pair_filter = try alloc.create(ObjectLayerPairFilter);
    errdefer alloc.destroy(object_layer_pair_filter);
    object_layer_pair_filter.* = ObjectLayerPairFilter {};

    const system = try zphys.PhysicsSystem.create(
        @as(*const zphys.BroadPhaseLayerInterface, @ptrCast(broad_phase_layer_interface)),
        @as(*const zphys.ObjectVsBroadPhaseLayerFilter, @ptrCast(object_vs_broad_phase_layer_filter)),
        @as(*const zphys.ObjectLayerPairFilter, @ptrCast(object_layer_pair_filter)),
        .{
            .max_bodies = 2048,
            .num_body_mutexes = 0,
            .max_body_pairs = 2048,
            .max_contact_constraints = 1024,
        },
    );
    errdefer system.destroy();

    return Self {
        .alloc = alloc,
        .broad_phase_layer_interface = broad_phase_layer_interface,
        .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
        .object_layer_pair_filter = object_layer_pair_filter,
        .system = system,
    };
}

// --- Jolt interfaces ---
const BroadPhaseLayerInterface = extern struct {
    __v: *const zphys.BroadPhaseLayerInterface.VTable = &vtable,

    object_to_broad_phase: [@typeInfo(ObjectLayers).@"enum".fields.len]zphys.BroadPhaseLayer = undefined,

    const vtable = zphys.BroadPhaseLayerInterface.VTable{
        .getNumBroadPhaseLayers = _getNumBroadPhaseLayers,
        .getBroadPhaseLayer = _getBroadPhaseLayer,
    };

    fn init() BroadPhaseLayerInterface {
        var layer_interface: BroadPhaseLayerInterface = .{};
        layer_interface.object_to_broad_phase[@intFromEnum(ObjectLayers.non_moving)] = @intFromEnum(BroadPhaseLayers.non_moving);
        layer_interface.object_to_broad_phase[@intFromEnum(ObjectLayers.moving)] = @intFromEnum(BroadPhaseLayers.moving);
        return layer_interface;
    }

    fn _getNumBroadPhaseLayers(_: *const zphys.BroadPhaseLayerInterface) callconv(.c) u32 {
        return @typeInfo(BroadPhaseLayers).@"enum".fields.len;
    }

    fn _getBroadPhaseLayer(
        iself: *const zphys.BroadPhaseLayerInterface,
        layer: zphys.ObjectLayer,
    ) callconv(.c) zphys.BroadPhaseLayer {
        const self = @as(*const BroadPhaseLayerInterface, @ptrCast(iself));
        return self.object_to_broad_phase[layer];
    }
};

const ObjectVsBroadPhaseLayerFilter = extern struct {
    __v: *const zphys.ObjectVsBroadPhaseLayerFilter.VTable = &vtable,

    const vtable = zphys.ObjectVsBroadPhaseLayerFilter.VTable{ .shouldCollide = _shouldCollide };

    fn _shouldCollide(
        _: *const zphys.ObjectVsBroadPhaseLayerFilter,
        layer1: zphys.ObjectLayer,
        layer2: zphys.BroadPhaseLayer,
    ) callconv(.c) bool {
        return switch (layer1) {
            @intFromEnum(ObjectLayers.non_moving) => layer2 == @intFromEnum(BroadPhaseLayers.moving),
            @intFromEnum(ObjectLayers.moving) => true,
            else => unreachable,
        };
    }
};

const ObjectLayerPairFilter = extern struct {
    __v: *const zphys.ObjectLayerPairFilter.VTable = &vtable,

    const vtable = zphys.ObjectLayerPairFilter.VTable{ .shouldCollide = _shouldCollide };

    fn _shouldCollide(
        _: *const zphys.ObjectLayerPairFilter,
        object1: zphys.ObjectLayer,
        object2: zphys.ObjectLayer,
    ) callconv(.c) bool {
        return switch (object1) {
            @intFromEnum(ObjectLayers.non_moving) => object2 == @intFromEnum(ObjectLayers.moving),
            @intFromEnum(ObjectLayers.moving) => true,
            else => unreachable,
        };
    }
};
