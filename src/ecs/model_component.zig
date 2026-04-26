const std = @import("std");
const eng = @import("self");
const sr = eng.serialize;
const as = eng.assets;

pub const COMPONENT_UUID = "0391f502-ebb5-4a64-8ed9-592bc7dabbe3";
pub const COMPONENT_NAME = "Model";

const Self = @This();

model: ?as.ModelAssetId = null,

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return .{};
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try object.put("model", try sr.serialize_value(?as.ModelAssetId, alloc, self.model));
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    var component: Self = .{};

    if (object.get("model")) |v| blk: { component.model = sr.deserialize_value(?as.ModelAssetId, alloc, v) catch break :blk; }

    return component;
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
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
        const drop_zone = eng.ui.widgets.file_drop_zone.create(imui, key ++ .{@src()});

        drop_zone.id.get().semantic_size[1].kind = .Pixels;
        drop_zone.id.get().semantic_size[1].value = 100.0;
        
        if (drop_zone.data_changed) blk: {
            if (eng.get().input.dropped_files.len == 0) { break :blk; }
            const file_path = eng.get().input.dropped_files[0];

            if (std.mem.startsWith(u8, file_path, eng.get().asset_manager.resource_directory_str)) {
                const uri = std.fmt.allocPrint(eng.get().frame_allocator, "res:{s}", .{file_path[eng.get().asset_manager.resource_directory_str.len..]}) catch break :blk;
                defer eng.get().frame_allocator.free(uri);

                const model_id = eng.get().asset_manager.get_asset_id(uri) catch break :blk;
                component.model = model_id;
            }
        }
    }

    if (component.model) |model_id| {
        const asset_metadata = eng.get().asset_manager.asset_metadata.get(model_id.unique_id) orelse unreachable;
        _ = eng.ui.widgets.label.create(imui, asset_metadata.uri);
    } else {
        _ = eng.ui.widgets.label.create(imui, "none");
    }

    if (eng.ui.widgets.badge.create(imui, "print model details", key ++ .{@src()}).clicked) blk: {
        const model_id = component.model orelse break :blk;
        const model_asset_metadata = eng.get().asset_manager.asset_metadata.get(model_id.unique_id) orelse unreachable;
        const model: *eng.mesh.Model = eng.get().asset_manager.get_asset(eng.assets.ModelAsset, model_id) catch |err| {
            std.log.err("Failed to get model asset from id: {}", .{err});
            break :blk;
        };

        std.log.info("model: {s}", .{model_asset_metadata.uri});
        std.log.info("num meshes: {}", .{model.meshes.len});
        for (model.meshes, 0..) |mesh, mesh_idx| {
            std.log.info("{} - num vertices: {}", .{mesh_idx, mesh.vertex_count});
            std.log.info("{} - num indices: {}", .{mesh_idx, mesh.index_count});
        }
        std.log.info("num bones: {}", .{model.bones_info.len});
        std.log.info("num animations: {}", .{model.animations.len});
        for (model.animations, 0..) |anim, anim_idx| {
            std.log.info("{} - animation: {s}", .{anim_idx, anim.name});
        }
        std.log.info("nodes: {}", .{model.nodes.len});
        for (model.nodes, 0..) |node, node_idx| {
            std.log.info("{} - {s}, parent: {}", .{node_idx, node.name orelse "unnamed", node.parent orelse 0});
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
