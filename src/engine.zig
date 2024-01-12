const std = @import("std");
const zwin32 = @import("zwin32");
const zmesh = @import("zmesh");
const zm = @import("zmath");
const hrPanic = zwin32.hrPanicOnFail;

pub const d3d11 = @import("gfx/d3d11.zig");
pub const w32 = @import("platform/windows.zig");
pub const input = @import("input/input.zig");
pub const time = @import("engine/time.zig");
pub const tf = @import("engine/transform.zig");
pub const gen = @import("engine/entity.zig");
pub const mesh = @import("engine/mesh.zig");
pub const physics = @import("engine/physics.zig");
pub const Transform = tf.Transform;

const wb = @import("window.zig");

pub fn Engine(comptime App: type) type {
    return struct {
        const Self = @This();
        const Log = std.log.scoped(.Engine);

        pub const EntitySuperStruct = struct {
            name: ?[]u8 = null,
            transform: tf.Transform = tf.Transform.new(),
            mesh: ?*mesh.Mesh = null,
            physics_body: ?physics.zphy.BodyId = null,
            app: App.EntityData = App.EntityData {},
        };

        pub const EntityList = gen.GenerationalList(EntitySuperStruct);

        window: w32.Win32Window,
        gfx: d3d11.D3D11State,
        physics: physics.PhysicsSystem,
        input: input.InputState,
        time: time.TimeState,
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
                .physics = undefined,
                .input = undefined,
                .time = undefined,
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

            Log.debug("Calling Window init!", .{});
            engine.window = try w32.Win32Window.init();
            defer engine.window.deinit();

            Log.debug("Calling GFX init!", .{});
            engine.gfx = try d3d11.D3D11State.init(&engine.window);
            defer engine.gfx.deinit();

            Log.debug("Calling physics init", .{});
            engine.physics = try physics.PhysicsSystem.init(alloc, &engine.gfx);
            defer engine.physics.deinit();

            engine.entities = try EntityList.init(alloc);
            defer {
                for (engine.entities.data.items) |*it| {
                    if (it.item_data) |*en| {
                        if (en.physics_body) |body_id| {
                            engine.physics.zphy.getBodyInterfaceMut().removeAndDestroyBody(body_id);
                            en.physics_body = null;
                        }
                    }
                }
                engine.entities.deinit();
            }

            Log.debug("Calling app init!", .{});
            engine.app = try App.init(&engine);
            defer engine.app.deinit();

            Log.debug("Engine inited!", .{});
            engine.window.run(@ptrCast(&engine), &Self.window_event_received);
        }

        fn window_event_received(engine_void_ptr: *anyopaque, event: wb.WindowEvent) void {
            const self: *Self = @ptrCast(@alignCast(engine_void_ptr));
            
            // Timing needs to be updated at the very beginning of a frame
            self.time.received_window_event(&event);

            switch (event) {
                .RESIZED => |new_size| { self.gfx.window_resized(new_size.width, new_size.height); },
                else => {},
            }

            // Update input struct with key events
            self.input.received_window_event_early(&event);

            // Send event to the client app
            self.app.window_event_received(&event);

            // Run update procedure on inputs after everything has finished their update()
            self.input.received_window_event_late(&event);
        }

        pub fn create_entities_from_model(self: *Self, model: *const mesh.Model, out_entities: ?*std.ArrayList(gen.GenerationalIndex)) !?gen.GenerationalIndex {
            var new_entities_dat = try std.ArrayList(gen.GenerationalIndex).initCapacity(self.general_allocator.allocator(), model.nodes_list.len);
            defer new_entities_dat.deinit();

            var new_entities = out_entities;
            if (new_entities == null) {
                new_entities = &new_entities_dat;
            }

            const resolved_transforms = try self.general_allocator.allocator().alloc(?zm.Mat, model.nodes_list.len);
            defer self.general_allocator.allocator().free(resolved_transforms);
            for (resolved_transforms) |*r| { r.* = null; }

            var first_entity_with_mesh: ?gen.GenerationalIndex = null;
            for (model.nodes_list) |*n| {
                var parent_model_matrix = zm.identity();
                if (n.parent) |parent_idx| {
                    parent_model_matrix = model.recursive_get_node_model_matrix(parent_idx, resolved_transforms);
                }

                const ent_idx = try self.entities.insert(EntitySuperStruct {
                    .name = n.name,
                    .transform = Transform {
                        .position = zm.mul(n.transform.position, parent_model_matrix),
                        .rotation = zm.qmul(n.transform.rotation, zm.quatFromMat(parent_model_matrix)),
                        .scale = n.transform.scale, // @TODO: multiply this by parent
                    },
                    .mesh = n.mesh,
                });

                if (first_entity_with_mesh == null and n.mesh != null) {
                    first_entity_with_mesh = ent_idx;
                }

                try new_entities.?.append(ent_idx);
            }

            if (new_entities.?.items.len == 0) {
                return error.NoNewEntitiesAdded;
            }
            return first_entity_with_mesh;
        }
    };
}

