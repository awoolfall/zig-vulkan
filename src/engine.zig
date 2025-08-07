const std = @import("std");
const App = @import("app");

const znoise = @import("znoise");
const zmesh = @import("zmesh");

const platform = @import("platform/platform.zig");
const gf = @import("gfx/gfx.zig");
const assets = @import("asset/asset.zig");
const in = @import("input/input.zig");
const tm = @import("engine/time.zig");
const mesh = @import("engine/mesh.zig");
const ph = @import("engine/physics.zig");
const im = @import("engine/image.zig");
const entity = @import("engine/entity.zig");
const gen = @import("engine/gen_list.zig");
const Transform = @import("engine/transform.zig");
const ui = @import("ui/ui.zig");

const path = @import("engine/path.zig");
const db = @import("debug/debug.zig");

const wd = @import("window.zig");

const Self = @This();
const Log = std.log.scoped(.Engine);

pub const EntitySuperStruct = entity.EntitySuperStruct;
pub const EntityDescriptor = entity.EntityDescriptor;
pub const EntityList = entity.EntityList;

window: platform.Window,
gfx: gf.GfxState,
image: im.ImageLoader,
physics: ph.PhysicsSystem,
input: in.InputState,
time: tm.TimeState,
debug: db.Debug,
imui: ui.Imui,
asset_manager: assets.AssetManager,
app: *App,
entities: EntityList,
exe_path: []u8,

general_allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
frame_allocator: std.mem.Allocator,

pub export fn deinit(self: *Self) void {
    self.gfx.flush();

    defer self.general_allocator.destroy(self);
    defer self.frame_arena.deinit();
    defer self.general_allocator.free(self.exe_path);
    defer zmesh.deinit();
    defer self.time.deinit();
    defer self.input.deinit();
    defer self.image.deinit();
    defer self.window.deinit();
    defer self.gfx.deinit();
    defer self.asset_manager.deinit();
    defer self.imui.deinit();
    defer self.debug.deinit();
    defer self.physics.deinit();
    defer self.entities.deinit();
    defer self.general_allocator.destroy(self.app);
    defer self.app.deinit();
}

pub export fn init_engine(alloc: *std.mem.Allocator) ?*Self {
    return init(alloc.*) catch unreachable;
}

pub fn init(alloc: std.mem.Allocator) !*Self {
    Log.debug("Engine init!", .{});
    errdefer std.log.debug("Engine deinit!", .{});

    const engine = try alloc.create(Self);
    errdefer alloc.destroy(engine);

    // set the global engine pointer
    @import("global_engine.zig").__global_engine = engine;

    engine.general_allocator = alloc;

    engine.frame_arena = std.heap.ArenaAllocator.init(engine.general_allocator);
    errdefer engine.frame_arena.deinit();
    engine.frame_allocator = engine.frame_arena.allocator();

    engine.exe_path = try std.fs.selfExeDirPathAlloc(engine.general_allocator);
    engine.exe_path = try alloc.realloc(engine.exe_path, engine.exe_path.len + 1);
    engine.exe_path[engine.exe_path.len - 1] = '\\';
    errdefer engine.general_allocator.free(engine.exe_path);

    zmesh.init(engine.general_allocator);
    errdefer zmesh.deinit();

    engine.time = tm.TimeState.init();
    errdefer engine.time.deinit();

    Log.debug("Calling Input init", .{});
    engine.input = try in.InputState.init();
    errdefer engine.input.deinit();

    engine.image = try im.ImageLoader.init(engine.general_allocator);
    errdefer engine.image.deinit();

    Log.debug("Calling Window init!", .{});
    engine.window = try platform.Window.init();
    errdefer engine.window.deinit();

    Log.debug("Calling GFX init!", .{});
    try engine.gfx.init(engine.general_allocator, &engine.window);
    errdefer engine.gfx.deinit();

    engine.asset_manager = blk: {
        const resources_path = try std.fs.path.join(engine.general_allocator, &[_][]const u8{engine.exe_path, "../../res"});
        defer engine.general_allocator.free(resources_path);

        break :blk try assets.AssetManager.init(engine.general_allocator, resources_path);
    };
    errdefer engine.asset_manager.deinit();

    engine.imui = try ui.Imui.init(engine.general_allocator, &engine.input, &engine.time, &engine.window, &engine.gfx);
    errdefer engine.imui.deinit();

    engine.debug = try db.Debug.init(engine.general_allocator);
    errdefer engine.debug.deinit();

    Log.debug("Calling physics init", .{});
    engine.physics = try ph.PhysicsSystem.init(engine.general_allocator, &engine.asset_manager);
    errdefer engine.physics.deinit();

    engine.entities = try EntityList.init(engine.general_allocator);
    errdefer engine.entities.deinit();

    Log.debug("Creating app!", .{});
    engine.app = try engine.general_allocator.create(App);
    errdefer engine.general_allocator.destroy(engine.app);

    Log.debug("Engine inited!", .{});

    Log.debug("Calling app init!", .{});
    engine.app.init() catch |err| {
        Log.err("App init failed! Error: {s}", .{@errorName(err)});
        unreachable;
    };
    errdefer engine.app.deinit();

    engine.gfx.flush();
    return engine;
}

pub export fn run(engine: *Self) void {
    engine.window.run(engine, &Self.window_event_received);
}

fn pre_app_update(self: *Self) !void {
    // Reset the frame allocator
    if (!self.frame_arena.reset(.retain_capacity)) {
        std.log.err("failed to reset frame arena", .{});
        _ = self.frame_arena.reset(.free_all);
    }

    // reset imui for next frame
    self.imui.end_frame(&self.gfx);

    // Update physics
    self.physics.update();
}

fn window_event_received(engine_void_ptr: *anyopaque, event: wd.WindowEvent) void {
    const self: *Self = @ptrCast(@alignCast(engine_void_ptr));

    // Timing needs to be updated at the very beginning of a frame
    self.time.received_window_event(&event);

    // send event to gfx
    self.gfx.received_window_event(&event);

    // Update input struct with key events
    self.input.received_window_event_early(&event);

    switch (event) {
        .EVENTS_CLEARED => self.pre_app_update() catch |err| {
            std.log.err("pre app update failed: {}", .{err});
        },
        else => {},
    }

    // Send event to the client app
    self.app.window_event_received(&event);

    // Run update procedure on inputs after everything has finished their update()
    self.input.received_window_event_late(&event);
}

