const std = @import("std");
const eng = @import("self");

pub const SerializedEntity = struct {
    id: u32,
    entity_s: std.json.Value,
};

fn open_scenes_dir(enableIterate: bool) !std.fs.Dir {
    return try std.fs.cwd().makeOpenPath("scenes", .{
        .iterate = enableIterate,
    });
}

pub fn load_serialized_entities_into_ecs(ecs: *eng.ecs.GenericEcsSystem, serialized_entities: []const SerializedEntity) void {
    for (serialized_entities) |serialized_entity| {
        const id = serialized_entity.id;
        const entity_s = serialized_entity.entity_s;

        const new_entity = ecs.deserialize_to_entity(entity_s) catch |err| {
            std.log.err("Failed to deserialize entity {}: {}", .{ id, err });
            continue;
        };

        // all loaded entities will be serialized so make sure it has the serialization component
        _ = ecs.add_component(eng.ecs.SerializationComponent, new_entity) catch |err| {
            std.log.warn("Unable to add serialization component to new entity: {}", .{err});
        };
    }
}

pub fn read_serialized_entites_from_filesystem(arena: *std.heap.ArenaAllocator, scene_name: []const u8) ![]const SerializedEntity {
    var serialized_arraylist = std.ArrayList(SerializedEntity).empty;
    errdefer serialized_arraylist.deinit(arena.allocator());

    var scenes_dir = try open_scenes_dir(true);
    defer scenes_dir.close();

    var dir = try scenes_dir.openDir(scene_name, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file) {
            // skip the scene file
            if (std.mem.eql(u8, entry.name, "scene.json")) {
                continue;
            }

            const id = std.fmt.parseInt(u32, std.fs.path.stem(entry.name), 10) catch |err| {
                std.log.warn("Unable to determine entity id number for file {s}: {}", .{ entry.name, err });
                continue;
            };

            const ent_file = dir.openFile(entry.name, .{}) catch |err| {
                std.log.err("Failed to open file {s}: {}", .{ entry.name, err });
                continue;
            };
            defer ent_file.close();

            const ent_str = ent_file.readToEndAlloc(eng.get().general_allocator, 1024 * 1024) catch |err| {
                std.log.err("Failed to read file {s}: {}", .{ entry.name, err });
                continue;
            };
            defer eng.get().general_allocator.free(ent_str);

            const ent_s = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), ent_str, .{ .ignore_unknown_fields = true }) catch |err| {
                std.log.err("Failed to parse file {s}: {}", .{ entry.name, err });
                continue;
            };

            try serialized_arraylist.append(arena.allocator(), .{ .id = id, .entity_s = ent_s });
        }
    }

    return try serialized_arraylist.toOwnedSlice(arena.allocator());
}

pub fn serialize_entities(arena: *std.heap.ArenaAllocator, ecs: *eng.ecs.GenericEcsSystem) ![]const SerializedEntity {
    var serialized_arraylist = std.ArrayList(SerializedEntity).empty;
    errdefer serialized_arraylist.deinit(arena.allocator());

    var serialize_component_iterator = ecs.query_iterator(.{eng.ecs.SerializationComponent});
    var largest_serialize_id: u32 = 0;
    while (serialize_component_iterator.next()) |components| {
        const serialize_component = components.@"0";
        largest_serialize_id = @max(largest_serialize_id, serialize_component.serialize_id orelse 0);
    }

    var entity_iterator = eng.get().ecs.entity_iterator();
    while (entity_iterator.next()) |entity| {
        const entity_serialize_component = eng.get().ecs.get_component(eng.ecs.SerializationComponent, entity) orelse continue;

        entity_serialize_component.serialize_id = entity_serialize_component.serialize_id orelse blk: {
            largest_serialize_id += 1;
            break :blk largest_serialize_id;
        };

        const entity_s = eng.get().ecs.serialize_entity(arena.allocator(), entity) catch |err| {
            std.log.err("unable to produce serializable for entity {}: {}\n", .{ entity_serialize_component.serialize_id.?, err });
            continue;
        };

        try serialized_arraylist.append(arena.allocator(), .{ .id = entity_serialize_component.serialize_id.?, .entity_s = entity_s });
    }

    return serialized_arraylist.toOwnedSlice(arena.allocator());
}

fn save_entities_to_filesystem(scene_dir: *std.fs.Dir, serialized_entities: []const SerializedEntity) !void {
    var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
    defer arena.deinit();

    for (serialized_entities) |serialized_entity| {
        if (!arena.reset(.retain_capacity)) {
            _ = arena.reset(.free_all);
        }

        const id = serialized_entity.id;
        const entity_s = serialized_entity.entity_s;

        var json_writer = std.io.Writer.Allocating.init(arena.allocator());
        defer json_writer.deinit();

        var json = std.json.Stringify{
            .writer = &json_writer.writer,
        };
        json.options.whitespace = .indent_2;

        json.write(entity_s) catch |err| {
            std.log.err("unable to write json for entity: {}", .{err});
            continue;
        };

        const file_path = std.fmt.allocPrint(arena.allocator(), "{d}.json", .{id}) catch |err| {
            std.log.err("unable to produce file path for entity {}: {}\n", .{ id, err });
            continue;
        };

        scene_dir.writeFile(.{
            .sub_path = file_path,
            .data = json_writer.written(),
            .flags = .{ .read = false, .truncate = true },
        }) catch |err| {
            std.log.err("unable to write file for entity {}: {}\n", .{ id, err });
            continue;
        };
    }
}

