const std = @import("std");
const zwin32 = @import("zwin32");
const zmesh = @import("zmesh");
const hrPanic = zwin32.hrPanicOnFail;

const d3d11 = @import("gfx/d3d11.zig");
const w32 = @import("platform/windows.zig");
const input = @import("input/input.zig");
const time = @import("engine/time.zig");
const tf = @import("engine/transform.zig");
const gen = @import("engine/entity.zig");
const ms = @import("engine/mesh.zig");
const ps = @import("engine/physics.zig");
pub const Transform = tf.Transform;

const wb = @import("window.zig");

pub fn Engine(comptime App: type) type {
    return struct {
        const Self = @This();
        const Log = std.log.scoped(.Engine);

        pub const EntitySuperStruct = struct {
            name: ?[]u8 = null,
            transform: tf.Transform = tf.Transform.new(),
            mesh: ?*ms.Mesh = null,
            parent: ?gen.GenerationalIndex = null,
            children: ?std.ArrayList(gen.GenerationalIndex) = null,
            app: App.EntityData = App.EntityData {},
        };

        pub const EntityList = gen.GenerationalList(EntitySuperStruct);

        window: w32.Win32Window,
        gfx: d3d11.D3D11State,
        physics: ps.PhysicsSystem,
        input: input.InputState,
        time: time.TimeState,
        app: App,
        entities: EntityList,
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
                .general_allocator = undefined,
            };

            engine.general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
            defer {
                const check = engine.general_allocator.deinit();
                std.debug.assert(check == std.heap.Check.ok);
            }
            const alloc = engine.general_allocator.allocator();

            engine.entities = try EntityList.init(alloc);
            defer {
                for (engine.entities.data.items) |*maybe_en| {
                    if (maybe_en.*) |*en| {
                        if (en.children != null) {
                            en.children.?.deinit();
                        }
                    }
                }
                engine.entities.deinit();
            }

            zmesh.init(alloc);
            defer zmesh.deinit();

            Log.debug("Calling physics init", .{});
            engine.physics = try ps.PhysicsSystem.init(alloc);
            defer engine.physics.deinit();

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

        pub fn delete_entity_and_children(self: *Self, ent_idx: gen.GenerationalIndex) !void {
            const ent = try self.entities.get(ent_idx);

            // recursively delete children
            if (ent.children) |*children| {
                for (children.items) |child_idx| {
                    try self.delete_entity_and_children(child_idx);
                }
            }

            // remove this entity from parent's children list
            if (ent.parent) |parent_idx| {
                var parent_ent = try self.entities.get(parent_idx);
                for (parent_ent.children.?.items, 0..) |child_idx, i| {
                    if (child_idx.index == ent_idx.index and child_idx.generation == ent_idx.generation) {
                        _ = parent_ent.children.?.orderedRemove(i);
                        break;
                    }
                }
            }

            // delete this entity from engine entity list
            try self.entities.remove(ent_idx);
        }

        pub fn create_entities_from_model(self: *Self, model: *const ms.Model) !gen.GenerationalIndex {
            const alloc = self.general_allocator.allocator();

            const new_entities = try alloc.alloc(gen.GenerationalIndex, model.nodes_list.len);
            defer alloc.free(new_entities);

            for (model.nodes_list, 0..) |*n, n_idx| {
                const ent_idx = try self.entities.insert(EntitySuperStruct {
                    .name = n.name,
                    .transform = n.transform,
                    .mesh = n.mesh,
                });
                new_entities[n_idx] = ent_idx;
            }

            // Once all the entities have been created we can then assign heirarchy
            for (model.nodes_list, 0..) |*n, n_idx| {
                var entity = self.entities.get(new_entities[n_idx]) catch unreachable;

                if (n.parent) |p_idx| {
                    entity.parent = new_entities[p_idx];
                }

                if (n.children) |children| {
                    entity.children = try std.ArrayList(gen.GenerationalIndex).initCapacity(alloc, n.children.?.len);
                    for (children) |c_node_idx| {
                        try entity.children.?.append(new_entities[c_node_idx]);
                    }
                }
            }

            // Return the first root node
            return new_entities[model.root_nodes[0]];
        }

        pub fn find_child_with_name(self: *Self, ent_idx: gen.GenerationalIndex, name: []const u8) ?gen.GenerationalIndex {
            // Return null if ent_idx is not a valid entity
            const entity = self.entities.get(ent_idx) catch return null;

            // Return entity idx if this entity has the required name
            if (std.mem.eql(u8, name, entity.name)) {
                return ent_idx;
            }

            // Otherwise search all entity's children
            if (entity.children) |*children| {
                for (children) |child_idx| {
                    if (find_child_with_name(child_idx, name, self.entities)) |idx| {
                        return idx;
                    }
                }
            }

            // If no children have the required name, return null
            return null;
        }

        pub fn print_entity_chain(self: *Self, ent_idx: gen.GenerationalIndex, indent: usize) void {
            for (0..indent) |_| {
                std.debug.print("| ", .{});
            }
            const entity = self.entities.get(ent_idx) catch unreachable;
            if (entity.name) |name| {
                std.debug.print("{s}\n", .{name});
            } else {
                std.debug.print("unnamed\n", .{});
            }
            if (entity.children) |*children| {
                for (children.items) |child_idx| {
                    self.print_entity_chain(child_idx, indent + 1);
                }
            }
        }

    };
}

