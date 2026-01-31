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
    TransformComponent,
    PhysicsComponent,
    ModelComponent,
};

pub const SerializationComponent = struct {
    serialize_id: ?u32 = null,

    pub fn deinit(self: *SerializationComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !SerializationComponent {
        _ = alloc;
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: SerializationComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("serialize_id", try sr.serialize_value(?u32, alloc, value.serialize_id));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !SerializationComponent {
        var component: SerializationComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("serialize_id")) |v| blk: { component.serialize_id = sr.deserialize_value(?u32, alloc, v) catch break :blk; }

        return component;
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *SerializationComponent, key: anytype) !void {
        _ = entity;

        const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(outer_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
        }

        {
            _ = imui.push_form_layout_item(key ++ .{@src()});
            defer imui.pop_layout();

            _ = eng.ui.widgets.label.create(imui, "serialization id: ");
            const serialization_id_string = if (component.serialize_id) |serialization_id|
                try std.fmt.allocPrint(imui.widget_allocator(), "{}", .{serialization_id})
                else "TBD on next save";
            _ = eng.ui.widgets.label.create(imui, serialization_id_string);
        }
    }
};

pub const TransformComponent = struct {
    transform: Transform = .{},

    pub fn deinit(self: *TransformComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !TransformComponent {
        _ = alloc;
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

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *TransformComponent, key: anytype) !void {
        _ = entity;

        const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(outer_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
            w.children_gap = 5.0;
        }

        {
            _ = imui.push_form_layout_item(.{@src()});
            defer imui.pop_layout();

            _ = eng.ui.widgets.label.create(imui, "position: ");
            _ = eng.ui.widgets.number_slider.create(imui, &component.transform.position[0], .{}, key ++ .{@src()});
            _ = eng.ui.widgets.number_slider.create(imui, &component.transform.position[1], .{}, key ++ .{@src()});
            _ = eng.ui.widgets.number_slider.create(imui, &component.transform.position[2], .{}, key ++ .{@src()});
        }
        {
            _ = imui.push_form_layout_item(.{@src()});
            defer imui.pop_layout();

            _ = eng.ui.widgets.label.create(imui, "rotation: ");
            var rot = zm.loadArr3(zm.quatToRollPitchYaw(component.transform.rotation)) * zm.f32x4s(180.0 / std.math.pi);
            const rx = eng.ui.widgets.number_slider.create(imui, &rot[0], .{}, key ++ .{@src()});
            const ry = eng.ui.widgets.number_slider.create(imui, &rot[1], .{}, key ++ .{@src()});
            const rz = eng.ui.widgets.number_slider.create(imui, &rot[2], .{}, key ++ .{@src()});

            if (rx.data_changed or ry.data_changed or rz.data_changed) {
                rot = rot * zm.f32x4s(std.math.pi / 180.0);
                component.transform.rotation = zm.quatFromRollPitchYawV(rot);
            }
        }
        {
            _ = imui.push_form_layout_item(.{@src()});
            defer imui.pop_layout();

            _ = eng.ui.widgets.label.create(imui, "scale: ");
            _ = eng.ui.widgets.number_slider.create(imui, &component.transform.scale[0], .{}, key ++ .{@src()});
            _ = eng.ui.widgets.number_slider.create(imui, &component.transform.scale[1], .{}, key ++ .{@src()});
            _ = eng.ui.widgets.number_slider.create(imui, &component.transform.scale[2], .{}, key ++ .{@src()});
        }
    }
};

pub const ModelComponent = struct {
    model: ?as.ModelAssetId = null,

    pub fn deinit(self: *ModelComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !ModelComponent {
        _ = alloc;
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: ModelComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("model", try sr.serialize_value(?as.ModelAssetId, alloc, value.model));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !ModelComponent {
        var component: ModelComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        if (object.get("model")) |v| blk: { component.model = sr.deserialize_value(?as.ModelAssetId, alloc, v) catch break :blk; }

        return component;
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *ModelComponent, key: anytype) !void {
        _ = entity;
        
        const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(outer_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
        }

        {
            _ = imui.push_form_layout_item(key ++ .{@src()});
            defer imui.pop_layout();

            _ = eng.ui.widgets.label.create(imui, "model: ");

            const model_combobox = eng.ui.widgets.combobox.create(imui, key ++ .{@src()});
            if (model_combobox.init) {
                std.log.info("model combobox init", .{});

                const model_combobox_data, _ = imui.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, model_combobox.id) catch unreachable;
                model_combobox_data.default_text = imui.widget_allocator().dupe(u8, "None") catch unreachable;
                model_combobox_data.can_be_default = true;

                var model_names = get_all_model_names(eng.get().frame_allocator) catch unreachable;
                defer model_names.deinit();

                for (model_names.names) |option| {
                    model_combobox_data.append_option(imui.widget_allocator(), option) catch |err| {
                        std.log.err("Failed to append combobox option: {}", .{err});
                        break;
                    };
                }

                model_combobox_data.selected_index = null;

                if (component.model) |model_id| {
                    const model_text = model_id.to_string_identifier(eng.get().frame_allocator) catch unreachable;
                    defer eng.get().frame_allocator.free(model_text);

                    for (model_combobox_data.options.items, 0..) |option, i| {
                        if (std.mem.eql(u8, option, model_text)) {
                            model_combobox_data.selected_index = i;
                            break;
                        }
                    }
                }
            }
            if (model_combobox.data_changed) {
                const model_combobox_data, _ = imui.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, model_combobox.id) catch unreachable;
                if (model_combobox_data.selected_index) |si| {
                    if (eng.assets.ModelAssetId.from_string_identifier(model_combobox_data.options.items[si])) |model_id| {
                        component.model = model_id;
                    } else |_| { 
                        std.log.err("Failed to deserialize model id!", .{});
                    }
                } else {
                    component.model = null;
                }
            }
        }
    }
    
    const ModelNames = struct {
        arena: std.heap.ArenaAllocator,
        names: [][]u8,

        pub fn deinit(self: *ModelNames) void {
            self.arena.allocator().free(self.names);
            self.arena.deinit();
        }
    };

    fn get_all_model_names(alloc: std.mem.Allocator) !ModelNames {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        // generate model option names from asset packs
        var model_names = std.ArrayList([]u8).empty;
        defer model_names.deinit(alloc);

        var asset_packs_iter = eng.get().asset_manager.asset_packs.iterator();
        while (asset_packs_iter.next()) |it| {
            const pack = it.value_ptr;
            var iter = pack.assets.iterator();
            while (iter.next()) |p| {
                switch (p.value_ptr.asset) {
                    .Model => {
                        const asset_id = eng.assets.ModelAssetId{ .pack_id = pack.unique_name_hash, .asset_id = p.key_ptr.* };

                        const asset_identifier_string = try asset_id.to_string_identifier(alloc);
                        defer alloc.free(asset_identifier_string);

                        try model_names.append(alloc, try std.fmt.allocPrint(arena.allocator(), "{s}", .{asset_identifier_string}));
                    },
                    else => {},
                }
            }
        }

        return ModelNames {
            .arena = arena,
            .names = try model_names.toOwnedSlice(alloc),
        };
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

const PhysicsUiData = struct {
    settings: eng.entity.PhysicsSettings,

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

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *PhysicsComponent, key: anytype) !void {
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
                const physics_options_fields = @typeInfo(eng.entity.PhysicsOptionsEnum).@"enum".fields;
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
                    switch (@as(eng.entity.PhysicsOptionsEnum, @enumFromInt(si))) {
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
                        if (eng.get().ecs.get_component(eng.entity.ModelComponent, entity)) |model_component| {
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
        const entity_transform_component = eng.get().ecs.get_component(eng.entity.TransformComponent, entity) orelse return error.EntityDoesNotHaveTransform;
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
};
