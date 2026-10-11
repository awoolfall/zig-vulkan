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

    fn ComponentList(comptime T: type) type { return gen.GenerationalList(T); }

    const ComponentInfo = struct {
        name: []const u8, // not owned
        component_list: *anyopaque,
        component_functions: ComponentFunctions,
        entity_ref_list: std.ArrayList(?Entity),

        fn deinit(self: *ComponentInfo, alloc: std.mem.Allocator) void {
            self.component_functions.fn_component_list_deinit(&alloc, self.component_list);
            self.entity_ref_list.deinit(alloc);
        }

        fn get_component_list(self: *ComponentInfo, comptime ComponentType: type) *ComponentList(ComponentType) {
            std.debug.assert(std.mem.eql(u8, ComponentType.COMPONENT_NAME, self.name));
            const component_list: *ComponentList(ComponentType) = @alignCast(@ptrCast(self.component_list));
            return component_list;
        }
    };

    const ComponentFunctions = struct {
        fn_component_list_deinit: *const fn (*const std.mem.Allocator, *anyopaque) void,
        fn_add_component: *const fn (*const std.mem.Allocator, *anyopaque, *gen.GenerationalIndex) void,
        fn_remove_component: *const fn (*anyopaque, *const gen.GenerationalIndex) void,
        fn_component_list_size: *const fn (*anyopaque) usize,
        fn_serialize_component: *const fn (*const std.mem.Allocator, *std.json.ObjectMap, *const Entity, *anyopaque, *const gen.GenerationalIndex) bool,
        fn_deserialize_component: *const fn (*const std.mem.Allocator, *GenericEcsSystem, *const std.json.ObjectMap, *const Entity) bool,
        fn_component_editor_ui: *const fn (*eng.ui, *const Entity, *anyopaque, *const gen.GenerationalIndex, usize) void,
    };

    alloc: std.mem.Allocator,
    entity_data: gen.GenerationalList(EntityInternal),
    components: std.AutoHashMap(u64, ComponentInfo),

    pub fn deinit(self: *GenericEcsSystem) void {
        var components_iter = self.components.iterator();
        while (components_iter.next()) |pair| {
            pair.value_ptr.deinit(self.alloc);
        }
        self.components.deinit();

        var entity_data_iter = self.entity_data.iterator();
        while (entity_data_iter.next()) |entity_data| {
            entity_data.deinit(self.alloc);
        }
        self.entity_data.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !GenericEcsSystem {
        const components = std.AutoHashMap(u64, ComponentInfo).init(alloc);
        errdefer components.deinit();

        const entity_data = try gen.GenerationalList(EntityInternal).init(alloc);
        errdefer entity_data.deinit();

        return GenericEcsSystem {
            .alloc = alloc,
            .entity_data = entity_data,
            .components = components,
        };
    }

    pub inline fn get_component_id(comptime T: type) u64 {
        return std.hash_map.hashString(@typeName(T));
    }

    fn get_component_list(self: *const GenericEcsSystem, comptime T: type) ?*ComponentList(T) {
        const component = self.get_component_info(T) orelse return null;
        return component.get_component_list(T);
    }

    fn get_component_info(self: *const GenericEcsSystem, comptime T: type) ?*ComponentInfo {
        const type_hash = comptime get_component_id(T);
        return self.components.getPtr(type_hash);
    }

    pub fn register_component(self: *GenericEcsSystem, comptime T: type) !void {
        const type_hash = comptime get_component_id(T);
        std.log.info("register {s} as {}", .{@typeName(T), type_hash});
        if (self.components.get(type_hash) == null) {
            const ComponentData = struct {
                pub fn component_list_deinit(alloc: *const std.mem.Allocator, list_ptr: *anyopaque) void {
                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    
                    var component_iter = component_list.iterator();
                    while (component_iter.next()) |component| {
                        component.deinit();
                    }

                    component_list.deinit();
                    alloc.destroy(component_list);
                }

                pub fn remove_component(list_ptr: *anyopaque, idx: *const gen.GenerationalIndex) void {
                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    component_list.get(idx.*).?.deinit();
                    component_list.remove(idx.*) catch unreachable;
                }

                pub fn add_component(alloc: *const std.mem.Allocator, list_ptr: *anyopaque, idx_out: *gen.GenerationalIndex) void {
                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    const component = T.init(alloc.*) catch unreachable;
                    idx_out.* = component_list.insert(component) catch unreachable;
                }

                pub fn component_list_size(list_ptr: *anyopaque) usize {
                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    return component_list.data.items.len;
                }

                pub fn serialize_component(alloc: *const std.mem.Allocator, object: *std.json.ObjectMap, entity: *const Entity, list_ptr: *anyopaque, component_idx: *const gen.GenerationalIndex) bool {
                    std.debug.assert(T.COMPONENT_UUID.len != 0);

                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    const component = component_list.get(component_idx.*).?;

                    var component_object_map = std.json.ObjectMap.init(alloc.*);
                    errdefer component_object_map.deinit();

                    component_object_map.put("_ecs_COMPONENT_NAME", std.json.Value{ .string = T.COMPONENT_NAME, }) catch return false;
                    component.serialize(alloc.*, entity.*, &component_object_map) catch return false;

                    const serialized_value = std.json.Value { .object = component_object_map };
                    object.put(T.COMPONENT_UUID, serialized_value) catch return false;
                    
                    return true;
                }

                pub fn deserialize_component(alloc: *const std.mem.Allocator, ecs: *GenericEcsSystem, object: *const std.json.ObjectMap, entity: *const Entity) bool {
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

                pub fn component_editor_ui(imui: *eng.ui, entity: *const Entity, list_ptr: *anyopaque, component_idx: *const gen.GenerationalIndex, key: u64) void {
                    const component_list: *ComponentList(T) = @alignCast(@ptrCast(list_ptr));
                    const component = component_list.get(component_idx.*).?;
                    T.editor_ui(imui, entity.*, component, .{key}) catch unreachable;
                }
            };

            const component_list = try self.alloc.create(ComponentList(T));
            errdefer self.alloc.destroy(component_list);

            component_list.* = try ComponentList(T).init(self.alloc);
            errdefer component_list.deinit();

            const component_info = ComponentInfo {
                .name = T.COMPONENT_NAME,
                .component_list = component_list,
                .component_functions = ComponentFunctions {
                    .fn_component_list_deinit = ComponentData.component_list_deinit,
                    .fn_remove_component = ComponentData.remove_component,
                    .fn_add_component = ComponentData.add_component,
                    .fn_component_list_size = ComponentData.component_list_size,
                    .fn_serialize_component = ComponentData.serialize_component,
                    .fn_deserialize_component = ComponentData.deserialize_component,
                    .fn_component_editor_ui = ComponentData.component_editor_ui,
                },
                .entity_ref_list = .empty,
            };

            try self.components.put(type_hash, component_info);
            errdefer _ = self.components.remove(type_hash);
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
            const component_info = self.components.get(pair.key_ptr.*).?;
            const component_functions = &component_info.component_functions;

            component_functions.fn_remove_component(component_info.component_list, pair.value_ptr);
            component_info.entity_ref_list.items[pair.value_ptr.index] = null;
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

    pub fn entity_has_component_generic(self: *GenericEcsSystem, component_type_hash: u64, entity: Entity) bool {
        const entity_data = self.entity_data.get(entity.idx).?;
        return entity_data.components.contains(component_type_hash);
    }

    pub fn get_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) ?*Component {
        const type_hash = comptime get_component_id(Component);
        const component_list = self.get_component_list(Component) orelse unreachable;
        const entity_data = self.entity_data.get(entity.idx) orelse unreachable;
        const component_id = entity_data.components.get(type_hash) orelse return null;
        return component_list.get(component_id);
    }

    pub fn add_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) !*Component {
        const type_hash = comptime get_component_id(Component);
        try self.add_component_generic(type_hash, entity);
        return self.get_component(Component, entity) orelse return error.EntityDoesNotHaveComponent;
    }

    pub fn add_component_generic(self: *GenericEcsSystem, component_type_hash: u64, entity: Entity) !void {
        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        if (ent.components.get(component_type_hash) == null) {
            const info = self.components.getPtr(component_type_hash).?;

            var component_idx: gen.GenerationalIndex = undefined;
            info.component_functions.fn_add_component(&self.alloc, info.component_list, &component_idx);

            try ent.components.put(component_type_hash, component_idx);
            errdefer _ = ent.components.remove(component_type_hash);

            const component_list_size = info.component_functions.fn_component_list_size(info.component_list);

            try info.entity_ref_list.resize(self.alloc, component_list_size);
            info.entity_ref_list.items[component_idx.index] = entity;
        }
    }

    pub fn remove_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) void {
        const type_hash = comptime get_component_id(Component);
        self.remove_component_generic(type_hash, entity);
    }

    pub fn remove_component_generic(self: *GenericEcsSystem, component_type_hash: u64, entity: Entity) void {
        std.debug.assert(self.entity_data.get(entity.idx) != null);
        const ent = self.entity_data.get(entity.idx) orelse return;
        std.debug.assert(ent.components.get(component_type_hash) != null);

        const component_info = self.components.getPtr(component_type_hash).?;

        component_info.component_functions.fn_remove_component(component_info.component_list, &ent.components.get(component_type_hash).?);
        component_info.entity_ref_list.items[ent.components.get(component_type_hash).?.index] = null;

        _ = ent.components.remove(component_type_hash);
    }

    pub fn serialize_entity(self: *GenericEcsSystem, alloc: std.mem.Allocator, entity: Entity) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        try object.put("name", try sr.serialize_value(?[]const u8, alloc, ent.name));

        var component_iter = ent.components.iterator();
        while (component_iter.next()) |pair| {
            const component_info = self.components.getPtr(pair.key_ptr.*).?;
            _ = component_info.component_functions.fn_serialize_component(&alloc, &object, &entity, component_info.component_list, pair.value_ptr);
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

        var component_iter = self.components.iterator();
        while (component_iter.next()) |pair| {
            const component_functions = &pair.value_ptr.component_functions;
            _ = component_functions.fn_deserialize_component(&alloc, self, &object, &entity);
        }

        return entity;
    }

    pub fn get_component_count(self: *const GenericEcsSystem, comptime T: type) usize {
        const component_list = self.get_component_list(T).?;
        return component_list.item_count();
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
                        shortest_entity_list = &ecs.get_component_info(QueryComponents[idx]).?.entity_ref_list;
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
