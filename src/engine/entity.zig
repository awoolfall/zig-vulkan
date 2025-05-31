const std = @import("std");
const zm = @import("zmath");
const gen = @import("gen_list.zig");
const Transform = @import("transform.zig");
const as = @import("../asset/asset.zig");
const physics = @import("physics.zig");
const zphy = physics.zphy;
const eng = @import("../root.zig");
const Engine = @import("../engine.zig");
const App = @import("app");

pub const EntitySuperStruct = struct {
    should_serialize: bool = false,
    serialize_id: ?u32 = null,

    name: ?[]const u8,
    transform: Transform,
    model: ?as.ModelAssetId,
    physics: ?PhysicsOptions,
    app: App.EntityData,

    pub fn deinit(self: *EntitySuperStruct) void {
        self.app.deinit();

        if (self.name) |name| {
            eng.get().general_allocator.free(name);
        }

        if (self.physics) |*phys| {
            phys.deinit(&eng.get().physics);
            self.physics = null;
        }
    }

    pub fn init_no_physics(desc: EntityDescriptor) !EntitySuperStruct {
        var name: ?[]const u8 = null;
        if (desc.name) |n| {
            name = try eng.get().general_allocator.dupe(u8, n);
        }

        return EntitySuperStruct {
            .name = name,
            .should_serialize = desc.should_serialize,
            .serialize_id = desc.serialize_id,
            .transform = desc.transform,
            .model = if (desc.model) |model_asset_str| 
                try as.ModelAssetId.deserialize(model_asset_str) else null,
            .physics = null,
            .app = try App.EntityData.init(desc.app),
        };
    }

    pub fn descriptor(self: *const EntitySuperStruct, alloc: std.mem.Allocator) !EntityDescriptor {
        return EntityDescriptor {
            .should_serialize = self.should_serialize,
            .serialize_id = self.serialize_id,
            .name = self.name,
            .transform = self.transform,
            .model = if (self.model) |model_asset_id| try model_asset_id.serialize(alloc) else null,
            .physics = if (self.physics) |phys| phys.descriptor() else null,
            .app = try self.app.descriptor(alloc),
        };
    }

    /// Applies and initializes the given physics options to the entity
    pub fn set_physics(self: *EntitySuperStruct, entity_id: gen.GenerationalIndex, desc: PhysicsOptionsDescriptor, physics_system: *physics.PhysicsSystem) !void {
        self.remove_physics(physics_system);
        self.physics = try PhysicsOptions.init(desc, self.transform, entity_id, physics_system);
    }

    /// Removes the applied physics options from the entity
    pub fn remove_physics(self: *EntitySuperStruct, physics_system: *physics.PhysicsSystem) void {
        if (self.physics) |*entity_physics| {
            entity_physics.deinit(physics_system);
            self.physics = null;
        }
    }
};

pub const EntityDescriptor = struct {
    should_serialize: bool = false,
    serialize_id: ?u32 = null,

    name: ?[]const u8 = null,
    transform: Transform = .{},
    model: ?[]const u8 = null,
    physics: ?PhysicsOptionsDescriptor = null,
    app: App.EntityData.Descriptor = App.EntityData.Descriptor {},
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
        try list.data.append(.{ .item_data = null, .generation = 1 });

        return EntityList {
            .list = list,
        };
    }

    /// Creates a new entity with the given descriptor
    pub fn new_entity(self: *EntityList, desc: EntityDescriptor) !gen.GenerationalIndex {
        const entity = try EntitySuperStruct.init_no_physics(desc);
        const inserted_entity_id = try self.list.insert(entity);

        if (desc.physics) |desc_physics| {
            self.get(inserted_entity_id).?.set_physics(inserted_entity_id, desc_physics, &eng.get().physics) catch {
                self.list.remove(inserted_entity_id) catch unreachable;
                return error.FailedToAddPhysics;
            };
        }

        return inserted_entity_id;
    }

    /// Removes the entity with the given id
    pub fn remove_entity(self: *EntityList, entity_id: gen.GenerationalIndex) !void {
        if (self.get(entity_id)) |entity| {
            entity.deinit();
        } else {
            return error.EntityDoesNotExist;
        }
        self.list.remove(entity_id) catch return error.EntityDoesNotExist;
    }

    /// Gets the entity with the given id if it exists
    pub fn get(self: *EntityList, entity_id: gen.GenerationalIndex) ?*EntitySuperStruct {
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
    pub fn find_entity_by_name(self: *const EntityList, name_to_find: []const u8) ?gen.GenerationalIndex {
        for (self.list.data.items, 0..) |*it, idx| {
            if (it.item_data) |*ent| {
                if (ent.name) |entity_name| {
                    if (std.mem.eql(u8, name_to_find, entity_name)) {
                        return gen.GenerationalIndex { .index = idx, .generation = it.generation };
                    }
                }
            }
        }
        return null;
    }
};

