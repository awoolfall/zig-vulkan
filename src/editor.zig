const std = @import("std");
const eng = @import("self");
const scene_util = @import("engine/scene_util.zig");

const Self = @This();

mode: enum {
    Editing,
    Playing,
},

saved_state: ?struct {
    arena: std.heap.ArenaAllocator,
    scene: std.json.Value,
    entities: []const scene_util.SerializedEntity,
},

default_camera: eng.Camera,

pub fn deinit(self: *Self) void {
    if (self.saved_state) |saved_state| {
        saved_state.arena.deinit();
        self.saved_state = null;
    }
}

pub fn init() !Self {
    return Self{
        .mode = .Editing,
        .saved_state = null,
        .default_camera = .{
            .field_of_view_y = eng.Camera.horizontal_to_vertical_fov(std.math.degreesToRadians(90.0), eng.get().gfx.swapchain_aspect()),
            .near_field = 0.3,
            .far_field = 10000.0,
            .move_speed = 10.0,
            .mouse_sensitivity = 0.001,
            .max_orbit_distance = 10.0,
            .min_orbit_distance = 1.0,
            .orbit_distance = 0.0,
        },
    };
}

pub fn update(self: *Self) !void {
    if (eng.get().input.get_key_up(eng.input.KeyCode.F1)) {
        try self.swap_mode();
    }

    switch (self.mode) {
        .Editing => try self.editing_update(),
        .Playing => {
            const app_update_result = eng.get().app_interface.fn_update();
            if (app_update_result != 0) {
                std.log.err("App Update error, returning to editor: {}", .{app_update_result});
                try self.swap_mode();
            }
        },
    }
}

fn swap_mode(self: *Self) !void {
    switch (self.mode) {
        .Editing => {
            var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
            errdefer arena.deinit();

            const serialized_scene = try scene_util.serialize_scene(&arena, &eng.get().ecs, "saved");
            const serialized_entities = try scene_util.serialize_entities(&arena, &eng.get().ecs);

            self.saved_state = .{
                .arena = arena,
                .scene = serialized_scene,
                .entities = serialized_entities,
            };

            self.mode = .Playing;
        },
        .Playing => {
            if (self.saved_state) |saved_state| {
                eng.get().ecs.clear_entities();
                scene_util.load_scene_into_ecs(&eng.get().ecs, &saved_state.scene);
                scene_util.load_serialized_entities_into_ecs(&eng.get().ecs, saved_state.entities);
                saved_state.arena.deinit();
                self.saved_state = null;
            }

            self.mode = .Editing;
        },
    }
}

fn editing_update(self: *Self) !void {
    self.default_camera.fly_camera_update(&eng.get().os, &eng.get().input, &eng.get().time);

    const imui = eng.get().ecs.get_resource(eng.Imui) orelse return error.ImuiResourceDoesNotExist;

    const top_bar_background = imui.push_layout(.X, .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(top_bar_background)) |top_widget| {
        top_widget.layout_axis = null;
        top_widget.semantic_size[0].kind = .ParentPercentage;
        top_widget.semantic_size[0].value = 1.0;
        top_widget.semantic_size = .{
            .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false },
            .{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = false },
        };
        top_widget.padding_px = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
        top_widget.children_gap = 5;
        top_widget.flags.render = true;
        top_widget.background_colour = imui.palette().background;
        top_widget.background_colour.?[3] = 0.5;
    }

    const l = eng.Imui.widgets.label.create(imui, try std.fmt.allocPrint(
        eng.get().frame_allocator,
        "Edit Mode{s}",
        .{
            "", //if (self.loaded_scene_name) |scene_name| try std.fmt.allocPrint(eng.get().frame_allocator, ": {s}", .{scene_name}) else "",
        },
    ));
    if (imui.get_widget(l.id)) |label_widget| {
        label_widget.anchor = .{ 0.5, 0.5 };
        label_widget.pivot = .{ 0.5, 0.5 };
    }

    // temporary button bind to load "scene"
    if (eng.get().input.get_key_up(eng.input.KeyCode.F2)) {
        // remove all entities (and components)
        eng.get().ecs.clear_entities();

        // Create new entities and set scene name
        var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
        defer arena.deinit();

        const serialized_entities = try scene_util.read_serialized_entites_from_filesystem(&arena, "scene");
        const serialized_scene = try scene_util.read_scene_file_from_filesystem(&arena, "scene");

        scene_util.load_scene_into_ecs(&eng.get().ecs, &serialized_scene);
        scene_util.load_serialized_entities_into_ecs(&eng.get().ecs, serialized_entities);
    }

    // temporary button bind to save "scene"
    if (eng.get().input.get_key_up(eng.input.KeyCode.F3)) {
        var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
        defer arena.deinit();

        const scene_entities = try scene_util.serialize_entities(&arena, &eng.get().ecs);
        const scene = try scene_util.serialize_scene(&arena, &eng.get().ecs, "scene");
        try scene_util.save_scene_to_filesystem("scene", scene, scene_entities);

        std.log.debug("saved scene {s}!", .{"scene"});
    }
}
