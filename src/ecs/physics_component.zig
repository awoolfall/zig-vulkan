const std = @import("std");
const eng = @import("self");
const sr = eng.serialize;
const physics = eng.physics;
const zphy = physics.zphy;
const zm = eng.zmath;

pub const COMPONENT_UUID = "71e2a14f-8a22-43ee-aed4-65592fe637ea";
pub const COMPONENT_NAME = "Physics";

const Self = @This();

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

settings: PhysicsSettings = .{ .None = {} },
runtime_data: PhysicsRuntimeData = .{ .None = {} },
velocity: zm.F32x4 = zm.f32x4s(0.0),

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

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try object.put("settings", try sr.serialize_value(PhysicsSettings, alloc, self.settings));
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    var component: Self = .{};

    if (object.get("settings")) |v| blk: { component.settings = sr.deserialize_value(PhysicsSettings, alloc, v) catch break :blk; }

    try component.update_runtime_data(entity);
    return component;
}

const PhysicsUiData = struct {
    settings: PhysicsSettings,

    pub fn deinit(self: *PhysicsUiData, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn init(alloc: std.mem.Allocator) !PhysicsUiData {
        _ = alloc;
        return PhysicsUiData { .settings = .{ .None = {} } };
    }

    pub fn clone(self: *PhysicsUiData, alloc: std.mem.Allocator) !PhysicsUiData {
        _ = alloc;
        return self.*;
    }
};

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(outer_layout)) |w| {
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
    }

    {
        const physics_button = eng.ui.widgets.badge.create(imui, "Set Physics", key ++ .{@src()});
        const data, _ = imui.get_widget_data(PhysicsUiData, physics_button.id.box) catch return error.UnableToGetPhysicsUiData;

        if (physics_button.clicked) {
            component.settings = data.settings;
            component.update_runtime_data(entity) catch |err| {
                std.log.err("Unable to update selected entity physics: {}", .{err});
            };
        }
        
        const physics_combobox = eng.ui.widgets.combobox.create(imui, key ++ .{@src()});
        const physics_combobox_data, _ = imui.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, physics_combobox.id) catch |err| {
            std.log.err("Unable to get physics combobox data: {}", .{err});
            unreachable;
        };
        if (physics_combobox.init) {
            physics_combobox_data.default_text = imui.widget_allocator().dupe(u8, "None") catch |err| {
                std.log.err("Failed to set default physics combobox text: {}", .{err});
                unreachable;
            };
            physics_combobox_data.can_be_default = false;
        
            // generate physics option names from enum
            const physics_options_fields = @typeInfo(PhysicsOptionsEnum).@"enum".fields;
            inline for (physics_options_fields) |field| {
                physics_combobox_data.append_option(imui.widget_allocator(), field.name) catch |err| {
                    std.log.err("Failed to append physics option to combobox: {}", .{err});
                    unreachable;
                };
            }
        
            // set physics descriptor
            data.settings = component.settings;
            physics_combobox_data.selected_index = @intFromEnum(data.settings);
        }
        if (physics_combobox.data_changed) {
            if (physics_combobox_data.selected_index) |si| {
                switch (@as(PhysicsOptionsEnum, @enumFromInt(si))) {
                    .None => data.settings = .{ .None = {} },
                    .Body => data.settings = .{ .Body = .{} },
                    .Character => data.settings = .{ .Character = .{} },
                    .CharacterVirtual => data.settings = .{ .CharacterVirtual = .{} },
                }
            }
        }

        const transform_layout = imui.push_layout(.Y, key ++ .{@src()});
        if (imui.get_widget(transform_layout)) |transform_layout_widget| {
            transform_layout_widget.semantic_size[0].kind = .ParentPercentage;
            transform_layout_widget.semantic_size[0].value = 1.0;
            transform_layout_widget.children_gap = 5;
            transform_layout_widget.padding_px = .{
                .left = 20.0,
            };
        }
        defer imui.pop_layout();
    
        switch (data.settings) {
            .None => {},
            .Body => |*b| {
                physics_shape_editor_ui(entity, &b.settings, key ++ .{@src()});

                {
                    _ = imui.push_form_layout_item(key ++ .{@src()});
                    defer imui.pop_layout();

                    _ = eng.ui.widgets.label.create(imui, "is sensor:");
                    _ = eng.ui.widgets.checkbox.create(imui, &b.is_sensor, "", key ++ .{@src()});
                }
                {
                    _ = imui.push_form_layout_item(key ++ .{@src()});
                    defer imui.pop_layout();
                    
                    _ = eng.ui.widgets.label.create(imui, "is static:");
                    _ = eng.ui.widgets.checkbox.create(imui, &b.is_static, "", key ++ .{@src()});
                }
            },
            .Character => |_| {
                _ = eng.ui.widgets.label.create(imui, "is character");
            },
            .CharacterVirtual => |_| {
                _ = eng.ui.widgets.label.create(imui, "is virtual character");
            },
        }
    }
}