pub const PhysicsOptions = union(PhysicsOptionsEnum) {
    Body: struct {
        descriptor: PhysicsOptionsDescriptor,
        id: physics.zphy.BodyId,
    },
    Character: struct {
        character: *physics.zphy.Character,
        settings: physics.CharacterSettings,
    },
    CharacterVirtual: struct {
        virtual: *physics.zphy.CharacterVirtual,
        character: ?*physics.zphy.Character,
        settings: physics.CharacterVirtualSettings,
        extended_update_settings: ?physics.zphy.CharacterVirtual.ExtendedUpdateSettings = null,
        body_filter: ?physics.IgnoreIdsBodyFilter = null,
    },

    pub fn deinit(self: *PhysicsOptions, phys: *physics.PhysicsSystem) void {
        switch (self.*) {
            .Body => |body| {
                phys.zphy.getBodyInterfaceMut().removeAndDestroyBody(body.id);
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
    }

    pub fn init(desc: PhysicsOptionsDescriptor, transform: Transform, entity_id: gen.GenerationalIndex, phys: *physics.PhysicsSystem) !PhysicsOptions {
        const physics_options = blk: { switch (desc) {
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

                break :blk PhysicsOptions {
                    .Body = .{ .id = body, .descriptor = desc },
                };
            },
            .Character => |settings| {
                const zphy_character = try settings.settings.create_character(transform, phys);
                errdefer zphy_character.destroy();

                zphy_character.addToPhysicsSystem(.{});

                break :blk PhysicsOptions {
                    .Character = .{
                        .character = zphy_character,
                        .settings = settings.settings,
                    },
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

                break :blk PhysicsOptions {
                    .CharacterVirtual = .{
                        .virtual = zphy_virtual_character,
                        .character = zphy_character,
                        .settings = settings.settings,
                        .extended_update_settings = settings.extended_update_settings,
                        .body_filter = body_filter,
                    },
                };
            },
        } };

        physics_options.set_full_user_data(physics.PhysicsSystem.construct_entity_user_data(entity_id, 0), phys);
        return physics_options;
    }

    pub fn descriptor(self: *const PhysicsOptions) PhysicsOptionsDescriptor {
        // if (self.* == .CharacterVirtual) {
        //     @panic("TDOD: body_filter must be made declarative");
        // }
        return switch (self.*) {
            .Body => |b| blk: {
                // TODO: currently we cannot modify any body parameters after creation
                break :blk b.descriptor;
            },
            .Character => |character| .{ 
                .Character = .{
                    .settings = character.settings,
                },
            },
            .CharacterVirtual => |character| .{
                .CharacterVirtual = .{
                    .settings = character.settings,
                    .create_character = (character.character != null),
                    .extended_update_settings = character.extended_update_settings,
                },
            },
        };
    }

    /// Sets the full 64 bit user data for the physics body
    fn set_full_user_data(self: *const PhysicsOptions, data: u64, physics_system: *physics.PhysicsSystem) void {
        const body_id: ?physics.zphy.BodyId = switch (self.*) {
            .Body => |body| body.id,
            .Character => |character| character.character.getBodyId(),
            .CharacterVirtual => |character| if (character.character) |c| c.getBodyId() else null,
        };

        if (body_id) |bid| {
            var write_lock = physics_system.init_body_write_lock(bid) catch unreachable;
            defer write_lock.deinit();

            write_lock.body.setUserData(data);
        }
    }

    /// Sets the end user accessable 16 bit user data for the physics body
    pub fn set_user_data(self: *const PhysicsOptions, data: u16, physics_system: *physics.PhysicsSystem) void {
        const body_id: ?physics.zphy.BodyId = switch (self.*) {
            .Body => |body| body.id,
            .Character => |character| character.getBodyId(),
            .CharacterVirtual => |character| if (character.character) |c| c.getBodyId() else null,
        };

        if (body_id) |bid| {
            var write_lock = physics_system.init_body_write_lock(bid) catch unreachable;
            defer write_lock.deinit();

            const user_data = write_lock.body.getUserData();
            write_lock.body.setUserData(physics.PhysicsSystem.construct_entity_user_data_raw(user_data, data));
        }
    }
};

pub const PhysicsOptionsEnum = enum {
    Body,
    Character,
    CharacterVirtual,
};

pub const PhysicsOptionsDescriptor = union(PhysicsOptionsEnum) {
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

