const std = @import("std");
const eng = @import("self");
const gen = eng.gen;
const sr = eng.serialize;

// -- Standard Components --

pub const SerializationComponent = @import("../ecs/serialization_component.zig");
pub const TransformComponent = @import("../ecs/transform_component.zig");
pub const ModelComponent = @import("../ecs/model_component.zig");
pub const PhysicsComponent = @import("../ecs/physics_component.zig");

pub const StandardEntityComponents = .{
    SerializationComponent,
    TransformComponent,
    ModelComponent,
    PhysicsComponent,
};

// -- Standard Components --

pub const Entity = struct {
    idx: gen.GenerationalIndex,
};

pub fn EcsSystem(comptime EcsComponentTypes: anytype) type {
    const info = @typeInfo(@TypeOf(EcsComponentTypes));

    // ensure all component types are unique
    inline for (info.@"struct".fields, 0..) |_, idx0| {
        inline for (info.@"struct".fields, 0..) |_, idx1| {
            if (idx0 == idx1) { continue; }
            if (EcsComponentTypes[idx0] == EcsComponentTypes[idx1]) {
                @compileError("All component types must be unique.");
            }
        }
    }

    // default component indices tuple contains null in all fields
    const component_indices_tuple_default_value = blk: {
        var tuple: ComponentIndicesTuple(EcsComponentTypes) = undefined;
        inline for (info.@"struct".fields, 0..) |_, idx| {
            tuple[idx] = null;
        }
        break :blk tuple;
    };

    return struct {
        const Self = @This();
        pub const ComponentTypes = EcsComponentTypes;
        
        pub const EntityInternal = struct {
            name: ?[]const u8 = null,
            components: ComponentIndicesTuple(ComponentTypes) = component_indices_tuple_default_value,
        };

        alloc: std.mem.Allocator,
        entity_data: gen.GenerationalList(EntityInternal),
        components: ComponentListTuple(ComponentTypes),

        pub fn deinit(self: *Self) void {
            // deinit all entities
            var entity_iter = self.entity_iterator();
            while (entity_iter.next()) |entity| {
                self.remove_entity(entity);
            }
            self.entity_data.deinit();

            // deinit component lists
            inline for (info.@"struct".fields, 0..) |_, idx| {
                var iter = self.components[idx].component_list.iterator();
                while (iter.next()) |item| {
                    // this should never be called since all components should be linked by an entity
                    std.log.warn("Component was leftover in ECS after removing all entities", .{});
                    item.deinit();
                }
                self.components[idx].component_list.deinit();
                self.components[idx].entity_ref_list.deinit(self.alloc);
            }
        }

        pub fn init(alloc: std.mem.Allocator) !Self {
            var components: ComponentListTuple(ComponentTypes) = undefined;
            inline for (info.@"struct".fields, 0..) |_, idx| {
                components[idx] = .{
                    .component_list = try .init(alloc),
                    .entity_ref_list = .empty,
                };
                errdefer components[idx].component_list.deinit();
                errdefer components[idx].entity_ref_list.deinit(alloc);
            }

            const entities_list = try gen.GenerationalList(EntityInternal).init(alloc);
            errdefer entities_list.deinit();

            return Self {
                .alloc = alloc,
                .components = components,
                .entity_data = entities_list,
            };
        }

        pub fn set_entity_name(self: *Self, entity: Entity, name: ?[]const u8) !void {
            const ent = self.entity_data.get(entity.idx) orelse return;
            if (ent.name) |n| {
                eng.get().general_allocator.free(n);
                ent.name = null;
            }
            if (name) |n| {
                ent.name = try eng.get().general_allocator.dupe(u8, n);
            }
        }

        pub fn get_entity_name(self: *const Self, entity: Entity) ?[]const u8 {
            return (self.entity_data.get(entity.idx) orelse return null).name;
        }

        pub fn find_first_entity_with_name(self: *Self, search_name: []const u8) ?Entity {
            var entity_iter = self.entity_iterator();
            while (entity_iter.next()) |entity| {
                if (self.get_entity_name(entity)) |entity_name| {
                    if (std.mem.eql(u8, entity_name, search_name)) {
                        return entity;
                    }
                }
            }
            return null;
        }

        fn get_component_list(self: *Self, comptime T: type) *ComponentList(T) {
            return &self.components[get_component_id(T)];
        }

        fn get_component_id(comptime T: type) comptime_int {
            inline for (info.@"struct".fields, 0..) |_, idx| {
                if (T == ComponentTypes[idx]) { return idx; }
            }
            @compileError(std.fmt.comptimePrint("The type '{s}' is not a ECS component.", .{@typeName(T)}));
        }

        pub fn get_component_count(self: *const Self, comptime T: type) usize {
            return self.components[get_component_id(T)].component_list.item_count();
        }

        pub fn component_iterator(self: *Self, comptime Component: type) gen.GenerationalListIterator(Component) {
            return self.get_component_list(Component).component_list.iterator();
        }

        pub fn query_iterator(self: *Self, comptime QueryComponents: anytype) QueryIterator(QueryComponents) {
            return QueryIterator(QueryComponents).init(self);
        }

        pub fn entity_iterator(self: *Self) EntityIterator {
            return EntityIterator.init(self);
        }

        pub fn create_new_entity(self: *Self) !Entity {
            return Entity {
                .idx = try self.entity_data.insert(.{}),
            };
        }

        pub fn remove_entity(self: *Self, entity: Entity) void {
            const ent = self.entity_data.get(entity.idx) orelse return;

            // deinit entity name by setting it to null
            self.set_entity_name(entity, null) catch {};

            // remove all entity components
            inline for (info.@"struct".fields, 0..) |_, idx| {
                if (ent.components[idx] != null) {
                    self.remove_component(ComponentTypes[idx], entity);
                }
            }
            
            self.entity_data.remove(entity.idx) catch unreachable;
        }

        pub fn get_component(self: *Self, comptime Component: type, entity: Entity) ?*Component {
            const ent = self.entity_data.get(entity.idx) orelse return null;
            const id = ent.components[get_component_id(Component)] orelse return null;
            return self.get_component_list(Component).component_list.get(id);
        }

        pub fn add_component(self: *Self, comptime Component: type, entity: Entity) !*Component {
            const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
            if (ent.components[get_component_id(Component)] == null) {
                const list = self.get_component_list(Component);

                var new_component = try Component.init(self.alloc);
                errdefer new_component.deinit();

                const component_idx = try list.component_list.insert(new_component);
                errdefer list.component_list.remove(component_idx) catch unreachable;

                ent.components[get_component_id(Component)] = component_idx;

                try list.entity_ref_list.resize(self.alloc, list.component_list.data.items.len);
                list.entity_ref_list.items[component_idx.index] = entity;
            }
            return self.get_component(Component, entity) orelse return error.EntityDoesNotHaveComponent;
        }

        pub fn remove_component(self: *Self, comptime Component: type, entity: Entity) void {
            std.debug.assert(self.entity_data.get(entity.idx) != null);
            const ent = self.entity_data.get(entity.idx) orelse return;
            std.debug.assert(ent.components[get_component_id(Component)] != null);

            const list = self.get_component_list(Component);
            
            list.component_list.get(ent.components[get_component_id(Component)].?).?.deinit();
            list.component_list.remove(ent.components[get_component_id(Component)].?) catch |err| {
                std.log.err("Unable to remove component from ECS system: {}", .{err});
                unreachable;
            };

            list.entity_ref_list.items[ent.components[get_component_id(Component)].?.index] = null;

            ent.components[get_component_id(Component)] = null;
        }

        pub fn serialize_entity(self: *Self, alloc: std.mem.Allocator, entity: Entity) !std.json.Value {
            var object = std.json.ObjectMap.init(alloc);
            errdefer object.deinit();

            const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
            try object.put("name", try sr.serialize_value(?[]const u8, alloc, ent.name));

            inline for (info.@"struct".fields, 0..) |_, idx| {
                if (self.get_component(ComponentTypes[idx], entity)) |component| {
                    var serialized_value = try sr.serialize_value(ComponentTypes[idx], alloc, component.*);
                    try serialized_value.object.put("_ecs_COMPONENT_NAME", std.json.Value{ .string = ComponentTypes[idx].COMPONENT_NAME, });
                    try object.put(ComponentTypes[idx].COMPONENT_UUID, serialized_value);
                }
            }

            return std.json.Value { .object = object };
        }

        pub fn deserialize_to_entity(self: *Self, value: std.json.Value) !Entity {
            const alloc = eng.get().general_allocator;

            const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

            const entity = try self.create_new_entity();
            errdefer self.remove_entity(entity);

            const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
            if (object.get("name")) |v| blk: { ent.name = sr.deserialize_value(?[]const u8, alloc, v) catch break :blk; }

            inline for (info.@"struct".fields, 0..) |_, idx| {
                if (object.get(ComponentTypes[idx].COMPONENT_UUID)) |v| {
                    const component = try self.add_component(ComponentTypes[idx], entity);
                    // deinit default component to replace with the deserialized value
                    // TODO ideally we dont do this.
                    component.deinit();

                    component.* = try sr.deserialize_value(ComponentTypes[idx], alloc, v);
                }
            }

            // hack to update physics when the entity is deserialized
            // TODO: figure out a way for components to access their own entity id during deserialization?
            if (self.get_component(eng.ecs.PhysicsComponent, entity)) |physics_component| {
                try physics_component.update_runtime_data(entity);
            }

            return entity;
        }

        const EntityIterator = struct {
            ecs: *Self,
            index: usize,

            pub fn init(ecs: *Self) EntityIterator {
                return EntityIterator {
                    .ecs = ecs,
                    .index = 0,
                };
            }

            pub inline fn reset(self: *EntityIterator) void {
                self.* = EntityIterator.init(self.ecs);
            }

            pub fn next(self: *EntityIterator) ?Entity {
                while (self.index < self.ecs.entity_data.data.items.len) {
                    defer self.index += 1;
                    if (self.ecs.entity_data.data.items[self.index].item_data) |_| {
                        const entity: Entity = .{
                            .idx = .{
                                .generation = self.ecs.entity_data.data.items[self.index].generation,
                                .index = self.index,
                            }
                        };
                        return entity;
                    }
                }
                return null;
            }
        };

        pub fn QueryIterator(comptime QueryComponents: anytype) type {
            const query_info = @typeInfo(@TypeOf(QueryComponents));

            return struct {
                const QueryIteratorSelf = @This();

                ecs: *Self,
                index: usize,
                driver_entity_list: *std.ArrayList(?Entity),

                pub fn init(ecs: *Self) QueryIteratorSelf {
                    // find out which query component has the smallest count in the ecs
                    // use this component's entity reference list as the driver so we can minimize iterations
                    var shortest_component_count: usize = std.math.maxInt(usize);
                    var shortest_entity_list: *std.ArrayList(?Entity) = undefined;
                    inline for (query_info.@"struct".fields, 0..) |_, idx| {
                        const component_count = ecs.get_component_count(QueryComponents[idx]);
                        if (component_count < shortest_component_count) {
                            shortest_component_count = component_count;
                            shortest_entity_list = &ecs.get_component_list(QueryComponents[idx]).entity_ref_list;
                        }
                    }

                    return .{
                        .ecs = ecs,
                        .index = 0,
                        .driver_entity_list = shortest_entity_list,
                    };
                }

                pub inline fn reset(self: *QueryIteratorSelf) void {
                    self.* = QueryIteratorSelf.init(self.ecs);
                }

                pub fn create_generic_iterator(self: *QueryIteratorSelf) GenericQueryIterator(QueryComponents) {
                    return GenericQueryIterator(QueryComponents) {
                        .iter_ptr = @ptrCast(self),
                        .next_function_ptr = generic_next,
                        .reset_function_ptr = generic_reset,
                    };
                }

                pub fn next(self: *QueryIteratorSelf) ?ComponentValuePointersTuple(QueryComponents) {
                    while (self.index < self.driver_entity_list.items.len) {
                        defer self.index += 1;

                        const entity_ref: Entity = self.driver_entity_list.items[self.index] orelse continue;

                        const components: ?ComponentValuePointersTuple(QueryComponents) = blk: {
                            var components: ComponentValuePointersTuple(QueryComponents) = undefined;
                            inline for (query_info.@"struct".fields, 0..) |_, idx| {
                                components[idx] = self.ecs.get_component(QueryComponents[idx], entity_ref) orelse break :blk null;
                            }
                            break :blk components;
                        };
                        
                        return components orelse continue;
                    }
                    return null;
                }

                fn generic_next(self_generic: *anyopaque) ?ComponentValuePointersTuple(QueryComponents) {
                    return @as(*QueryIteratorSelf, @alignCast(@ptrCast(self_generic))).next();
                }

                fn generic_reset(self_generic: *anyopaque) void {
                    @as(*QueryIteratorSelf, @alignCast(@ptrCast(self_generic))).reset();
                }
            };
        }
    };
}

