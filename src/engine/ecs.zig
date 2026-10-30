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

            return EntityInternal{
                .name = null,
                .components = components,
            };
        }

        fn set_name(self: *EntityInternal, alloc: std.mem.Allocator, name: ?[]const u8) !void {
            const new_name = if (name) |n| try alloc.dupe(u8, n) else null;
            errdefer if (new_name) |n| alloc.free(n);

            if (self.name) |old_name| {
                alloc.free(old_name);
            }

            self.name = new_name;
        }
    };

    fn ComponentList(comptime T: type) type {
        return gen.GenerationalList(T);
    }

    const ComponentInfo = struct {
        const Functions = struct {
            fn_component_list_deinit: *const fn (*const std.mem.Allocator, *anyopaque) void,
            fn_add_component: *const fn (*const std.mem.Allocator, *anyopaque, *gen.GenerationalIndex) void,
            fn_remove_component: *const fn (*anyopaque, *const gen.GenerationalIndex) void,
            fn_component_list_size: *const fn (*anyopaque) usize,
            fn_serialize_component: *const fn (*const std.mem.Allocator, *std.json.ObjectMap, *const Entity, *anyopaque, *const gen.GenerationalIndex) bool,
            fn_deserialize_component: *const fn (*const std.mem.Allocator, *GenericEcsSystem, *const std.json.ObjectMap, *const Entity) bool,
            fn_component_editor_ui: *const fn (*eng.Imui, *const Entity, *anyopaque, *const gen.GenerationalIndex, usize) void,
        };

        name: []const u8, // not owned
        uuid: []const u8, // not owned
        component_list: *anyopaque,
        entity_ref_list: std.ArrayList(?Entity),
        functions: Functions,

        fn deinit(self: *ComponentInfo, alloc: std.mem.Allocator) void {
            self.functions.fn_component_list_deinit(&alloc, self.component_list);
            self.entity_ref_list.deinit(alloc);
        }

        fn get_component_list(self: *ComponentInfo, comptime ComponentType: type) *ComponentList(ComponentType) {
            std.debug.assert(std.mem.eql(u8, ComponentType.COMPONENT_NAME, self.name));
            const component_list: *ComponentList(ComponentType) = @ptrCast(@alignCast(self.component_list));
            return component_list;
        }
    };

    const ResourceInfo = struct {
        const Functions = struct {
            fn_deinit: *const fn (*const std.mem.Allocator, *anyopaque) void,
            fn_init: *const fn (*const std.mem.Allocator, *?*anyopaque) i32,
            fn_serialize: *const fn (*const std.mem.Allocator, *std.json.ObjectMap, *anyopaque) bool,
            fn_deserialize: *const fn (*GenericEcsSystem, *const std.json.ObjectMap) bool,
        };

        name: []const u8, // not owned
        uuid: []const u8, // not owned
        data: ?*anyopaque,
        functions: Functions,
    };

    alloc: std.mem.Allocator,

    entity_data: gen.GenerationalList(EntityInternal),
    components: std.AutoHashMap(u64, ComponentInfo),
    resources: std.AutoHashMap(u64, ResourceInfo),

    pub fn deinit(self: *GenericEcsSystem) void {
        self.clear(.{});

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

        var resource_iter = self.resources.keyIterator();
        while (resource_iter.next()) |type_id| {
            self.destroy_resource_generic(type_id.*);
        }
        self.resources.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !GenericEcsSystem {
        const components = std.AutoHashMap(u64, ComponentInfo).init(alloc);
        errdefer components.deinit();

        const entity_data = try gen.GenerationalList(EntityInternal).init(alloc);
        errdefer entity_data.deinit();

        const resources = std.AutoHashMap(u64, ResourceInfo).init(alloc);
        errdefer resources.deinit();

        return GenericEcsSystem{
            .alloc = alloc,
            .entity_data = entity_data,
            .components = components,
            .resources = resources,
        };
    }

    pub fn clear_entities(self: *GenericEcsSystem) void {
        var entity_iter = self.entity_iterator();
        while (entity_iter.next()) |entity| {
            self.remove_entity(entity);
        }
    }

    pub fn clear_resources(self: *GenericEcsSystem, ignore_resources: anytype) void {
        var resource_iter = self.resources.keyIterator();
        resources_while: while (resource_iter.next()) |type_id| {
            inline for (ignore_resources) |T| {
                if (type_id.* == comptime get_type_id(T)) continue :resources_while;
            }
            self.destroy_resource_generic(type_id.*);
        }
    }

    pub fn clear(self: *GenericEcsSystem, ignore_resources: anytype) void {
        self.clear_entities();
        self.clear_resources(ignore_resources);
    }

    pub inline fn get_type_id(comptime T: type) u64 {
        return std.hash_map.hashString(@typeName(T));
    }

    fn get_component_list(self: *const GenericEcsSystem, comptime T: type) ?*ComponentList(T) {
        const component = self.get_component_info(T) orelse return null;
        return component.get_component_list(T);
    }

    fn get_component_info(self: *const GenericEcsSystem, comptime T: type) ?*ComponentInfo {
        const type_id = comptime get_type_id(T);
        return self.components.getPtr(type_id);
    }

    fn generate_component_functions(comptime ComponentType: type) ComponentInfo.Functions {
        const Functions = struct {
            fn component_list_deinit(alloc: *const std.mem.Allocator, list_ptr: *anyopaque) void {
                const component_list: *ComponentList(ComponentType) = @ptrCast(@alignCast(list_ptr));

                var component_iter = component_list.iterator();
                while (component_iter.next()) |component| {
                    component.deinit();
                }

                component_list.deinit();
                alloc.destroy(component_list);
            }

            fn remove_component(list_ptr: *anyopaque, idx: *const gen.GenerationalIndex) void {
                const component_list: *ComponentList(ComponentType) = @ptrCast(@alignCast(list_ptr));
                component_list.get(idx.*).?.deinit();
                component_list.remove(idx.*) catch unreachable;
            }

            fn add_component(alloc: *const std.mem.Allocator, list_ptr: *anyopaque, idx_out: *gen.GenerationalIndex) void {
                const component_list: *ComponentList(ComponentType) = @ptrCast(@alignCast(list_ptr));
                const component = ComponentType.init(alloc.*) catch unreachable;
                idx_out.* = component_list.insert(component) catch unreachable;
            }

            fn component_list_size(list_ptr: *anyopaque) usize {
                const component_list: *ComponentList(ComponentType) = @ptrCast(@alignCast(list_ptr));
                return component_list.data.items.len;
            }

            fn serialize_component(alloc: *const std.mem.Allocator, object: *std.json.ObjectMap, entity: *const Entity, list_ptr: *anyopaque, component_idx: *const gen.GenerationalIndex) bool {
                // don't serialize components without a UUID
                if (ComponentType.COMPONENT_UUID.len == 0) {
                    return true;
                }

                const component_list: *ComponentList(ComponentType) = @ptrCast(@alignCast(list_ptr));
                const component = component_list.get(component_idx.*).?;

                var component_object_map = std.json.ObjectMap.init(alloc.*);
                errdefer component_object_map.deinit();

                component_object_map.put("COMPONENT_NAME", std.json.Value{ .string = ComponentType.COMPONENT_NAME }) catch return false;
                component.serialize(alloc.*, entity.*, &component_object_map) catch return false;

                const serialized_value = std.json.Value{ .object = component_object_map };
                object.put(ComponentType.COMPONENT_UUID, serialized_value) catch return false;

                return true;
            }

            fn deserialize_component(alloc: *const std.mem.Allocator, ecs: *GenericEcsSystem, object: *const std.json.ObjectMap, entity: *const Entity) bool {
                if (object.get(ComponentType.COMPONENT_UUID)) |v| {
                    const component = ecs.add_component(ComponentType, entity.*) catch return false;
                    // deinit default component to replace with the deserialized value
                    // TODO ideally we dont do this.
                    component.deinit();

                    const component_object_map = switch (v) {
                        .object => |obj| obj,
                        else => return false,
                    };
                    component.* = ComponentType.deserialize(alloc.*, entity.*, component_object_map) catch return false;

                    return true;
                } else {
                    return false;
                }
            }

            fn component_editor_ui(imui: *eng.Imui, entity: *const Entity, list_ptr: *anyopaque, component_idx: *const gen.GenerationalIndex, key: u64) void {
                const component_list: *ComponentList(ComponentType) = @ptrCast(@alignCast(list_ptr));
                const component = component_list.get(component_idx.*).?;
                ComponentType.editor_ui(imui, entity.*, component, .{key}) catch unreachable;
            }
        };

        return ComponentInfo.Functions{
            .fn_component_list_deinit = Functions.component_list_deinit,
            .fn_remove_component = Functions.remove_component,
            .fn_add_component = Functions.add_component,
            .fn_component_list_size = Functions.component_list_size,
            .fn_serialize_component = Functions.serialize_component,
            .fn_deserialize_component = Functions.deserialize_component,
            .fn_component_editor_ui = Functions.component_editor_ui,
        };
    }

    pub fn register_component(self: *GenericEcsSystem, comptime T: type) !void {
        const type_id = comptime get_type_id(T);
        std.log.info("register component {s} as {}", .{ @typeName(T), type_id });

        if (self.components.get(type_id) == null) {
            const component_list = try self.alloc.create(ComponentList(T));
            errdefer self.alloc.destroy(component_list);

            component_list.* = try ComponentList(T).init(self.alloc);
            errdefer component_list.deinit();

            const component_info = ComponentInfo{
                .name = T.COMPONENT_NAME,
                .uuid = T.COMPONENT_UUID,
                .component_list = component_list,
                .functions = generate_component_functions(T),
                .entity_ref_list = .empty,
            };

            try self.components.put(type_id, component_info);
            errdefer _ = self.components.remove(type_id);
        } else {
            std.log.err("Attempted to register component that already exists", .{});
            unreachable;
        }
    }

    fn generate_resource_functions(comptime ResourceType: type) ResourceInfo.Functions {
        const Functions = struct {
            fn init(alloc: *const std.mem.Allocator, out_ptr: *?*anyopaque) i32 {
                const ptr = alloc.create(ResourceType) catch return -1;
                ptr.* = ResourceType.init() catch return -2;
                out_ptr.* = ptr;
                return 0;
            }

            fn deinit(alloc: *const std.mem.Allocator, opaque_ptr: *anyopaque) void {
                const ptr: *ResourceType = @ptrCast(@alignCast(opaque_ptr));
                ptr.deinit();
                alloc.destroy(ptr);
            }

            fn serialize(alloc: *const std.mem.Allocator, map: *std.json.ObjectMap, opaque_ptr: *anyopaque) bool {
                const resource: *ResourceType = @ptrCast(@alignCast(opaque_ptr));
                if (@hasDecl(ResourceType, "serialize")) {
                    resource.serialize(alloc.*, map) catch |err| {
                        std.log.err("Failed to serialize resource {s}: {}", .{ @typeName(ResourceType), err });
                        return false;
                    };
                }
                return true;
            }

            fn deserialize(ecs: *GenericEcsSystem, map: *const std.json.ObjectMap) bool {
                if (!ecs.resource_exists(ResourceType)) {
                    ecs.create_resource(ResourceType) catch return false;
                }
                const resource = ecs.get_resource(ResourceType) orelse return false;
                if (@hasDecl(ResourceType, "deserialize")) {
                    resource.deserialize(map) catch |err| {
                        std.log.err("Failed to deserialize resource {s}: {}", .{ @typeName(ResourceType), err });
                        return false;
                    };
                }
                return true;
            }
        };

        return ResourceInfo.Functions{
            .fn_init = Functions.init,
            .fn_deinit = Functions.deinit,
            .fn_serialize = Functions.serialize,
            .fn_deserialize = Functions.deserialize,
        };
    }

    pub fn register_resource(self: *GenericEcsSystem, comptime ResourceType: type) !void {
        const type_id = comptime get_type_id(ResourceType);
        std.log.info("register resource {s} as {}", .{ @typeName(ResourceType), type_id });

        if (self.resources.get(type_id) == null) {
            const resource_info = ResourceInfo{
                .name = ResourceType.RESOURCE_NAME,
                .uuid = ResourceType.RESOURCE_UUID,
                .data = null,
                .functions = generate_resource_functions(ResourceType),
            };

            try self.resources.put(type_id, resource_info);
            errdefer _ = self.resources.remove(type_id);
        } else {
            std.log.err("Attempted to register resource that already exists", .{});
            unreachable;
        }
    }

    pub fn create_resource(self: *GenericEcsSystem, comptime ResourceType: type) !void {
        const type_id = comptime get_type_id(ResourceType);
        try self.create_resource_generic(type_id);
    }

    pub fn create_resource_generic(self: *GenericEcsSystem, type_id: u64) !void {
        const resource_info = self.resources.getPtr(type_id) orelse return error.ResourceNotRegistered;

        if (resource_info.data != null) {
            std.log.warn("create resource called on resource that already exists: {s}", .{resource_info.name});
            return;
        }

        const result = resource_info.functions.fn_init(&self.alloc, &resource_info.data);
        switch (result) {
            -1 => return error.AllocatorError,
            -2 => return error.ResourceInitFailed,
            else => {},
        }
    }

    pub fn destroy_resource(self: *GenericEcsSystem, comptime ResourceType: type) void {
        const type_id = comptime get_type_id(ResourceType);
        self.destroy_resource_generic(type_id);
    }

    pub fn destroy_resource_generic(self: *GenericEcsSystem, type_id: u64) void {
        const resource_info = self.resources.getPtr(type_id) orelse return;

        if (resource_info.data) |data_opaque_ptr| {
            resource_info.functions.fn_deinit(&self.alloc, data_opaque_ptr);
            resource_info.data = null;
        }
    }

    pub fn get_resource(self: *GenericEcsSystem, comptime ResourceType: type) ?*ResourceType {
        const type_id = comptime get_type_id(ResourceType);
        const resource_info = self.resources.getPtr(type_id) orelse {
            std.log.err("Attempted to get resource which has not been registered: {s}", .{@typeName(ResourceType)});
            return null;
        };
        if (resource_info.data) |data_opaque_ptr| return @ptrCast(@alignCast(data_opaque_ptr)) else return null;
    }

    pub fn resource_exists(self: *const GenericEcsSystem, comptime ResourceType: type) bool {
        const type_id = comptime get_type_id(ResourceType);
        const resource_info = self.resources.getPtr(type_id) orelse return false;
        return resource_info.data != null;
    }

    pub fn create_new_entity(self: *GenericEcsSystem) !Entity {
        var components = std.AutoHashMap(u64, gen.GenerationalIndex).init(self.alloc);
        errdefer components.deinit();

        return Entity{
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
            const functions = &component_info.functions;

            functions.fn_remove_component(component_info.component_list, pair.value_ptr);
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

    pub fn entity_has_component(self: *const GenericEcsSystem, comptime ComponentType: type, entity: Entity) bool {
        const type_id = comptime get_type_id(ComponentType);
        return self.entity_has_component_generic(type_id, entity);
    }

    pub fn entity_has_component_generic(self: *const GenericEcsSystem, component_type_id: u64, entity: Entity) bool {
        const entity_data = self.entity_data.get(entity.idx).?;
        return entity_data.components.contains(component_type_id);
    }

    pub fn get_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) ?*Component {
        const type_id = comptime get_type_id(Component);
        const component_list = self.get_component_list(Component) orelse unreachable;
        const entity_data = self.entity_data.get(entity.idx) orelse unreachable;
        const component_id = entity_data.components.get(type_id) orelse return null;
        return component_list.get(component_id);
    }

    pub fn add_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) !*Component {
        const type_id = comptime get_type_id(Component);
        try self.add_component_generic(type_id, entity);
        return self.get_component(Component, entity) orelse return error.EntityDoesNotHaveComponent;
    }

    pub fn add_component_generic(self: *GenericEcsSystem, component_type_id: u64, entity: Entity) !void {
        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        if (ent.components.get(component_type_id) == null) {
            const info = self.components.getPtr(component_type_id).?;

            var component_idx: gen.GenerationalIndex = undefined;
            info.functions.fn_add_component(&self.alloc, info.component_list, &component_idx);

            try ent.components.put(component_type_id, component_idx);
            errdefer _ = ent.components.remove(component_type_id);

            const component_list_size = info.functions.fn_component_list_size(info.component_list);

            try info.entity_ref_list.resize(self.alloc, component_list_size);
            info.entity_ref_list.items[component_idx.index] = entity;
        }
    }

    pub fn remove_component(self: *GenericEcsSystem, comptime Component: type, entity: Entity) void {
        const type_id = comptime get_type_id(Component);
        self.remove_component_generic(type_id, entity);
    }

    pub fn remove_component_generic(self: *GenericEcsSystem, component_type_id: u64, entity: Entity) void {
        std.debug.assert(self.entity_data.get(entity.idx) != null);
        const ent = self.entity_data.get(entity.idx) orelse return;
        std.debug.assert(ent.components.get(component_type_id) != null);

        const component_info = self.components.getPtr(component_type_id).?;

        component_info.functions.fn_remove_component(component_info.component_list, &ent.components.get(component_type_id).?);
        component_info.entity_ref_list.items[ent.components.get(component_type_id).?.index] = null;

        _ = ent.components.remove(component_type_id);
    }

    pub fn serialize_entity(self: *GenericEcsSystem, alloc: std.mem.Allocator, entity: Entity) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        try object.put("name", try sr.serialize_value(?[]const u8, alloc, ent.name));

        var component_iter = ent.components.iterator();
        while (component_iter.next()) |pair| {
            const component_info = self.components.getPtr(pair.key_ptr.*).?;
            _ = component_info.functions.fn_serialize_component(&alloc, &object, &entity, component_info.component_list, pair.value_ptr);
        }

        return std.json.Value{ .object = object };
    }

    pub fn deserialize_to_entity(self: *GenericEcsSystem, value: std.json.Value) !Entity {
        const alloc = eng.get().general_allocator;

        const object = switch (value) {
            .object => |obj| obj,
            else => return error.InvalidType,
        };

        const entity = try self.create_new_entity();
        errdefer self.remove_entity(entity);

        const ent = self.entity_data.get(entity.idx) orelse return error.EntityDoesNotExist;
        if (object.get("name")) |v| blk: {
            ent.name = sr.deserialize_value(?[]const u8, alloc, v) catch break :blk;
        }

        var component_iter = self.components.iterator();
        while (component_iter.next()) |pair| {
            const functions = &pair.value_ptr.functions;
            _ = functions.fn_deserialize_component(&alloc, self, &object, &entity);
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
            return EntityIterator{
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
                    const entity: Entity = .{ .idx = .{
                        .generation = self.ecs.entity_data.data.items[self.index].generation,
                        .index = self.index,
                    } };
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
                return GenericQueryIterator(QueryComponents){
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
                return @as(*QueryIteratorSelf, @ptrCast(@alignCast(self_generic))).next();
            }

            fn generic_reset(self_generic: *anyopaque) void {
                @as(*QueryIteratorSelf, @ptrCast(@alignCast(self_generic))).reset();
            }
        };
    }
};

fn ComponentValuePointersTuple(comptime ComponentTypes: anytype) type {
    const info = @typeInfo(@TypeOf(ComponentTypes));

    var component_type_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (info.@"struct".fields, 0..) |_, idx| {
        const T = *ComponentTypes[idx];

        component_type_fields[idx] = std.builtin.Type.StructField{
            .name = std.fmt.comptimePrint("{d}", .{idx}),
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{ .@"struct" = .{
        .is_tuple = true,
        .fields = &component_type_fields,
        .decls = &.{},
        .layout = .auto,
    } });
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
        return ComponentA{
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
        return ComponentB{
            .i = 0,
        };
    }
};

const ResourceA = struct {
    value: i32,

    pub fn deinit(self: *ResourceA) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !ResourceA {
        _ = alloc;
        return ResourceA{
            .value = 0,
        };
    }
};

test "abc" {
    var ecs = try GenericEcsSystem.init(std.heap.page_allocator);
    defer ecs.deinit();

    ecs.register_component(ComponentA);
    ecs.register_component(ComponentB);

    ecs.register_resource(ResourceA);

    const resource_a = try ecs.create_resource(ResourceA);
    _ = resource_a;
    ecs.destroy_resource(ResourceA);

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
