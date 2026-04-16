const std = @import("std");
const App = @import("app");
const eng = @import("self");
const Imui = eng.ui;
const db = @import("debug/debug.zig");

const znoise = @import("znoise");
const zmesh = @import("zmesh");

const Self = @This();

const Log = std.log.scoped(.Engine);

window: eng.window.Window,
gfx: eng.gfx.GfxState,
image: eng.image.ImageLoader,
physics: eng.physics.PhysicsSystem,
input: eng.input.InputState,
time: eng.time.TimeState,
debug: db.Debug,
imui: Imui,
asset_manager: eng.assets.AssetManager,
profiler: eng.util.Profiler,
app: *App,
ecs: eng.AppEcsSystem,
exe_path: []u8,

general_allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
frame_allocator: std.mem.Allocator,

core_asset_pack_id: u64,

pub export fn deinit(self: *Self) void {
    self.gfx.flush();

    defer self.general_allocator.destroy(self);
    defer self.frame_arena.deinit();
    defer self.general_allocator.free(self.exe_path);
    defer self.profiler.deinit();
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
    defer self.ecs.deinit();

    defer self.asset_manager.unload_asset_pack(self.core_asset_pack_id) catch |err| {
        std.log.err("Unable to unload core asset pack: {}", .{err});
    };

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

    engine.profiler = eng.util.Profiler.init(engine.general_allocator);
    errdefer engine.profiler.deinit();

    zmesh.init(engine.general_allocator);
    errdefer zmesh.deinit();

    engine.time = eng.time.TimeState.init();
    errdefer engine.time.deinit();

    Log.debug("Calling Input init", .{});
    engine.input = try eng.input.InputState.init();
    errdefer engine.input.deinit();

    engine.image = try eng.image.ImageLoader.init(engine.general_allocator);
    errdefer engine.image.deinit();

    Log.debug("Calling Window init!", .{});
    engine.window = try eng.window.Window.init();
    errdefer engine.window.deinit();

    Log.debug("Calling GFX init!", .{});
    engine.gfx = try eng.gfx.GfxState.init(engine.general_allocator, &engine.window);
    errdefer engine.gfx.deinit();
    try engine.gfx.init_late(&engine.window);

    engine.asset_manager = blk: {
        const resources_path = try std.fs.path.join(engine.general_allocator, &[_][]const u8{engine.exe_path, "../../res"});
        defer engine.general_allocator.free(resources_path);

        break :blk try eng.assets.AssetManager.init(engine.general_allocator, resources_path);
    };
    errdefer engine.asset_manager.deinit();

    engine.imui = try Imui.init(engine.general_allocator);
    errdefer engine.imui.deinit();

    engine.debug = try db.Debug.init(engine.general_allocator);
    errdefer engine.debug.deinit();

    Log.debug("Calling physics init", .{});
    engine.physics = try eng.physics.PhysicsSystem.init(engine.general_allocator, &engine.asset_manager);
    errdefer engine.physics.deinit();

    engine.ecs = try eng.AppEcsSystem.init(engine.general_allocator);
    errdefer engine.ecs.deinit();

    // load core assets
    var core_asset_pack = blk: {
        const core_asset_pack_zon = @embedFile("core_assets.zon");
        const core_asset_pack_zon_0 = try engine.general_allocator.dupeZ(u8, core_asset_pack_zon[0..]);
        defer engine.general_allocator.free(core_asset_pack_zon_0);

        break :blk try eng.assets.AssetPack.init_from_buffer(engine.general_allocator, "core", core_asset_pack_zon_0);
    };
    errdefer core_asset_pack.deinit();

    engine.core_asset_pack_id = try engine.asset_manager.add_asset_pack(core_asset_pack);
    try engine.asset_manager.load_asset_pack(engine.core_asset_pack_id);
    errdefer engine.asset_manager.unload_asset_pack(engine.core_asset_pack_id) catch |err| {
        std.log.err("Unable to unload core asset pack: {}", .{err});
    };

    Log.debug("Engine inited!", .{});

    Log.debug("Creating app!", .{});
    engine.app = try engine.general_allocator.create(App);
    errdefer engine.general_allocator.destroy(engine.app);

    Log.debug("Calling app init!", .{});
    engine.app.* = App.init() catch |err| {
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
    self.imui.end_frame();

    // Update physics
    var physics_iter = self.ecs.query_iterator(.{ eng.ecs.TransformComponent, eng.ecs.PhysicsComponent });
    self.physics.update(physics_iter.create_generic_iterator());
}

fn window_event_received(engine_void_ptr: *anyopaque, event: eng.window.WindowEvent) void {
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

