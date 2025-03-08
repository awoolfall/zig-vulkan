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
asset_manager: assets.AssetManager,
app: *App,
entities: EntityList,
exe_path: []u8,
general_allocator: std.heap.GeneralPurposeAllocator(.{}),

pub fn run() !void {
    Log.debug("Engine init!", .{});
    defer std.log.debug("Engine deinit!", .{});

    var engine = Self {
        .window = undefined,
        .gfx = undefined,
        .image = undefined,
        .physics = undefined,
        .input = undefined,
        .time = undefined,
        .debug = undefined,
        .asset_manager = undefined,
        .app = undefined,
        .entities = undefined,
        .exe_path = undefined,
        .general_allocator = undefined,
    };

    // set the global engine pointer
    @import("global_engine.zig").__global_engine = @ptrCast(&engine);

    engine.general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = engine.general_allocator.deinit();
        if (check != std.heap.Check.ok) {
            std.log.err("General allocator leak check: {}", .{check});
        }
    }
    const alloc = engine.general_allocator.allocator();

    engine.exe_path = try std.fs.selfExeDirPathAlloc(alloc);
    engine.exe_path = try alloc.realloc(engine.exe_path, engine.exe_path.len + 1);
    engine.exe_path[engine.exe_path.len - 1] = '\\';
    defer alloc.free(engine.exe_path);

    zmesh.init(alloc);
    defer zmesh.deinit();

    engine.time = tm.TimeState.init();
    defer engine.time.deinit();

    Log.debug("Calling Input init", .{});
    engine.input = try in.InputState.init();
    defer engine.input.deinit();

    engine.image = try im.ImageLoader.init(alloc);
    defer engine.image.deinit();

    Log.debug("Calling Window init!", .{});
    engine.window = try platform.Window.init();
    defer engine.window.deinit();

    Log.debug("Calling GFX init!", .{});
    engine.gfx = try gf.GfxState.init(alloc, &engine.window);
    defer engine.gfx.deinit();

    engine.asset_manager = blk: {
        const resources_path = try std.fs.path.join(engine.general_allocator.allocator(), &[_][]const u8{engine.exe_path, "../../res"});
        defer engine.general_allocator.allocator().free(resources_path);

        break :blk try assets.AssetManager.init(alloc, resources_path);
    };
    defer engine.asset_manager.deinit();

    engine.debug = try db.Debug.init(alloc, &engine.gfx);
    defer engine.debug.deinit();

    Log.debug("Calling physics init", .{});
    engine.physics = try ph.PhysicsSystem.init(alloc, &engine.asset_manager, &engine.gfx);
    defer engine.physics.deinit();

    engine.entities = try EntityList.init(alloc, &engine);
    defer engine.entities.deinit(&engine);

    Log.debug("Creating app!", .{});
    engine.app = try engine.general_allocator.allocator().create(App);
    defer engine.general_allocator.allocator().destroy(engine.app);

    Log.debug("Engine inited!", .{});

    Log.debug("Calling app init!", .{});
    engine.app.init() catch |err| {
        Log.err("App init failed! Error: {s}", .{@errorName(err)});
        return err;
    };
    defer engine.app.deinit();

    engine.window.run(@ptrCast(&engine), &Self.window_event_received);
}

fn window_event_received(engine_void_ptr: *anyopaque, event: wd.WindowEvent) void {
    const self: *Self = @ptrCast(@alignCast(engine_void_ptr));

    // Timing needs to be updated at the very beginning of a frame
    self.time.received_window_event(&event);

    switch (event) {
        .RESIZED => |new_size| { self.gfx.window_resized(new_size.width, new_size.height); },
        .EVENTS_CLEARED => {
            // Update physics
            self.physics.update();
        },
        else => {},
    }

    // Update input struct with key events
    self.input.received_window_event_early(&event);

    // Send event to the client app
    self.app.window_event_received(&event);

    // Run update procedure on inputs after everything has finished their update()
    self.input.received_window_event_late(&event);
}

