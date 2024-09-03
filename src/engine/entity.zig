const std = @import("std");
const zm = @import("zmath");
const gen = @import("gen_list.zig");
const tf = @import("transform.zig");
const as = @import("../asset/asset.zig");
const physics = @import("physics.zig");
const zphy = physics.zphy;
const en = @import("../engine.zig");

pub fn EntitySuperStruct(comptime App: type) type {
    return struct {
        name: ?[]const u8,
        transform: tf.Transform,
        model: ?as.ModelAssetId,
        physics: ?PhysicsOptions,
        app: App.EntityData,

        pub fn deinit(self: *EntitySuperStruct(App), engine: *en.Engine(App)) void {
            self.app.deinit();

            if (self.name) |name| {
                engine.general_allocator.allocator().free(name);
            }

            if (self.physics) |*phys| {
                phys.deinit(&engine.physics);
                self.physics = null;
            }
        }

        pub fn init_no_physics(desc: EntityDescriptor(App), engine: *en.Engine(App)) !EntitySuperStruct(App) {
            var name: ?[]const u8 = null;
            if (desc.name) |n| {
                name = try engine.general_allocator.allocator().dupe(u8, n);
            }

            return EntitySuperStruct(App) {
                .name = name,
                .transform = desc.transform,
                .model = desc.model,
                .physics = null,
                .app = desc.app,
            };
        }

        /// Applies and initializes the given physics options to the entity
        pub fn set_physics(self: *EntitySuperStruct(App), entity_id: gen.GenerationalIndex, desc: PhysicsOptionsDescriptor, physics_system: *physics.PhysicsSystem) !void {
            self.remove_physics(physics_system);
            self.physics = try PhysicsOptions.init(desc, entity_id, physics_system);
        }

        /// Removes the applied physics options from the entity
        pub fn remove_physics(self: *EntitySuperStruct(App), physics_system: *physics.PhysicsSystem) void {
            if (self.physics) |*entity_physics| {
                entity_physics.deinit(physics_system);
                self.physics = null;
            }
        }
    };
}

pub fn EntityDescriptor(comptime App: type) type {
    return struct {
        name: ?[]const u8 = null,
        transform: tf.Transform = tf.Transform.new(),
        model: ?as.ModelAssetId = null,
        physics: ?PhysicsOptionsDescriptor = null,
        app: App.EntityData = App.EntityData {},
    };
}

pub fn EntityList(comptime App: type) type {
    return struct {
        list: gen.GenerationalList(EntitySuperStruct(App)),
        engine: *en.Engine(App),

        pub fn deinit(self: *EntityList(App), engine: *en.Engine(App)) void {
            for (self.list.data.items) |*it| {
                if (it.item_data) |*entt| {
                    entt.deinit(engine);
                }
            }
            self.list.deinit();
        }

        pub fn init(alloc: std.mem.Allocator, engine: *en.Engine(App)) !EntityList(App) {
            return EntityList(App) {
                .list = try gen.GenerationalList(EntitySuperStruct(App)).init(alloc),
                .engine = engine,
            };
        }

        /// Creates a new entity with the given descriptor
        pub fn new_entity(self: *EntityList(App), desc: EntityDescriptor(App)) !gen.GenerationalIndex {
            const entity = try EntitySuperStruct(App).init_no_physics(desc, self.engine);
            const inserted_entity_id = try self.list.insert(entity);

            if (desc.physics) |desc_physics| {
                self.get(inserted_entity_id).?.set_physics(inserted_entity_id, desc_physics, &self.engine.physics) catch {
                    self.list.remove(inserted_entity_id) catch unreachable;
                    return error.FailedToAddPhysics;
                };
            }

            return inserted_entity_id;
        }

        /// Removes the entity with the given id
        pub fn remove_entity(self: *EntityList(App), entity_id: gen.GenerationalIndex) !void {
            if (self.get(entity_id)) |entity| {
                entity.deinit(self.engine);
            } else {
                return error.EntityDoesNotExist;
            }
            self.list.remove(entity_id) catch return error.EntityDoesNotExist;
        }

        /// Gets the entity with the given id if it exists
        pub fn get(self: *EntityList(App), entity_id: gen.GenerationalIndex) ?*EntitySuperStruct(App) {
            return self.list.get(entity_id);
        }
    };
}

pub const PhysicsOptions = union(enum) {
    Body: physics.zphy.BodyId,
    Character: *physics.zphy.Character,
    CharacterVirtual: struct {
        virtual: *physics.zphy.CharacterVirtual,
        character: ?*physics.zphy.Character,
        extended_update_settings: ?physics.zphy.CharacterVirtual.ExtendedUpdateSettings = null,
        body_filter: ?*const physics.zphy.BodyFilter = null,
    },

    pub fn deinit(self: *PhysicsOptions, phys: *physics.PhysicsSystem) void {
        switch (self.*) {
            .Body => |body_id| {
                phys.zphy.getBodyInterfaceMut().removeAndDestroyBody(body_id);
            },
            .Character => |character| {
                character.removeFromPhysicsSystem(.{});
                character.destroy();
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

    pub fn init(desc: PhysicsOptionsDescriptor, entity_id: gen.GenerationalIndex, phys: *physics.PhysicsSystem) !PhysicsOptions {
        const physics_options = blk: { switch (desc) {
            .Body => |body_id| {
                break :blk PhysicsOptions {
                    .Body = body_id,
                };
            },
            .Character => |settings| {
                const zphy_character = try settings.settings.create_character(settings.transform, phys);
                errdefer zphy_character.destroy();

                zphy_character.addToPhysicsSystem(.{});

                break :blk PhysicsOptions {
                    .Character = zphy_character,
                };
            },
            .CharacterVirtual => |settings| {
                const zphy_virtual_character = try settings.settings.create_character_virtual(settings.transform, phys);
                errdefer zphy_virtual_character.destroy();

                var zphy_character: ?*zphy.Character = null;
                if (settings.create_character) {
                    const character_settings = physics.CharacterSettings {
                        .base = settings.settings.base,
                        .mass = settings.settings.mass,
                        .layer = physics.object_layers.moving,
                        .friction = 0.0,
                        .gravity_factor = 0.0,
                    };

                    zphy_character = try character_settings.create_character(settings.transform, phys);
                    zphy_character.?.addToPhysicsSystem(.{});
                }

                break :blk PhysicsOptions {
                    .CharacterVirtual = .{
                        .virtual = zphy_virtual_character,
                        .character = zphy_character,
                        .extended_update_settings = settings.extended_update_settings,
                        .body_filter = settings.body_filter,
                    },
                };
            },
        } };

        physics_options.set_full_user_data(physics.PhysicsSystem.construct_entity_user_data(entity_id, 0), phys);
        return physics_options;
    }

    /// Sets the full 64 bit user data for the physics body
    fn set_full_user_data(self: *const PhysicsOptions, data: u64, physics_system: *physics.PhysicsSystem) void {
        const body_id: ?physics.zphy.BodyId = switch (self.*) {
            .Body => |body_id| body_id,
            .Character => |character| character.getBodyId(),
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
            .Body => |body_id| body_id,
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

pub const PhysicsOptionsDescriptor = union(enum) {
    Body: physics.zphy.BodyId,
    Character: struct {
        settings: physics.CharacterSettings,
        transform: tf.Transform,
    },
    CharacterVirtual: struct {
        settings: physics.CharacterVirtualSettings,
        transform: tf.Transform,
        create_character: bool,
        extended_update_settings: ?zphy.CharacterVirtual.ExtendedUpdateSettings = null,
        body_filter: ?*const zphy.BodyFilter = null,
    },
};