fn ComponentList(comptime T: type) type {
    return struct {
        component_list: gen.GenerationalList(T),
        entity_ref_list: std.ArrayList(?Entity),
    };
}

fn ComponentListTuple(comptime ComponentTypes: anytype) type {
    const info = @typeInfo(@TypeOf(ComponentTypes));

    var component_type_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (info.@"struct".fields, 0..) |_, idx| {
        const T = ComponentList(ComponentTypes[idx]);

        component_type_fields[idx] = std.builtin.Type.StructField {
            .name = std.fmt.comptimePrint("{d}", .{idx}),
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = true,
            .fields = &component_type_fields,
            .decls = &.{},
            .layout = .auto,
        }
    });
}

fn ComponentIndicesTuple(comptime ComponentTypes: anytype) type {
    const info = @typeInfo(@TypeOf(ComponentTypes));

    var component_type_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (info.@"struct".fields, 0..) |_, idx| {
        const T = ?gen.GenerationalIndex;

        component_type_fields[idx] = std.builtin.Type.StructField {
            .name = std.fmt.comptimePrint("{d}", .{idx}),
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = true,
            .fields = &component_type_fields,
            .decls = &.{},
            .layout = .auto,
        }
    });
}

fn ComponentValuePointersTuple(comptime ComponentTypes: anytype) type {
    const info = @typeInfo(@TypeOf(ComponentTypes));

    var component_type_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (info.@"struct".fields, 0..) |_, idx| {
        const T = *ComponentTypes[idx];

        component_type_fields[idx] = std.builtin.Type.StructField {
            .name = std.fmt.comptimePrint("{d}", .{idx}),
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = true,
            .fields = &component_type_fields,
            .decls = &.{},
            .layout = .auto,
        }
    });
}