fn physics_shape_editor_ui(
    entity: eng.ecs.Entity,
    shape_settings: *eng.physics.ShapeSettings, 
    key: anytype
) void {
    const imui = &eng.get().imui;

    const shape_combobox = eng.ui.widgets.combobox.create(imui, key ++ .{@src()});
    const shape_combobox_data, _ = imui.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, shape_combobox.id) catch |err| {
        std.log.err("Unable to get combobox widget data: {}", .{ err });
        unreachable;
    };
    if (shape_combobox.init) {
        shape_combobox_data.can_be_default = false;
        const shape_fields = @typeInfo(eng.physics.ShapeSettingsEnum).@"enum".fields;
        inline for (shape_fields) |field| {
            shape_combobox_data.append_option(imui.widget_allocator(), field.name) catch |err| {
                std.log.err("Failed to append physics option to combobox: {}", .{err});
                unreachable;
            };
        }
    }
    if (shape_combobox.data_changed) {
        if (shape_combobox_data.selected_index) |si| {
            switch (@as(eng.physics.ShapeSettingsEnum, @enumFromInt(si))) {
                .Capsule => shape_settings.shape = .{ .Capsule = .{
                    .half_height = 0.7,
                    .radius = 0.2,
                } },
                .Sphere => shape_settings.shape = .{ .Sphere = .{
                    .radius = 1.0,
                } },
                .Box => shape_settings.shape = .{ .Box = .{
                    .width = 1.0,
                    .height = 1.0,
                    .depth = 1.0,
                } },
                .ModelCompoundConvexHull => {
                    if (eng.get().ecs.get_component(eng.ecs.ModelComponent, entity)) |model_component| {
                        if (model_component.model) |m| {
                            shape_settings.shape = .{ .ModelCompoundConvexHull = m };
                        } else {
                            std.log.warn("Cannot set physics to model convex hull as the entity's model component has no assigned model", .{});
                            shape_combobox_data.selected_index = null;
                            shape_settings.shape = .{ .Sphere = .{ .radius = 0.5, } };
                        }
                    } else {
                        std.log.warn("Cannot set physics to model convex hull as entity does not have a model component", .{});
                        shape_combobox_data.selected_index = null;
                        shape_settings.shape = .{ .Sphere = .{ .radius = 0.5, } };
                    }
                },
            }
        }
    }

    const sl = imui.push_layout(.Y, key ++ .{@src()});
    if (imui.get_widget(sl)) |sl_widget| {
        sl_widget.semantic_size[0].kind = .ParentPercentage;
        sl_widget.semantic_size[0].value = 1.0;
        sl_widget.padding_px = .{
            .left = 20.0,
        };
        sl_widget.children_gap = 5;
    }

    switch (shape_settings.shape) {
        .Capsule => |*c| {
            create_form_number_slider("radius:", &c.radius, key ++ .{@src()});
            var height = c.half_height * 2.0;
            create_form_number_slider("height:", &height, key ++ .{@src()});
            c.half_height = height * 0.5;
        },
        .Sphere => |*s| {
            create_form_number_slider("radius:", &s.radius, key ++ .{@src()});
        },
        .Box => |*b| {
            create_form_number_slider("width:", &b.width, key ++ .{@src()});
            create_form_number_slider("height:", &b.height, key ++ .{@src()});
            create_form_number_slider("depth:", &b.depth, key ++ .{@src()});
        },
        .ModelCompoundConvexHull => |_| {
        },
    }

    imui.pop_layout(); // sl
}

fn create_form_number_slider(
    text: []const u8,
    value: *f32, 
    key: anytype
) void {
    const imui = &eng.get().imui;

    _ = imui.push_form_layout_item(key ++ .{@src()});
    defer imui.pop_layout();

    _ = eng.ui.widgets.label.create(imui, text);
    _ = eng.ui.widgets.number_slider.create(imui, value, .{}, key ++ .{@src()});
}

pub fn update_runtime_data(self: *Self, entity: eng.ecs.Entity) !void {
    const entity_transform_component = eng.get().ecs.get_component(eng.ecs.TransformComponent, entity) orelse return error.EntityDoesNotHaveTransform;
    const transform = entity_transform_component.transform;

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

    try self.set_full_user_data(physics.PhysicsSystem.construct_entity_user_data(entity.idx, 0));
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
