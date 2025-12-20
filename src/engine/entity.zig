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
const App = @import("app");

pub const EntityId = gen.GenerationalIndex;

pub const EntitySuperStruct = struct {
    should_serialize: bool = false,
    serialize_id: ?u32 = null,

    name: ?[]const u8 = null,
    transform: Transform = .{},
    model: ?as.ModelAssetId = null,
    physics: EntityPhysics = .{},
    app: App.EntityData = .{},

    pub fn deinit(self: *EntitySuperStruct) void {
        self.app.deinit();

        if (self.name) |name| {
            eng.get().general_allocator.free(name);
        }

        self.physics.deinit();
    }

    pub fn serialize(alloc: std.mem.Allocator, value: EntitySuperStruct) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        if (value.serialize_id) |sid| {
            try object.put("serialize_id", try sr.serialize_value(u32, alloc, sid));
        }
        try object.put("name", try sr.serialize_value(?[]const u8, alloc, value.name));
        try object.put("transform", try sr.serialize_value(Transform, alloc, value.transform));
        try object.put("model", try sr.serialize_value(?as.ModelAssetId, alloc, value.model));
        try object.put("physics", try sr.serialize_value(EntityPhysics, alloc, value.physics));
        try object.put("app", try sr.serialize_value(App.EntityData, alloc, value.app));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !EntitySuperStruct {
        var entity: EntitySuperStruct = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("serialize_id")) |v| blk: { entity.serialize_id = sr.deserialize_value(u32, alloc, v) catch break :blk; }
        if (object.get("name")) |v| blk: { entity.name = sr.deserialize_value(?[]const u8, alloc, v) catch break :blk; }
        if (object.get("transform")) |v| blk: { entity.transform = sr.deserialize_value(Transform, alloc, v) catch break :blk; }
        if (object.get("model")) |v| blk: { entity.model = sr.deserialize_value(?as.ModelAssetId, alloc, v) catch break :blk; }
        if (object.get("physics")) |v| blk: { entity.physics = sr.deserialize_value(EntityPhysics, alloc, v) catch break :blk; }
        if (object.get("app")) |v| blk: { entity.app = sr.deserialize_value(App.EntityData, alloc, v) catch break :blk; }

        return entity;
    }

    pub fn set_name(self: *EntitySuperStruct, name: ?[]const u8) !void {
        if (self.name) |n| { eng.get().general_allocator.free(n); }
        self.name = null;
        if (name) |n| { self.name = try eng.get().general_allocator.dupe(u8, n); }
    }

    /// Applies and initializes the given physics options to the entity
    pub fn set_physics(self: *EntitySuperStruct, entity_id: EntityId, new_settings: PhysicsSettings) !void {
        self.physics.settings = new_settings;
        self.physics.update_runtime_data(entity_id);
    }

    /// Removes the applied physics options from the entity
    pub fn remove_physics(self: *EntitySuperStruct, entity_id: EntityId) void {
        self.set_physics(entity_id, .{ .None = {} });
    }
};

