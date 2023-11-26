const std = @import("std");
const zphy = @import("zphysics");
pub const BodyId = zphy.BodyId;
const en = @import("../engine.zig");

pub const PhysicsSystem = struct {
    const Self = @This();

    _allocator: std.mem.Allocator,
    _interfaces: struct {
        broad_phase_layer_interface: *BroadPhaseLayerInterface,
        object_vs_broad_phase_layer_filter: *ObjectVsBroadPhaseLayerFilter,
        object_layer_pair_filter: *ObjectLayerPairFilter,
        debug_renderer: *DebugRenderer,
    },
    zphy: *zphy.PhysicsSystem,

    pub fn init(alloc: std.mem.Allocator) !Self {
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

        const debug_renderer = try alloc.create(DebugRenderer);
        errdefer alloc.destroy(debug_renderer);
        // debug_renderer.* = DebugRenderer{};
        //
        // try zphy.DebugRenderer.createSingleton(debug_renderer);
        // errdefer zphy.DebugRenderer.destroySingleton();

        return Self {
            ._allocator = alloc,
            ._interfaces = .{
                .broad_phase_layer_interface = broad_phase_layer_interface,
                .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
                .object_layer_pair_filter = object_layer_pair_filter,
                .debug_renderer = debug_renderer,
            },
            .zphy = physics_system,
        };
    }

    pub fn deinit(self: *Self) void {
        // zphy.DebugRenderer.destroySingleton();
        self.zphy.destroy();
        self._allocator.destroy(self._interfaces.broad_phase_layer_interface);
        self._allocator.destroy(self._interfaces.object_vs_broad_phase_layer_filter);
        self._allocator.destroy(self._interfaces.object_layer_pair_filter);
        self._allocator.destroy(self._interfaces.debug_renderer);
        zphy.deinit();
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

const DebugRenderer = extern struct {
    const MyRenderPrimitive = extern struct {
        // Actual render data goes here
        foobar: i32 = 0,
    };

    usingnamespace zphy.DebugRenderer.Methods(@This());
    __v: *const zphy.DebugRenderer.VTable(@This()) = &vtable,

    primitives: [32]MyRenderPrimitive = [_]MyRenderPrimitive{.{}} ** 32,
    prim_head: i32 = -1,

    const vtable = zphy.DebugRenderer.VTable(@This()){
        .drawLine = drawLine,
        .drawTriangle = drawTriangle,
        .createTriangleBatch = createTriangleBatch,
        .createTriangleBatchIndexed = createTriangleBatchIndexed,
        .drawGeometry = drawGeometry,
        .drawText3D = drawText3D,
    };

    pub fn shouldBodyDraw(_: *const zphy.Body) align(zphy.DebugRenderer.BodyDrawFilterFuncAlignment) callconv(.C) bool {
        return true;
    }

    fn drawLine(
        self: *DebugRenderer,
        from: *const [3]zphy.Real,
        to: *const [3]zphy.Real,
        color: *const zphy.DebugRenderer.Color,
    ) callconv(.C) void {
        _ = self;
        _ = from;
        _ = to;
        _ = color;
        std.log.info("PhysicsSystem should draw line", .{});
    }
    fn drawTriangle(
        self: *DebugRenderer,
        v1: *const [3]zphy.Real,
        v2: *const [3]zphy.Real,
        v3: *const [3]zphy.Real,
        color: *const zphy.DebugRenderer.Color,
    ) callconv(.C) void {
        _ = self;
        _ = v1;
        _ = v2;
        _ = v3;
        _ = color;
        std.log.info("PhysicsSystem should draw triangle", .{});
    }
    fn createTriangleBatch(
        self: *DebugRenderer,
        triangles: [*]zphy.DebugRenderer.Triangle,
        triangle_count: u32,
    ) callconv(.C) *anyopaque {
        _ = triangles;
        _ = triangle_count;
        std.log.info("PhysicsSystem should draw triangle batch", .{});
        self.prim_head += 1;
        const prim = &self.primitives[@as(usize, @intCast(self.prim_head))];
        return zphy.DebugRenderer.createTriangleBatch(prim);
    }
    fn createTriangleBatchIndexed(
        self: *DebugRenderer,
        vertices: [*]zphy.DebugRenderer.Vertex,
        vertex_count: u32,
        indices: [*]u32,
        index_count: u32,
    ) callconv(.C) *anyopaque {
        _ = vertices;
        _ = vertex_count;
        _ = indices;
        _ = index_count;
        std.log.info("PhysicsSystem should draw triangle batch indexed", .{});
        self.prim_head += 1;
        const prim = &self.primitives[@as(usize, @intCast(self.prim_head))];
        return zphy.DebugRenderer.createTriangleBatch(prim);
    }
    fn drawGeometry(
        self: *DebugRenderer,
        model_matrix: *const [16]zphy.Real,
        world_space_bound: *const zphy.DebugRenderer.AABox,
        lod_scale_sq: f32,
        color: zphy.DebugRenderer.Color,
        geometry: *const zphy.DebugRenderer.Geometry,
        cull_mode: zphy.DebugRenderer.CullMode,
        cast_shadow: zphy.DebugRenderer.CastShadow,
        draw_mode: zphy.DebugRenderer.DrawMode,
    ) callconv(.C) void {
        _ = self;
        _ = model_matrix;
        _ = world_space_bound;
        _ = lod_scale_sq;
        _ = color;
        _ = geometry;
        _ = cull_mode;
        _ = cast_shadow;
        _ = draw_mode;
        std.log.info("PhysicsSystem should draw geometry", .{});
    }
    fn drawText3D(
        self: *DebugRenderer,
        positions: *const [3]zphy.Real,
        string: [*:0]const u8,
        color: zphy.DebugRenderer.Color,
        height: f32,
    ) callconv(.C) void {
        _ = self;
        _ = positions;
        _ = string;
        _ = color;
        _ = height;
        std.log.info("PhysicsSystem should draw text 3d", .{});
    }
};
