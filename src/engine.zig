const std = @import("std");
const App = @import("app");
const eng = @import("self");
const Imui = eng.ui;
const db = @import("debug/debug.zig");

const znoise = @import("znoise");
const zmesh = @import("zmesh");

const Self = @This();

const Log = std.log.scoped(.Engine);

os: eng.os.Platform,
window: ?eng.os.Window = null,
gfx: eng.gfx.GfxState,
image: eng.image.ImageLoader,
physics: eng.physics.PhysicsSystem,
input: eng.input.InputState,
time: eng.time.TimeState,
debug: db.Debug,
imui: Imui,
asset_manager: eng.assets.AssetManager,
app: *App,
ecs: eng.AppEcsSystem,
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
    defer self.os.deinit();
    defer self.gfx.deinit();
    defer self.asset_manager.deinit();
    defer self.imui.deinit();
    defer self.debug.deinit();
    defer self.physics.deinit();
    defer self.ecs.deinit();

    defer self.general_allocator.destroy(self.app);
    defer self.app.deinit();
}

pub export fn init_engine(alloc: *std.mem.Allocator) ?*Self {
    return init(alloc.*) catch unreachable;
}

pub fn init(alloc: std.mem.Allocator) !*Self {
    const __tracy_zone = eng.ztracy.ZoneN(@src(), "Engine init");
    defer __tracy_zone.End();

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

    engine.time = eng.time.TimeState.init();
    errdefer engine.time.deinit();

    Log.debug("Calling Input init", .{});
    engine.input = try eng.input.InputState.init();
    errdefer engine.input.deinit();

    engine.image = try eng.image.ImageLoader.init(engine.general_allocator);
    errdefer engine.image.deinit();

    Log.debug("Calling Window init!", .{});
    engine.os = try eng.os.Platform.init();
    errdefer engine.os.deinit();

    try engine.os.create_new_window(0, 0);
    while (true) {
        const event = try engine.os.pull_event();
        switch (event) {
            .WINDOW_CREATED => |wc| {
                engine.window = wc.window;
                break;
            },
            else => {},
        }
    }

    Log.debug("Calling GFX init!", .{});
    engine.gfx = try eng.gfx.GfxState.init(engine.general_allocator, engine.main_window());
    errdefer engine.gfx.deinit();
    try engine.gfx.init_late(engine.main_window());

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
    engine.physics = try eng.physics.PhysicsSystem.init(engine.general_allocator);
    errdefer engine.physics.deinit();

    engine.ecs = try eng.AppEcsSystem.init(engine.general_allocator);
    errdefer engine.ecs.deinit();

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

pub inline fn main_window(self: *Self) *eng.os.Window {
    return &self.window.?;
}

pub export fn run(engine: *Self) void {
    main_loop: while (true) {
        const event = try engine.os.pull_event();

        switch (event) {
            .EVENTS_CLEARED => {
                // new frame
                eng.ztracy.FrameMark();
                
                // Reset the frame allocator
                if (!engine.frame_arena.reset(.retain_capacity)) {
                    std.log.err("failed to reset frame arena", .{});
                    _ = engine.frame_arena.reset(.free_all);
                }

                engine.time.start_new_frame();

                engine.input.start_new_frame();

                engine.imui.start_new_frame();

                var physics_iter = engine.ecs.query_iterator(.{ eng.ecs.TransformComponent, eng.ecs.PhysicsComponent, eng.ecs.PhysicsRuntimeComponent });
                engine.physics.update(physics_iter.create_generic_iterator());

                engine.app.update() catch |err| {
                    std.log.err("App failed update: {}", .{err});
                    engine.main_window().close_window();
                };
            },
            .WINDOW_REQUESTED_CLOSE => |window_id| {
                _ = window_id;
                // @TODO handle multiple windows
                engine.gfx.platform.valid_swapchain = false; // TEMP FIX disable rendering before destroying window surface
                engine.main_window().close_window();
            },
            .WINDOW_CLOSED => |window_id| {
                // break main loop if the closed window was the main window
                if (window_id == 0) {
                    break :main_loop;
                }
            },
            else => {
                // run event handlers
                engine.time.received_window_event(&event);
                engine.gfx.received_window_event(&event);
                engine.input.received_window_event(&event);
            },
        }

        switch (event) {
            .DROPPED_FILES => |d| {
                d.deinit(engine.general_allocator);
            },
            else => {},
        }
    }
}
