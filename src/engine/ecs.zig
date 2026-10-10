const std = @import("std");
const eng = @import("self");
const gen = eng.util.gen;
const sr = eng.serialize;

// -- Standard Components --

pub const SerializationComponent = @import("../ecs/serialization_component.zig");
pub const TransformComponent = @import("../ecs/transform_component.zig");
pub const ModelComponent = @import("../ecs/model_component.zig");
pub const PhysicsComponent = @import("../ecs/physics_component.zig");
pub const PhysicsRuntimeComponent = @import("../ecs/physics_runtime_component.zig");
pub const AnimationControllerComponent = @import("../ecs/animation_controller_component.zig");

pub const StandardEntityComponents = .{
    SerializationComponent,
    TransformComponent,
    ModelComponent,
    PhysicsComponent,
    PhysicsRuntimeComponent,
    AnimationControllerComponent,
};

// -- Standard Components --

pub const Entity = struct {
    idx: gen.GenerationalIndex,
};

pub const GenericEcsSystem = struct {
    pub const EntityInternal = struct {
        name: ?[]const u8 = null,
        components: std.AutoHashMap(u64, gen.GenerationalIndex),

        fn deinit(self: *EntityInternal, alloc: std.mem.Allocator) void {
            if (self.name) |name| {
                alloc.free(name);
            }
            self.components.deinit();
        }

        fn init(alloc: std.mem.Allocator) !EntityInternal {
            const components = try std.AutoHashMap(u64, void).init(alloc);
            errdefer components.deinit();

            return EntityInternal {
                .name = null,
                .components = components,
            };
        }

        fn set_name(self: *EntityInternal, alloc: std.mem.Allocator, name: ?[]const u8) !void {
            const new_name = if (name) |n| try alloc.dupe(u8, n) else null;
            errdefer if (new_name) |n| { alloc.free(n); };

            if (self.name) |old_name| {
                alloc.free(old_name);
            }

            self.name = new_name;
        }
    };

    const ComponentFunctions = struct {
        fn_component_list_deinit: *const fn (*const std.mem.Allocator, *anyopaque) callconv(.c) void,
        fn_remove_component: *const fn (*anyopaque, *const gen.GenerationalIndex) callconv(.c) void,
        fn_serialize_component: *const fn (*const std.mem.Allocator, *std.json.ObjectMap, *const Entity, *anyopaque, *const gen.GenerationalIndex) callconv(.c) bool,
        fn_deserialize_component: *const fn (*const std.mem.Allocator, *GenericEcsSystem, *const std.json.ObjectMap, *const Entity) callconv(.c) bool,
    };

    alloc: std.mem.Allocator,
    
    entity_data: gen.GenerationalList(EntityInternal),
    
    components: std.AutoHashMap(u64, *anyopaque),
    component_functions: std.AutoHashMap(u64, ComponentFunctions),

    pub fn deinit(self: *GenericEcsSystem) void {
        var components_iter = self.components.iterator();
        while (components_iter.next()) |pair| {
            const component_functions = self.component_functions.get(pair.key_ptr.*) orelse unreachable;
            component_functions.fn_component_list_deinit(&self.alloc, pair.value_ptr.*);
        }

        self.components.deinit();
        self.component_functions.deinit();

        var entity_data_iter = self.entity_data.iterator();
        while (entity_data_iter.next()) |entity_data| {
            entity_data.deinit(self.alloc);
        }
        self.entity_data.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !GenericEcsSystem {
        const components = std.AutoHashMap(u64, *anyopaque).init(alloc);
        errdefer components.deinit();

        const component_functions = std.AutoHashMap(u64, ComponentFunctions).init(alloc);
        errdefer component_functions.deinit();

        const entity_data = try gen.GenerationalList(EntityInternal).init(alloc);
        errdefer entity_data.deinit();

        return GenericEcsSystem {
            .alloc = alloc,
            .entity_data = entity_data,
            .components = components,
            .component_functions = component_functions,
        };
    }

    inline fn get_component_id(comptime T: type) u64 {
        return std.hash_map.hashString(@typeName(T));
    }

    fn get_component_list(self: *GenericEcsSystem, comptime T: type) ?*ComponentList(T) {
        const type_hash = comptime get_component_id(T);
        const component_array = self.components.get(type_hash) orelse unreachable;
        return @alignCast(@ptrCast(component_array));
    }

    pub fn register_component(self: *GenericEcsSystem, comptime T: type) !void {
        const type_hash = comptime get_component_id(T);
        std.log.info("register {s} as {}", .{@typeName(T), type_hash});
        if (self.components.get(type_hash) == null) {
            const ComponentData = struct {
                pub fn component_list_deinit(alloc: *const std.mem.Allocator, list_ptr: *anyopaque) callconv(.c) void {
                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    
                    var component_iter = component_list.component_list.iterator();
                    while (component_iter.next()) |component| {
                        component.deinit();
                    }

                    component_list.deinit(alloc.*);
                    alloc.destroy(component_list);
                }

                pub fn remove_component(list_ptr: *anyopaque, idx: *const gen.GenerationalIndex) callconv(.c) void {
                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));

                    component_list.component_list.remove(idx.*) catch unreachable;
                    component_list.entity_ref_list.items[idx.index] = null;
                }

                pub fn serialize_component(alloc: *const std.mem.Allocator, object: *std.json.ObjectMap, entity: *const Entity, list_ptr: *anyopaque, component_idx: *const gen.GenerationalIndex) callconv(.c) bool {
                    std.debug.assert(T.COMPONENT_UUID.len != 0);

                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    const component = component_list.component_list.get(component_idx.*).?;

                    var component_object_map = std.json.ObjectMap.init(alloc.*);
                    errdefer component_object_map.deinit();

                    component_object_map.put("_ecs_COMPONENT_NAME", std.json.Value{ .string = T.COMPONENT_NAME, }) catch return false;
                    component.serialize(alloc.*, entity.*, &component_object_map) catch return false;

                    const serialized_value = std.json.Value { .object = component_object_map };
                    object.put(T.COMPONENT_UUID, serialized_value) catch return false;
                    
                    return true;
                }

                pub fn deserialize_component(alloc: *const std.mem.Allocator, ecs: *GenericEcsSystem, object: *const std.json.ObjectMap, entity: *const Entity) callconv(.c) bool {
                    if (object.get(T.COMPONENT_UUID)) |v| {
                        const component = ecs.add_component(T, entity.*) catch return false;
                        // deinit default component to replace with the deserialized value
                        // TODO ideally we dont do this.
                        component.deinit();

                        const component_object_map = switch (v) { .object => |obj| obj, else => return false, };
                        component.* = T.deserialize(alloc.*, entity.*, component_object_map) catch return false;

                        return true;
                    } else {
                        return false;
                    }
                }
            };

            const component_list = try self.alloc.create(ComponentList(T));
            errdefer self.alloc.destroy(component_list);

            component_list.* = try ComponentList(T).init(self.alloc);
            errdefer component_list.deinit(self.alloc);

            try self.components.put(type_hash, component_list);
            errdefer _ = self.components.remove(type_hash);

            try self.component_functions.put(type_hash, ComponentFunctions {
                .fn_component_list_deinit = ComponentData.component_list_deinit,
                .fn_remove_component = ComponentData.remove_component,
                .fn_serialize_component = ComponentData.serialize_component,
                .fn_deserialize_component = ComponentData.deserialize_component,
            });
            errdefer self.component_functions.remove(type_hash);
        } else {
            std.log.err("Attempted to add component array that already exists", .{});
            unreachable;
        }
    }

    pub fn create_new_entity(self: *GenericEcsSystem) !Entity {
        var components = std.AutoHashMap(u64, gen.GenerationalIndex).init(self.alloc);
        errdefer components.deinit();

        return Entity {
            .idx = try self.entity_data.insert(.{
                .components = components,
            }),
        };
    }
    
    pub fn remove_entity(self: *GenericEcsSystem, entity: Entity) void {
        const ent = self.entity_data.get(entity.idx) orelse return;

        // deinit entity name by setting it to null
        self.set_entity_name(entity, null) catch {};

        // remove all entity components
        var component_iter = ent.components.iterator();
        while (component_iter.next()) |pair| {
            const component_functions = self.component_functions.get(pair.key_ptr.*).?;
            const component_list = self.components.get(pair.key_ptr.*).?;
            component_functions.fn_remove_component(component_list, pair.value_ptr);
        }
        ent.components.deinit();
        
        self.entity_data.remove(entity.idx) catch unreachable;
    }

    pub fn set_entity_name(self: *GenericEcsSystem, entity: Entity, name: ?[]const u8) !void {
        const entity_data = self.entity_data.get(entity.idx) orelse unreachable;
        try entity_data.set_name(self.alloc, name);
    }

    pub fn get_entity_name(self: *const GenericEcsSystem, entity: Entity) ?[]const u8 {
        const entity_data = self.entity_data.get(entity.idx) orelse unreachable;
        return entity_data.name;
    }

    pub fn find_first_entity_with_name(self: *GenericEcsSystem, search_name: []const u8) ?Entity {
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

    pub fn get_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) ?*Component {
        const type_hash = comptime get_component_id(Component);
        const component_list = self.get_component_list(Component) orelse unreachable;
        const entity_data = self.entity_data.get(entity.idx) orelse unreachable;
        const component_id = entity_data.components.get(type_hash) orelse return null;
        return component_list.component_list.get(component_id);
    }

    pub fn add_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) !*Component {
        const type_hash = comptime get_component_id(Component);
        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        if (ent.components.get(type_hash) == null) {
            const list = self.get_component_list(Component).?;

            var new_component = try Component.init(self.alloc);
            errdefer new_component.deinit();

            const component_idx = try list.component_list.insert(new_component);
            errdefer list.component_list.remove(component_idx) catch unreachable;

            try ent.components.put(type_hash, component_idx);
            errdefer _ = ent.components.remove(type_hash);

            try list.entity_ref_list.resize(self.alloc, list.component_list.data.items.len);
            list.entity_ref_list.items[component_idx.index] = entity;
        }
        return self.get_component(Component, entity) orelse return error.EntityDoesNotHaveComponent;
    }

    pub fn remove_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) void {
        const type_hash = comptime get_component_id(Component);
        std.debug.assert(self.entity_data.get(entity.idx) != null);
        const ent = self.entity_data.get(entity.idx) orelse return;
        std.debug.assert(ent.components.get(type_hash) != null);

        const list = self.get_component_list(Component).?;
        
        list.component_list.get(ent.components.get(type_hash).?).?.deinit();
        list.component_list.remove(ent.components.get(type_hash).?) catch |err| {
            std.log.err("Unable to remove component from ECS system: {}", .{err});
            unreachable;
        };

        list.entity_ref_list.items[ent.components.get(type_hash).?.index] = null;

        ent.components.remove(type_hash);
    }

    pub fn serialize_entity(self: *GenericEcsSystem, alloc: std.mem.Allocator, entity: Entity) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        try object.put("name", try sr.serialize_value(?[]const u8, alloc, ent.name));

        var component_iter = ent.components.iterator();
        while (component_iter.next()) |pair| {
            const component_functions = self.component_functions.get(pair.key_ptr.*).?;
            const component_list = self.components.get(pair.key_ptr.*).?;
            _ = component_functions.fn_serialize_component(&alloc, &object, &entity, component_list, pair.value_ptr);
        }

        return std.json.Value { .object = object };
    }

    pub fn deserialize_to_entity(self: *GenericEcsSystem, value: std.json.Value) !Entity {
        const alloc = eng.get().general_allocator;

        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        const entity = try self.create_new_entity();
        errdefer self.remove_entity(entity);

        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        if (object.get("name")) |v| blk: { ent.name = sr.deserialize_value(?[]const u8, alloc, v) catch break :blk; }

        var component_iter = self.components.keyIterator();
        while (component_iter.next()) |type_hash| {
            const component_functions = self.component_functions.get(type_hash.*).?;
            _ = component_functions.fn_deserialize_component(&alloc, self, &object, &entity);
        }

        return entity;
    }

    pub fn get_component_count(self: *const GenericEcsSystem, comptime T: type) usize {
        const type_hash = comptime get_component_id(T);
        const list_ptr = self.components.get(type_hash).?;
        const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
        return component_list.component_list.item_count();
    }

    pub fn entity_iterator(self: *GenericEcsSystem) EntityIterator {
        return EntityIterator.init(self);
    }

    pub const EntityIterator = struct {
        ecs: *GenericEcsSystem,
        index: usize,

        pub fn init(ecs: *GenericEcsSystem) EntityIterator {
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

    pub fn query_iterator(self: *GenericEcsSystem, comptime QueryComponents: anytype) QueryIterator(QueryComponents) {
        return QueryIterator(QueryComponents).init(self);
    }

    pub fn QueryIterator(comptime QueryComponents: anytype) type {
        const query_info = @typeInfo(@TypeOf(QueryComponents));

        return struct {
            const QueryIteratorSelf = @This();

            ecs: *GenericEcsSystem,
            index: usize,
            driver_entity_list: *std.ArrayList(?Entity),

            pub fn init(ecs: *GenericEcsSystem) QueryIteratorSelf {
                // find out which query component has the smallest count in the ecs
                // use this component's entity reference list as the driver so we can minimize iterations
                var shortest_component_count: usize = std.math.maxInt(usize);
                var shortest_entity_list: *std.ArrayList(?Entity) = undefined;
                inline for (query_info.@"struct".fields, 0..) |_, idx| {
                    const component_count = ecs.get_component_count(QueryComponents[idx]);
                    if (component_count < shortest_component_count) {
                        shortest_component_count = component_count;
                        shortest_entity_list = &ecs.get_component_list(QueryComponents[idx]).?.entity_ref_list;
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

fn ComponentList(comptime T: type) type {
    return struct {
        component_list: gen.GenerationalList(T),
        entity_ref_list: std.ArrayList(?Entity),

        fn deinit(self: *ComponentList(T), alloc: std.mem.Allocator) void {
            self.component_list.deinit();
            self.entity_ref_list.deinit(alloc);
        }

        fn init(alloc: std.mem.Allocator) !ComponentList(T) {
            const component_list = try gen.GenerationalList(T).init(alloc);
            errdefer component_list.deinit();

            return ComponentList(T) {
                .component_list = component_list,
                .entity_ref_list = .empty,
            };
        }
    };
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
    var ecs = try GenericEcsSystem.init(std.heap.page_allocator);
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