pub fn load_scene_into_ecs(ecs: *eng.ecs.GenericEcsSystem, scene: *const std.json.Value) void {
    const scene_obj = switch (scene.*) {
        .object => |obj| obj,
        else => return,
    };

    const scene_name = blk: {
        const scene_name_value = scene_obj.get("name") orelse break :blk "unknown";
        switch (scene_name_value) {
            .string => |str| break :blk str,
            else => break :blk "unknown",
        }
    };
    std.log.info("loading scene \"{s}\"", .{scene_name});

    const resources_value = scene_obj.get("resources") orelse return;
    const resources_obj = switch (resources_value) {
        .object => |resources_obj| resources_obj,
        else => return,
    };

    var ecs_resources_iter = ecs.resources.iterator();
    while (ecs_resources_iter.next()) |pair| {
        const resource_value = resources_obj.get(pair.value_ptr.uuid) orelse {
            // resource does not exist in the new scene, destroy it
            ecs.destroy_resource_generic(pair.key_ptr.*);
            continue;
        };
        if (pair.value_ptr.data == null) {
            ecs.create_resource_generic(pair.key_ptr.*) catch |err| {
                std.log.err("Unable to create resource: {}", .{err});
                continue;
            };
        }

        const resource_obj = switch (resource_value) {
            .object => |obj| obj,
            else => continue, // @TODO report invalid schema?
        };

        const result = pair.value_ptr.functions.fn_deserialize(ecs, &resource_obj);
        if (result == false) {
            std.log.err("Unable to deserialize resource \"{s}\"", .{pair.value_ptr.name});
            continue;
        }
    }
}

pub fn read_scene_file_from_filesystem(arena: *std.heap.ArenaAllocator, scene_name: []const u8) !std.json.Value {
    var scenes_dir = try open_scenes_dir(true);
    defer scenes_dir.close();

    var dir = try scenes_dir.openDir(scene_name, .{ .iterate = true });
    defer dir.close();

    const scene_file = dir.openFile("scene.json", .{}) catch |err| {
        std.log.err("Failed to open scene file for scene \"{s}\": {}", .{ scene_name, err });
        return err;
    };
    defer scene_file.close();

    const scene_str = scene_file.readToEndAlloc(eng.get().general_allocator, 1024 * 1024) catch |err| {
        std.log.err("Failed to read scene file for scene \"{s}\": {}", .{ scene_name, err });
        return err;
    };
    defer eng.get().general_allocator.free(scene_str);

    return std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), scene_str, .{ .ignore_unknown_fields = true }) catch |err| {
        std.log.err("Failed to parse scene file for scene \"{s}\": {}", .{ scene_name, err });
        return err;
    };
}

pub fn serialize_scene(arena: *std.heap.ArenaAllocator, ecs: *eng.ecs.GenericEcsSystem, scene_name: []const u8) !std.json.Value {
    var object = std.json.ObjectMap.init(arena.allocator());
    errdefer object.deinit();

    try object.put("name", std.json.Value{ .string = try arena.allocator().dupe(u8, scene_name) });
    try object.put("version", std.json.Value{ .integer = 1 });

    var resources_object = std.json.ObjectMap.init(arena.allocator());
    errdefer resources_object.deinit();

    var resource_iter = ecs.resources.iterator();
    while (resource_iter.next()) |pair| {
        if (pair.value_ptr.data) |resource_data| {
            var resource_object = std.json.ObjectMap.init(arena.allocator());
            errdefer resource_object.deinit();

            try resource_object.put("RESOURCE_NAME", std.json.Value{ .string = try arena.allocator().dupe(u8, pair.value_ptr.name) });

            // @TODO handle fail result
            _ = pair.value_ptr.functions.fn_serialize(&arena.allocator(), &resource_object, resource_data);

            try resources_object.put(try arena.allocator().dupe(u8, pair.value_ptr.uuid), std.json.Value{ .object = resource_object });
        }
    }

    try object.put("resources", std.json.Value{ .object = resources_object });

    return std.json.Value{ .object = object };
}

fn save_scene_file_to_filesystem(scene_dir: *std.fs.Dir, serialized_scene: std.json.Value) !void {
    var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
    defer arena.deinit();

    var json_writer = std.io.Writer.Allocating.init(arena.allocator());
    defer json_writer.deinit();

    var json = std.json.Stringify{
        .writer = &json_writer.writer,
    };
    json.options.whitespace = .indent_2;

    json.write(serialized_scene) catch |err| {
        std.log.err("unable to write json for scene: {}", .{err});
        return err;
    };

    const file_path = std.fmt.allocPrint(arena.allocator(), "scene.json", .{}) catch |err| {
        std.log.err("unable to produce file path for scene file: {}\n", .{err});
        return err;
    };

    scene_dir.writeFile(.{
        .sub_path = file_path,
        .data = json_writer.written(),
        .flags = .{ .read = false, .truncate = true },
    }) catch |err| {
        std.log.err("unable to write file for scene file: {}\n", .{err});
        return err;
    };
}

pub fn save_scene_to_filesystem(scene_name: []const u8, serialized_scene: std.json.Value, serialized_entities: []const SerializedEntity) !void {
    var scenes_dir = try open_scenes_dir(true);
    defer scenes_dir.close();

    // @TODO: save to a temp folder and then copy to the final dir if no errors occur
    scenes_dir.deleteTree(scene_name) catch |err| {
        std.debug.print("unable to delete scene {s}: {}\n", .{ scene_name, err });
    };

    var scene_dir = try scenes_dir.makeOpenPath(scene_name, .{ .iterate = true });
    defer scene_dir.close();

    try save_scene_file_to_filesystem(&scene_dir, serialized_scene);
    try save_entities_to_filesystem(&scene_dir, serialized_entities);
}
