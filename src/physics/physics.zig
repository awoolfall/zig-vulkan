const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const Transform = eng.Transform;

pub const zphy = @import("zphysics");
pub const util = @import("util.zig");
pub const BodyId = zphy.BodyId;

pub const PhysicsSystem = @import("physics_system.zig");
pub const Shape = @import("shape.zig");
pub const ShapeSettings = Shape;
pub const ShapeSettingsEnum = std.meta.Tag(Shape.ShapeUnion);

pub const ObjectLayer = enum(u16) {
    non_moving = 0,
    moving = 1,
};

pub const BroadPhaseLayer = enum(u8) {
    non_moving = 0,
    moving = 1,
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

pub const CharacterSettings = struct {
    shape: Shape = .{ .shape = .{ .Capsule = .{} }, .offset_transform = .{} },

    up_direction: [4]f32 = [4]f32{ 0.0, 1.0, 0.0, 0.0 },
    supporting_volume: [4]f32 = [4]f32{ 0.0, 1.0, 0.0, -1.0e10 },
    max_slope_angle: f32 = std.math.degreesToRadians(50.0),

    layer: ObjectLayer = ObjectLayer.moving,
    mass: f32 = 80.0,
    friction: f32 = 0.2,
    gravity_factor: f32 = 1.0,

    pub fn create_zphy(self: CharacterSettings, phys: *PhysicsSystem) !*zphy.CharacterSettings {
        var ret = try zphy.CharacterSettings.create();
        errdefer ret.release();

        ret.base.up = self.up_direction;
        ret.base.supporting_volume = self.supporting_volume;
        ret.base.max_slope_angle = self.max_slope_angle;
        ret.base.shape = try phys.create_shape(self.shape);

        ret.layer = @intFromEnum(self.layer);
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
            phys.zphysics.system
        );
    }
};

pub const CharacterVirtualSettings = struct {
    shape: Shape = .{ .shape = .{ .Capsule = .{} }, .offset_transform = .{} },

    up_direction: [4]f32 = [4]f32{ 0.0, 1.0, 0.0, 0.0 },
    supporting_volume: [4]f32 = [4]f32{ 0.0, 1.0, 0.0, -1.0e10 },
    max_slope_angle: f32 = std.math.degreesToRadians(50.0),

    mass: f32 = 70.0,
    max_strength: f32 = 100.0,
    character_padding: f32 = 0.02,

    pub fn create_zphy(self: CharacterVirtualSettings, phys: *PhysicsSystem) !*zphy.CharacterVirtualSettings {
        var ret = try zphy.CharacterVirtualSettings.create();
        errdefer ret.release();

        ret.base.up = self.up_direction;
        ret.base.supporting_volume = self.supporting_volume;
        ret.base.max_slope_angle = self.max_slope_angle;
        ret.base.shape = try phys.create_shape(self.shape);

        ret.mass = self.mass;
        ret.max_strength = self.max_strength;
        ret.shape_offset = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
        ret.back_face_mode = .collide_with_back_faces;
        ret.predictive_contact_distance = 0.1;
        ret.max_collision_iterations = 5;
        ret.max_constraint_iterations = 15;
        ret.min_time_remaining = 1.0e-4;
        ret.collision_tolerance = 1.0e-3;
        ret.character_padding = self.character_padding;
        ret.max_num_hits = 256;
        ret.hit_reduction_cos_max_angle = 0.999;
        ret.penetration_recovery_speed = 1.0;

        return ret;
    }

    pub fn create_character_virtual(self: CharacterVirtualSettings, transform: Transform, phys: *PhysicsSystem) !*zphy.CharacterVirtual {
        const settings = try self.create_zphy(phys);
        defer settings.release();

        return try zphy.CharacterVirtual.create(
            settings,
            zm.vecToArr3(transform.position),
            transform.rotation,
            phys.zphysics.system
        );
    }
};