pub fn GenericQueryIterator(comptime QueryComponents: anytype) type {
    return struct {
        const QueryIteratorSelf = @This();

        iter_ptr: *anyopaque,
        next_function_ptr: *const fn (*anyopaque) ?ComponentValuePointersTuple(QueryComponents),
        reset_function_ptr: *const fn (*anyopaque) void,

        pub fn reset(self: *const QueryIteratorSelf) void {
            self.reset_function_ptr(self.iter_ptr);
        }

        pub fn next(self: *const QueryIteratorSelf) ?ComponentValuePointersTuple(QueryComponents) {
            return self.next_function_ptr(self.iter_ptr);
        }
    };
}


const ComponentA = struct {
    i: i32,

    pub fn deinit(self: *ComponentA) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !ComponentA {
        _ = alloc;
        return ComponentA {
            .i = 0,
        };
    }
};

const ComponentB = struct {
    i: i32,

    pub fn deinit(self: *ComponentB) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !ComponentB {
        _ = alloc;
        return ComponentB {
            .i = 0,
        };
    }
};

test "abc" {
    const Ecs = EcsSystem(.{ ComponentA, ComponentB });
    var ecs = try Ecs.init(std.heap.page_allocator);
    defer ecs.deinit();

    const ent = try ecs.create_new_entity();
    defer ecs.remove_entity(ent);

    {
        const component_a = try ecs.add_component(ComponentA, ent);
        component_a.i = 1;
    }

    (try ecs.add_component(ComponentB, ent)).* = .{
        .i = 5,
    };

    // TODO maybe there is a way we can combine similar systems so we only iterate entities once?
    var entity_iter = ecs.entity_iterator();
    while (entity_iter.next()) |entity| {
        const a = ecs.get_component(ComponentA, entity) orelse continue;
        const b = ecs.get_component(ComponentB, entity) orelse continue;

        a.i = a.i + b.i;
    }

    var query_iter = ecs.query_iterator(.{ ComponentA, ComponentB });
    var generic_query_iter = query_iter.create_generic_iterator();
    while (generic_query_iter.next()) |components| {
        const a, const b = components;
        a.i = a.i + b.i;
    }

    var iter = ecs.component_iterator(ComponentA);
    while (iter.next()) |a| {
        try std.testing.expectEqual(11, a.i);
    }
}