pub const EntityList = struct {
    list: gen.GenerationalList(EntitySuperStruct),

    pub fn deinit(self: *EntityList) void {
        for (self.list.data.items) |*it| {
            if (it.item_data) |*entt| {
                entt.deinit();
            }
        }
        self.list.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !EntityList {
        var list = try gen.GenerationalList(EntitySuperStruct).init(alloc);
        errdefer list.deinit();

        // index 0 is reserved
        // this was done so that the selection texture can set the value 0 to mean 'no entity'
        try list.data.append(alloc, .{ .item_data = null, .generation = 1 });

        return EntityList {
            .list = list,
        };
    }

    /// Creates a new entity
    pub fn new_entity(self: *EntityList, entity_data: EntitySuperStruct) !EntityId {
        return try self.list.insert(entity_data);
    }

    /// Removes the entity with the given id
    pub fn remove_entity(self: *EntityList, entity_id: EntityId) !void {
        if (self.get(entity_id)) |entity| {
            entity.deinit();
        } else {
            return error.EntityDoesNotExist;
        }
        self.list.remove(entity_id) catch return error.EntityDoesNotExist;
    }

    /// Gets the entity with the given id if it exists
    pub fn get(self: *EntityList, entity_id: EntityId) ?*EntitySuperStruct {
        return self.list.get(entity_id);
    }

    /// Gets the entity at the given index if it exists regardless of generation
    pub fn get_dont_check_generation(self: *EntityList, index: usize) ?*EntitySuperStruct {
        if (index >= self.list.data.items.len) {
            return null;
        }
        if (self.list.data.items[index].item_data) |*ent| {
            return ent;
        }
        return null;
    }

    /// Finds an entity by name, returns null if not found
    pub fn find_entity_by_name(self: *const EntityList, name_to_find: []const u8) ?EntityId {
        for (self.list.data.items, 0..) |*it, idx| {
            if (it.item_data) |*ent| {
                if (ent.name) |entity_name| {
                    if (std.mem.eql(u8, name_to_find, entity_name)) {
                        return EntityId { .index = idx, .generation = it.generation };
                    }
                }
            }
        }
        return null;
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

pub const EntityPhysics = struct {
    const Self = @This();

    settings: PhysicsSettings = .{ .None = {} },
    runtime_data: PhysicsRuntimeData = .{ .None = {} },

    pub fn deinit(self: *Self) void {
        self.deinit_runtime_data();
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
        return try sr.serialize_value(PhysicsSettings, alloc, value.settings);
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !EntityPhysics {
        const settings = try sr.deserialize_value(PhysicsSettings, alloc, value);
        var entity_physics: EntityPhysics = .{};
        entity_physics.settings = settings;
        return entity_physics;
    }

    pub fn update_runtime_data(self: *Self, entity_id: EntityId) !void {
        const entity = eng.get().entities.get(entity_id) orelse return error.UnableToGetEntity;
        const transform = entity.transform;
        const phys = &eng.get().physics;

        self.deinit_runtime_data();

        switch (self.settings) {
            .None => {
                self.runtime_data = .{ .None = {} };
            },
            .Body => |b| {
                var settings = b.settings;
                settings.offset_transform.scale *= transform.scale;
                const shape = try phys.create_shape(settings);
                defer shape.release();

                const body = try phys.zphy.getBodyInterfaceMut().createAndAddBody(.{
                    .shape = shape,
                    .object_layer = if (b.is_static) physics.object_layers.non_moving else physics.object_layers.moving,
                    .motion_type = if (b.is_static) .static else .dynamic, // TODO: fix this
                    .is_sensor = b.is_sensor,
                }, .activate);

                self.runtime_data = .{
                    .Body = .{
                        .id = body,
                    }
                };
            },
            .Character => |settings| {
                const zphy_character = try settings.settings.create_character(transform, phys);
                errdefer zphy_character.destroy();

                zphy_character.addToPhysicsSystem(.{});

                self.runtime_data = .{
                    .Character = .{
                        .character = zphy_character,
                    }
                };
            },
            .CharacterVirtual => |settings| {
                const zphy_virtual_character = try settings.settings.create_character_virtual(transform, phys);
                errdefer zphy_virtual_character.destroy();

                var zphy_character: ?*zphy.Character = null;
                var body_filter: ?physics.IgnoreIdsBodyFilter = null;
                if (settings.create_character) {
                    var character_settings = physics.CharacterSettings {
                        .base = settings.settings.base,
                        .mass = settings.settings.mass,
                        .layer = physics.object_layers.moving,
                        .friction = 0.0,
                        .gravity_factor = 0.0,
                    };
                    switch (character_settings.base.shape.shape) {
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

        try self.set_full_user_data(physics.PhysicsSystem.construct_entity_user_data(entity_id, 0));
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
};
