const std = @import("std");
const zm = @import("zmath");
const gen = @import("gen_list.zig");
const Transform = @import("transform.zig");
const as = @import("../asset/asset.zig");
const physics = @import("../physics/physics.zig");
const zphy = physics.zphy;
const eng = @import("../root.zig");
const Engine = @import("../engine.zig");
const sr = eng.serialize;

pub const StandardEntityComponents = .{
    SerializationComponent,
    NameComponent,
    TransformComponent,
    PhysicsComponent,
};

pub const SerializationComponent = struct {
    serialize_id: ?u32 = null,

    pub fn deinit(self: *SerializationComponent) void {
        _ = self;
    }

    pub fn init() !SerializationComponent {
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: SerializationComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("serialize_id", try sr.serialize_value(u32, alloc, value.serialize_id));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !SerializationComponent {
        var component: SerializationComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("serialize_id")) |v| blk: { component.serialize_id = sr.deserialize_value(u32, alloc, v) catch break :blk; }

        return component;
    }
};

pub const NameComponent = struct {
    name: ?[]const u8 = null,

    pub fn deinit(self: *NameComponent) void {
        _ = self;
    }

    pub fn init() !NameComponent {
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: NameComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("name", try sr.serialize_value(?[]const u8, alloc, value.name));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !NameComponent {
        var component: NameComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("name")) |v| blk: { component.name = sr.deserialize_value(?[]const u8, alloc, v) catch break :blk; }

        return component;
    }

    pub fn set_name(self: *NameComponent, name: ?[]const u8) !void {
        if (self.name) |n| { eng.get().general_allocator.free(n); }
        self.name = null;
        if (name) |n| { self.name = try eng.get().general_allocator.dupe(u8, n); }
    }
};

pub const TransformComponent = struct {
    transform: Transform = .{},

    pub fn deinit(self: *TransformComponent) void {
        _ = self;
    }

    pub fn init() !TransformComponent {
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: TransformComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("transform", try sr.serialize_value(Transform, alloc, value.transform));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !TransformComponent {
        var component: TransformComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("transform")) |v| blk: { component.transform = sr.deserialize_value(Transform, alloc, v) catch break :blk; }

        return component;
    }
};

pub const PhysicsOptionsEnum = enum {
    None,
    Body,
    Character,
    CharacterVirtual,
};

pub const PhysicsSettings = union(PhysicsOptionsEnum) {
    None: void,
    Body: struct {
        settings: physics.ShapeSettings = .{},
        is_static: bool = true,
        is_sensor: bool = false,
    },
    Character: struct {
        settings: physics.CharacterSettings = .{},
    },
    CharacterVirtual: struct {
        settings: physics.CharacterVirtualSettings = .{},
        create_character: bool = false,
        extended_update_settings: ?zphy.CharacterVirtual.ExtendedUpdateSettings = null,
    },
};

pub const PhysicsRuntimeData = union(PhysicsOptionsEnum) {
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

pub const PhysicsComponent = struct {
    const Self = @This();

    settings: PhysicsSettings = .{ .None = {} },
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

    pub fn deinit_runtime_data(self: *Self) void {
        switch (self.runtime_data) {
            .None => {},
            .Body => |body| {
                const physics_system = &eng.get().physics;
                physics_system.zphy.getBodyInterfaceMut().removeAndDestroyBody(body.id);
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

    pub fn serialize(alloc: std.mem.Allocator, value: Self) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("settings", try sr.serialize_value(PhysicsSettings, alloc, value.settings));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !PhysicsComponent {
        var component: PhysicsComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("settings")) |v| blk: { component.settings = sr.deserialize_value(PhysicsSettings, alloc, v) catch break :blk; }

        return component;
    }

    // pub fn update_runtime_data(self: *Self, entity_id: EntityId) !void {
    //     const entity = eng.get().entities.get(entity_id) orelse return error.UnableToGetEntity;
    //     const transform = entity.transform;
    //     const phys = &eng.get().physics;

    //     self.deinit_runtime_data();

    //     switch (self.settings) {
    //         .None => {
    //             self.runtime_data = .{ .None = {} };
    //         },
    //         .Body => |b| {
    //             var settings = b.settings;
    //             settings.offset_transform.scale *= transform.scale;
    //             const shape = try phys.create_shape(settings);
    //             defer shape.release();

    //             const body = try phys.zphy.getBodyInterfaceMut().createAndAddBody(.{
    //                 .shape = shape,
    //                 .object_layer = if (b.is_static) physics.object_layers.non_moving else physics.object_layers.moving,
    //                 .motion_type = if (b.is_static) .static else .dynamic, // TODO: fix this
    //                 .is_sensor = b.is_sensor,
    //             }, .activate);

    //             self.runtime_data = .{
    //                 .Body = .{
    //                     .id = body,
    //                 }
    //             };
    //         },
    //         .Character => |settings| {
    //             const zphy_character = try settings.settings.create_character(transform, phys);
    //             errdefer zphy_character.destroy();

    //             zphy_character.addToPhysicsSystem(.{});

    //             self.runtime_data = .{
    //                 .Character = .{
    //                     .character = zphy_character,
    //                 }
    //             };
    //         },
    //         .CharacterVirtual => |settings| {
    //             const zphy_virtual_character = try settings.settings.create_character_virtual(transform, phys);
    //             errdefer zphy_virtual_character.destroy();

    //             var zphy_character: ?*zphy.Character = null;
    //             var body_filter: ?physics.IgnoreIdsBodyFilter = null;
    //             if (settings.create_character) {
    //                 var character_settings = physics.CharacterSettings {
    //                     .base = settings.settings.base,
    //                     .mass = settings.settings.mass,
    //                     .layer = physics.object_layers.moving,
    //                     .friction = 0.0,
    //                     .gravity_factor = 0.0,
    //                 };
    //                 switch (character_settings.base.shape.shape) {
    //                     .Capsule => |*c| {
    //                         c.half_height /= 2.0;
    //                     },
    //                     else => {},
    //                 }

    //                 zphy_character = try character_settings.create_character(transform, phys);
    //                 zphy_character.?.addToPhysicsSystem(.{});

    //                 body_filter = physics.IgnoreIdsBodyFilter.init(&[1]physics.zphy.BodyId{zphy_character.?.getBodyId()});
    //             }

    //             self.runtime_data = .{
    //                 .CharacterVirtual = .{
    //                     .virtual = zphy_virtual_character,
    //                     .character = zphy_character,
    //                     .body_filter = body_filter,
    //                 },
    //             };
    //         },
    //     }
    //     errdefer self.deinit_runtime_data();

    //     try self.set_full_user_data(physics.PhysicsSystem.construct_entity_user_data(entity_id, 0));
    // }

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
};
