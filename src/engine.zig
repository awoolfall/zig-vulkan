const std = @import("std");
const zmesh = @import("zmesh");
pub const zm = @import("zmath");

pub const gitrev = @import("build_options").engine_gitrev;
pub const gitchanged = @import("build_options").engine_gitchanged;

pub const pl = @import("platform/platform.zig");
pub const _gfx = @import("gfx/gfx.zig");
pub const as = @import("asset/asset.zig");
pub const input = @import("input/input.zig");
pub const time = @import("engine/time.zig");
pub const tf = @import("engine/transform.zig");
pub const gen = @import("engine/gen_list.zig");
pub const mesh = @import("engine/mesh.zig");
pub const physics = @import("engine/physics.zig");
pub const image = @import("engine/image.zig");
pub const en = @import("engine/entity.zig");
pub const Transform = tf.Transform;

pub const window = @import("window.zig");

pub fn Engine(comptime App: type) type {
    return struct {
        const Self = @This();
        const Log = std.log.scoped(.Engine);

        pub const EntitySuperStruct = en.EntitySuperStruct(App);
        pub const EntityDescriptor = en.EntityDescriptor(App);
        pub const EntityList = en.EntityList(App);

        window: pl.Window,
        gfx: _gfx.GfxState,
        image: image.ImageLoader,
        physics: physics.PhysicsSystem,
        input: input.InputState,
        time: time.TimeState,
        asset_manager: as.AssetManager,
        app: App,
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
                .asset_manager = undefined,
                .app = undefined,
                .entities = undefined,
                .exe_path = undefined,
                .general_allocator = undefined,
            };

            engine.general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
            defer {
                const check = engine.general_allocator.deinit();
                std.debug.assert(check == std.heap.Check.ok);
            }
            const alloc = engine.general_allocator.allocator();

            engine.exe_path = try std.fs.selfExeDirPathAlloc(alloc);
            engine.exe_path = try alloc.realloc(engine.exe_path, engine.exe_path.len + 1);
            engine.exe_path[engine.exe_path.len - 1] = '\\';
            defer alloc.free(engine.exe_path);

            zmesh.init(alloc);
            defer zmesh.deinit();

            engine.time = time.TimeState.init();
            defer engine.time.deinit();

            Log.debug("Calling Input init", .{});
            engine.input = try input.InputState.init();
            defer engine.input.deinit();

            engine.image = try image.ImageLoader.init(alloc);
            defer engine.image.deinit();

            Log.debug("Calling Window init!", .{});
            engine.window = try pl.Window.init();
            defer engine.window.deinit();

            Log.debug("Calling GFX init!", .{});
            engine.gfx = try _gfx.GfxState.init(alloc, &engine.window);
            defer engine.gfx.deinit();

            engine.asset_manager = blk: {
                const resources_path = try std.fs.path.join(engine.general_allocator.allocator(), &[_][]const u8{engine.exe_path, "../../res"});
                defer engine.general_allocator.allocator().free(resources_path);

                break :blk try as.AssetManager.init(alloc, resources_path);
            };

            defer engine.asset_manager.deinit();
            Log.debug("Calling physics init", .{});
            engine.physics = try physics.PhysicsSystem.init(alloc, &engine.asset_manager, &engine.gfx);
            defer engine.physics.deinit();

            engine.entities = try EntityList.init(alloc, &engine);
            defer engine.entities.deinit(&engine);

            Log.debug("Calling app init!", .{});
            engine.app = try App.init(&engine);
            defer engine.app.deinit();

            Log.debug("Engine inited!", .{});
            engine.window.run(@ptrCast(&engine), &Self.window_event_received);
        }

        fn window_event_received(engine_void_ptr: *anyopaque, event: window.WindowEvent) void {
            const self: *Self = @ptrCast(@alignCast(engine_void_ptr));
            
            // Timing needs to be updated at the very beginning of a frame
            self.time.received_window_event(&event);

            switch (event) {
                .RESIZED => |new_size| { self.gfx.window_resized(new_size.width, new_size.height); },
                .EVENTS_CLEARED => {
                    // Update physics
                    self.physics.update(Self.EntityList, &self.entities, &self.time);
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
    };
}

