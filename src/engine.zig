const std = @import("std");
const AppInterface = @import("app_interface.zig");
const eng = @import("self");
const Imui = eng.ui;
const db = @import("debug/debug.zig");

const znoise = @import("znoise");
const zmesh = @import("zmesh");

const Self = @This();

const Log = std.log.scoped(.Engine);

os: eng.os.Platform,
window: eng.os.Window,
gfx: eng.gfx.GfxState,
physics: eng.physics.PhysicsSystem,
input: eng.input.InputState,
time: eng.time.TimeState,
debug: db.Debug,
imui: Imui,
asset_manager: eng.assets.AssetManager,
app: ?*anyopaque,
ecs: eng.ecs.GenericEcsSystem,
exe_path: []u8,

general_allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
frame_allocator: std.mem.Allocator,

app_dll_filewatcher: eng.assets.FileWatcher,
app_dll: ?std.DynLib,
app_interface: AppInterface,

pub export fn deinit(self: *Self) void {
    self.gfx.flush();

    // deinit ecs before unloading app shared library since it
    // relies on function pointers that may exist in that lib
    self.ecs.deinit();

    self.app_interface.fn_deinit(self.app);
    if (self.app_dll) |*app_dll| {
        app_dll.close();
    }
    self.app_dll_filewatcher.deinit();

    self.physics.deinit();
    self.debug.deinit();
    self.imui.deinit();
    self.asset_manager.deinit();
    self.gfx.deinit();
    self.os.deinit();
    self.input.deinit();
    self.time.deinit();
    zmesh.deinit();
    self.general_allocator.free(self.exe_path);
    self.frame_arena.deinit();
    self.general_allocator.destroy(self);
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
    eng.set_global_engine_ptr(engine);

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

    engine.ecs = try eng.ecs.GenericEcsSystem.init(engine.general_allocator);
    errdefer engine.ecs.deinit();

    // register standard components
    inline for (eng.ecs.StandardEntityComponents) |T| {
        try engine.ecs.register_component(T);
    }

    const app_dll_path = try std.fs.path.join(engine.general_allocator, &[_][]const u8{engine.exe_path, "app.dll"});
    defer engine.general_allocator.free(app_dll_path);

    engine.app_dll_filewatcher = try eng.assets.FileWatcher.init(engine.general_allocator, app_dll_path, 1000);
    errdefer engine.app_dll_filewatcher.deinit();

    engine.app_dll = null;
    try engine.reload_app_dll();
    errdefer engine.app_dll.?.close();

    Log.debug("Engine inited!", .{});

    Log.debug("Creating app!", .{});
    engine.app = engine.app_interface.fn_init(engine);
    if (engine.app == null) {
        return error.AppInitFailed;
    }
    errdefer engine.app_interface.fn_deinit(engine.app);

    engine.gfx.flush();

    return engine;
}

pub inline fn main_window(self: *Self) *eng.os.Window {
    return &self.window;
}

fn reload_app_dll(self: *Self) !void {
    if (self.app_dll) |*app_dll| {
        self.app_interface.fn_app_dll_unload(self);
        app_dll.close();
        self.app_dll = null;
    }

    const app_dll_path = try std.fs.path.join(self.general_allocator, &[_][]const u8{self.exe_path, "app.dll"});
    defer self.general_allocator.free(app_dll_path);

    const running_app_dll_path = try std.fs.path.join(self.general_allocator, &[_][]const u8{self.exe_path, "app.running.dll"});
    defer self.general_allocator.free(running_app_dll_path);

    try std.fs.copyFileAbsolute(app_dll_path, running_app_dll_path, .{});

    self.app_dll = try std.DynLib.open(running_app_dll_path);
    errdefer self.app_dll.?.close();

    self.app_interface = try AppInterface.init_interface(&self.app_dll.?);

    self.app_interface.fn_app_dll_load(self);
}

pub export fn run(engine: *Self) void {
    main_loop: while (true) {
        const event = try engine.os.pull_event();

        switch (event) {
            .EVENTS_CLEARED => {
                // new frame
                eng.ztracy.FrameMark();

                if (engine.app_dll_filewatcher.was_modified_since_last_check()) {
                    engine.reload_app_dll() catch |err| {
                        std.log.err("Unable to reload app dll: {}", .{err});
                        engine.main_window().close_window();
                        break :main_loop;
                    };
                    engine.app_interface = AppInterface.init_interface(&engine.app_dll.?) catch |err| {
                        std.log.err("Unable to reload app dll: {}", .{err});
                        engine.main_window().close_window();
                        break :main_loop;
                    };
                }
                
                // Reset the frame allocator
                if (!engine.frame_arena.reset(.retain_capacity)) {
                    std.log.warn("failed to reset frame arena while retaining capacity", .{});
                    _ = engine.frame_arena.reset(.free_all);
                }

                engine.time.start_new_frame();

                engine.input.start_new_frame();

                engine.imui.start_new_frame();

                var physics_iter = engine.ecs.query_iterator(.{ eng.ecs.TransformComponent, eng.ecs.PhysicsComponent, eng.ecs.PhysicsRuntimeComponent });
                engine.physics.update(physics_iter.create_generic_iterator());

                if (engine.app_interface.fn_update(engine.app, engine) != 0) {
                    engine.main_window().close_window();
                    break :main_loop;
                }
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

pub export fn app_dll_unload(engine_opqaqueptr: ?*anyopaque) void {
    _ = engine_opqaqueptr;
    eng.zmesh.deinit();
}

pub export fn app_dll_load(engine_opqaqueptr: ?*anyopaque) void {
    const engine_ptr: *eng.Engine = @ptrCast(@alignCast(engine_opqaqueptr));
    eng.set_global_engine_ptr(engine_ptr);

    eng.zmesh.init(engine_ptr.general_allocator);
}
