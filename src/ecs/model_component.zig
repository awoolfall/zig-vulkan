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

pub fn serialize(alloc: std.mem.Allocator, value: Self) !std.json.Value {
    var object = std.json.ObjectMap.init(alloc);
    errdefer object.deinit();

    try object.put("model", try sr.serialize_value(?as.ModelAssetId, alloc, value.model));

    return std.json.Value { .object = object };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    var component: Self = .{};
    const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

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

        const model_combobox = eng.ui.widgets.combobox.create(imui, key ++ .{@src()});
        const model_combobox_data, _ = imui.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, model_combobox.id) catch unreachable;

        if (model_combobox.init) {
            std.log.info("model combobox init", .{});

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

        if (model_combobox_data.selected_index) |selected_model_index| {
            if (eng.assets.ModelAssetId.from_string_identifier(model_combobox_data.options.items[selected_model_index])) |model_id| {
                if (eng.ui.widgets.badge.create(imui, "print model details", key ++ .{@src()}).clicked) blk: {
                    const model: *eng.mesh.Model = eng.get().asset_manager.get_asset(eng.assets.ModelAsset, model_id) catch |err| {
                        std.log.err("Failed to get model asset from id: {}", .{err});
                        break :blk;
                    };
                    std.log.info("model: {s}", .{model_combobox_data.options.items[selected_model_index]});
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
                }
            } else |_| { 
                std.log.err("Failed to deserialize model id!", .{});
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
