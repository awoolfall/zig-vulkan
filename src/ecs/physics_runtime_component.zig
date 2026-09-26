const std = @import("std");
const eng = @import("self");
const sr = eng.serialize;
const physics = eng.physics;
const zphy = physics.zphy;
const zm = eng.zmath;

pub const COMPONENT_UUID = "";
pub const COMPONENT_NAME = "Physics Runtime";

const Self = @This();

pub const PhysicsRuntimeData = union(@import("physics_component.zig").PhysicsOptionsEnum) {
    None: void,
    Body: struct {
        id: physics.zphy.BodyId,
    },
    Character: struct {
        character: *physics.zphy.Character,
    },
    CharacterVirtual: struct {
        virtual: *physics.zphy.CharacterVirtual,
        character: ?*physics.zphy.Character,
        body_filter: ?physics.IgnoreIdsBodyFilter = null,
    },
};

runtime_data: PhysicsRuntimeData = .{ .None = {} },

last_frame_data: struct {
    position: zm.F32x4 = zm.f32x4s(0.0),
    rotation: zm.F32x4 = zm.qidentity(),
} = .{},

pub fn deinit(self: *Self) void {
    self.deinit_runtime_data();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return .{};
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = imui; _ = entity; _ = component; _ = key;
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = self;
    _ = alloc;
    _ = entity;
    _ = object;
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = alloc;
    _ = entity;
    _ = object;
    return .{};
}

pub fn deinit_runtime_data(self: *Self) void {
    switch (self.runtime_data) {
        .None => {},
        .Body => |body| {
            const physics_system = &eng.get().physics;
            physics_system.zphysics.system.getBodyInterfaceMut().removeAndDestroyBody(body.id);
        },
        .Character => |character| {
            character.character.removeFromPhysicsSystem(.{});
            character.character.destroy();
        },
        .CharacterVirtual => |character| {
            character.virtual.destroy();
            if (character.character) |c| {
                c.removeFromPhysicsSystem(.{});
                c.destroy();
            }
        },
    }
    self.runtime_data = .{ .None = {} };
}

/// Sets the full 64 bit user data for the physics body
fn set_full_user_data(self: *const Self, data: u64) !void {
    const body_id: ?physics.zphy.BodyId = switch (self.runtime_data) {
        .None => null,
        .Body => |body| body.id,
        .Character => |character| character.character.getBodyId(),
        .CharacterVirtual => |character| if (character.character) |c| c.getBodyId() else null,
    };

    if (body_id) |bid| {
        const physics_system = &eng.get().physics;
        var write_lock = try physics_system.init_body_write_lock(bid);
        defer write_lock.deinit();

        write_lock.body.setUserData(data);
    }
}

/// Sets the end user accessable 16 bit user data for the physics body
pub fn set_user_data(self: *const Self, data: u16) !void {
    const body_id: ?physics.zphy.BodyId = switch (self.*) {
        .Body => |body| body.id,
        .Character => |character| character.getBodyId(),
        .CharacterVirtual => |character| if (character.character) |c| c.getBodyId() else null,
    };

    if (body_id) |bid| {
        const physics_system = &eng.get().physics;
        var write_lock = try physics_system.init_body_write_lock(bid);
        defer write_lock.deinit();

        const user_data = write_lock.body.getUserData();
        write_lock.body.setUserData(physics.PhysicsSystem.construct_entity_user_data_raw(user_data, data));
    }
}

pub fn update_runtime_data(self: *Self, entity: eng.ecs.Entity, settings: @import("physics_component.zig").PhysicsSettings, transform: eng.Transform) !void {
    const phys = &eng.get().physics;

    self.deinit_runtime_data();

    switch (settings) {
        .None => {
            self.runtime_data = .{ .None = {} };
        },
        .Body => |b| {
            //b.shape.offset_transform.scale *= transform.scale; // TODO
            const shape = try phys.create_shape(b.shape);
            defer shape.release();

            const body = try phys.zphysics.system.getBodyInterfaceMut().createAndAddBody(.{
                .shape = shape,
                .object_layer = if (b.is_static) @intFromEnum(physics.ObjectLayer.non_moving) else @intFromEnum(physics.ObjectLayer.moving),
                .motion_type = if (b.is_static) .static else .dynamic, // TODO: fix this
                .is_sensor = b.is_sensor,
            }, .activate);

            self.runtime_data = .{
                .Body = .{
                    .id = body,
                }
            };
        },
        .Character => |character| {
            const zphy_character = try character.settings.create_character(transform, phys);
            errdefer zphy_character.destroy();

            zphy_character.addToPhysicsSystem(.{});

            self.runtime_data = .{
                .Character = .{
                    .character = zphy_character,
                }
            };
        },
        .CharacterVirtual => |character_virtual| {
            const zphy_virtual_character = try character_virtual.settings.create_character_virtual(transform, phys);
            errdefer zphy_virtual_character.destroy();

            var zphy_character: ?*zphy.Character = null;
            var body_filter: ?physics.IgnoreIdsBodyFilter = null;
            if (character_virtual.create_character) {
                var character_settings = physics.CharacterSettings {
                    .shape = character_virtual.settings.shape,
                    .up_direction = character_virtual.settings.up_direction,
                    .supporting_volume = character_virtual.settings.supporting_volume,
                    .max_slope_angle = character_virtual.settings.max_slope_angle,
                    .mass = character_virtual.settings.mass,
                    .layer = physics.ObjectLayer.moving,
                    .friction = 0.0,
                    .gravity_factor = 0.0,
                };
                switch (character_settings.shape.shape) {
                    .Capsule => |*c| {
                        c.half_height /= 2.0;
                    },
                    else => {},
                }

                zphy_character = try character_settings.create_character(transform, phys);
                zphy_character.?.addToPhysicsSystem(.{});

                body_filter = physics.IgnoreIdsBodyFilter.init(&[1]physics.zphy.BodyId{zphy_character.?.getBodyId()});
            }

            self.runtime_data = .{
                .CharacterVirtual = .{
                    .virtual = zphy_virtual_character,
                    .character = zphy_character,
                    .body_filter = body_filter,
                },
            };
        },
    }
    errdefer self.deinit_runtime_data();

    try self.set_full_user_data(physics.PhysicsSystem.construct_entity_user_data(entity.idx, 0));
}
