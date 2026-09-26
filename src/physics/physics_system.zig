const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const zphy = @import("zphysics");
const ZphysicsInterface = @import("zphysics_interface.zig");
const physics = eng.physics;

const Self = @This();

pub const UpdateRateHz = 15;
pub const UpdateRateS = (1.0 / @as(comptime_float, @floatFromInt(UpdateRateHz)));
pub const UpdateRateNs = @divFloor(std.time.ns_per_s, UpdateRateHz);

inline fn debug_renderer_enabled() bool {
    return true;
}
const DebugRenderer = if (debug_renderer_enabled()) @import("physics_debug_renderer.zig").D3D11DebugRenderer else void;

alloc: std.mem.Allocator,

debug_renderer: if (debug_renderer_enabled()) *DebugRenderer else void,

zphysics: ZphysicsInterface,

last_update_time: std.time.Instant,
last_update_time_offset: u64 = 0,

pub fn deinit(self: *Self) void {
    if (debug_renderer_enabled()) {
        @import("zphysics").DebugRenderer.destroySingleton();
        self.debug_renderer.deinit();
        self.alloc.destroy(self.debug_renderer);
    }
    self.zphysics.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    var zphysics = try ZphysicsInterface.init(alloc);
    errdefer zphysics.deinit();

    var debug_renderer: ?*DebugRenderer = null;
    if (debug_renderer_enabled()) {
        debug_renderer = try alloc.create(DebugRenderer);
        debug_renderer.?.* = try DebugRenderer.init();

        try @import("zphysics").DebugRenderer.createSingleton(debug_renderer.?);
        errdefer @import("zphysics").DebugRenderer.destroySingleton();
    }
    errdefer if (debug_renderer) |r| alloc.destroy(r);

    return Self {
        .alloc = alloc,
        .debug_renderer = if (debug_renderer_enabled()) debug_renderer.? else undefined,
        .zphysics = zphysics,
        .last_update_time = std.time.Instant.now() catch unreachable,
    };
}

pub fn update(
    self: *Self,
    components_query_iterator: eng.ecs.GenericQueryIterator(.{ eng.ecs.TransformComponent, eng.ecs.PhysicsComponent, eng.ecs.PhysicsRuntimeComponent })
) void {
    const time = &eng.get().time;

    // find out how many times we need to update to hit UpdateRateHz
    const ns_since_last_update = time.frame_start_time.since(self.last_update_time) + self.last_update_time_offset;
    const times_to_update = @divFloor(ns_since_last_update, UpdateRateNs);
    
    const physics_delta_time: f32 = UpdateRateS * @as(f32, @floatCast(eng.get().time.time_scale));

    self.zphysics.system.optimizeBroadPhase(); // TODO: conditional on how many new entities were added?

    if (times_to_update >= 1) {
        { // TODO: Speed: change this to only update when something has changed. Hash?
            const body_interface = self.zphysics.system.getBodyInterfaceMut();

            components_query_iterator.reset();
            while (components_query_iterator.next()) |components| {
                const entity_transform: *eng.ecs.TransformComponent,
                const entity_physics: *eng.ecs.PhysicsComponent,
                const entity_physics_runtime: *eng.ecs.PhysicsRuntimeComponent = components;

                switch (entity_physics_runtime.runtime_data) {
                    .None => {
                        entity_physics_runtime.last_frame_data.position = entity_transform.transform.position;
                        entity_physics_runtime.last_frame_data.rotation = entity_transform.transform.rotation;
                    },
                    .Body => |body| {
                        body_interface.setLinearVelocity(body.id, zm.vecToArr3(entity_physics.velocity));
                        body_interface.setPosition(body.id, zm.vecToArr3(entity_transform.transform.position), .dont_activate);
                        body_interface.setRotation(body.id, zm.vecToArr4(entity_transform.transform.rotation), .activate);
                    },
                    .Character => |character| {
                        character.character.setPosition(zm.vecToArr3(entity_transform.transform.position));
                        //character.character.setRotation(zm.vecToArr4(entity_transform.transform.rotation));

                        character.character.setLinearVelocity(zm.vecToArr3(entity_physics.velocity));
                    },
                    .CharacterVirtual => |character| {
                        character.virtual.setPosition(zm.vecToArr3(entity_transform.transform.position));
                        //character.virtual.setRotation(zm.vecToArr4(entity_transform.transform.rotation));

                        character.virtual.setLinearVelocity(zm.vecToArr3(entity_physics.velocity));
                    },
                }
            }
        }

        const body_interface = self.zphysics.system.getBodyInterface();

        // Update at UpdateRateHz, this may happen zero or more than one times before returning
        for (0..@intCast(times_to_update)) |_| {
            // Snapshot pre-step positions into last_frame_data for visual interpolation.
            components_query_iterator.reset();
            while (components_query_iterator.next()) |components| {
                const entity_transform: *eng.ecs.TransformComponent,
                _,
                const entity_physics_runtime: *eng.ecs.PhysicsRuntimeComponent = components;
                switch (entity_physics_runtime.runtime_data) {
                    .None => {},
                    .Body => |body| {
                        entity_physics_runtime.last_frame_data.position = zm.loadArr3(body_interface.getPosition(body.id));
                        entity_physics_runtime.last_frame_data.rotation = zm.loadArr4(body_interface.getRotation(body.id));
                    },
                    .Character => |character| {
                        entity_physics_runtime.last_frame_data.position = zm.loadArr3(character.character.getPosition());
                        entity_physics_runtime.last_frame_data.rotation = entity_transform.transform.rotation;
                    },
                    .CharacterVirtual => |character| {
                        entity_physics_runtime.last_frame_data.position = zm.loadArr3(character.virtual.getPosition());
                        entity_physics_runtime.last_frame_data.rotation = entity_transform.transform.rotation;
                    },
                }
            }

            // Run physics update
            self.zphysics.system.update(physics_delta_time, .{})
                catch std.log.err("Unable to update physics", .{});

            // After physics update set all entity transforms to match physics bodies

            components_query_iterator.reset();
            while (components_query_iterator.next()) |components| {
                _,
                const entity_physics: *eng.ecs.PhysicsComponent,
                const entity_physics_runtime: *eng.ecs.PhysicsRuntimeComponent = components;

                switch (entity_physics_runtime.runtime_data) {
                    .None => {}, 
                    .Body => |_| {},
                    .Character => |character| {
                        character.character.postSimulation(0.1, true);
                    },
                    .CharacterVirtual => |character| {
                        const extended_update_settings = switch (entity_physics.settings) {
                            .CharacterVirtual => |v| v.extended_update_settings,
                            else => null
                        };

                        // Run update for virtual character
                        if (extended_update_settings) |ext| {
                            character.virtual.extendedUpdate(
                                physics_delta_time,
                                self.zphysics.system.getGravity(),
                                &ext,
                                .{
                                    .body_filter = if (character.body_filter) |*b| @ptrCast(b) else null,
                                }
                            );
                        } else {
                            character.virtual.update(
                                physics_delta_time,
                                self.zphysics.system.getGravity(),
                                .{
                                    .body_filter = if (character.body_filter) |*b| @ptrCast(b) else null,
                                }
                            );
                        }

                        const new_pos = character.virtual.getPosition();

                        if (character.character) |c| {
                            c.setPosition(new_pos);
                            c.postSimulation(0.05, true);
                        }
                    },
                }
            }
        }

        // update last_update_time and last_update_time_offset
        // last_update_time_offset accounts for the portion of time between the 
        // last sub-frame physics update and the actual frame time 
        self.last_update_time = time.frame_start_time;
        self.last_update_time_offset = @mod(ns_since_last_update, UpdateRateNs);

        // update entity transforms to match updated physics
        components_query_iterator.reset();
        while (components_query_iterator.next()) |components| {
            const entity_transform: *eng.ecs.TransformComponent,
            const entity_physics: *eng.ecs.PhysicsComponent,
            const entity_physics_runtime: *eng.ecs.PhysicsRuntimeComponent = components;
            
            switch (entity_physics_runtime.runtime_data) {
                .None => {}, 
                .Body => |body| {
                    entity_transform.transform.position = zm.loadArr3(body_interface.getPosition(body.id));
                    entity_transform.transform.rotation = zm.loadArr4(body_interface.getRotation(body.id));
                    entity_physics.velocity = zm.loadArr3(body_interface.getLinearVelocity(body.id));
                },
                .Character => |character| {
                    entity_transform.transform.position = zm.loadArr3(character.character.getPosition());
                    entity_physics.velocity = zm.loadArr3(character.character.getLinearVelocity());
                },
                .CharacterVirtual => |character| {
                    entity_transform.transform.position = zm.loadArr3(character.virtual.getPosition());
                    entity_physics.velocity = zm.loadArr3(character.virtual.getLinearVelocity());
                },
            }
        }
    }
}

pub fn calculate_entity_visual_transform(self: *const Self, entity: eng.ecs.Entity) eng.Transform {
    const transform_component = eng.get().ecs.get_component(eng.ecs.TransformComponent, entity) orelse return .{};
    if (eng.get().ecs.get_component(eng.ecs.PhysicsRuntimeComponent, entity)) |physics_runtime| {
        // update positions and rotations of all entities based on current physics info
        const ns_since_last_update = eng.get().time.frame_start_time.since(self.last_update_time) + self.last_update_time_offset;
        const offset_seconds = @as(f32, @floatFromInt(ns_since_last_update)) / @as(f32, @floatFromInt(std.time.ns_per_s));

        const body_interface = self.zphysics.system.getBodyInterface();
        const pos, const rot = switch (physics_runtime.runtime_data) {
            .None => .{
                transform_component.transform.position,
                transform_component.transform.rotation,
            },
            .Body => |body| .{
                zm.loadArr3(body_interface.getPosition(body.id)),
                zm.loadArr4(body_interface.getRotation(body.id)),
            },
            .Character => |character| .{
                zm.loadArr3(character.character.getPosition()),
                transform_component.transform.rotation, // TODO add binding for jolt character GetRotation
            },
            .CharacterVirtual => |character_virtual| .{
                zm.loadArr3(character_virtual.virtual.getPosition()),
                transform_component.transform.rotation, // TODO add binding for jolt character GetRotation
            },
        };

        const t = offset_seconds / UpdateRateS;
        return eng.Transform {
            .position = zm.lerp(physics_runtime.last_frame_data.position, pos, t),
            .rotation = zm.slerp(physics_runtime.last_frame_data.rotation, rot, t),
            .scale = transform_component.transform.scale,
        };
    } else {
        return transform_component.transform;
    }
}

pub fn debug_draw_bodies(self: *Self, cmd: *eng.gfx.CommandBuffer, projection: zm.Mat, view: zm.Mat) void {
    if (debug_renderer_enabled()) {
        self.debug_renderer.draw_bodies(cmd, projection, view);
    }
}

pub fn create_shape(self: *const Self, shape: physics.Shape) !*zphy.Shape {
    _ = self;
    var shape_settings = switch (shape.shape) {
        .Capsule => |*c|
            (try zphy.CapsuleShapeSettings.create(c.half_height, c.radius)).asShapeSettings(),
        .Sphere => |*s|
            (try zphy.SphereShapeSettings.create(s.radius)).asShapeSettings(),
        .Box => |*b|
            (try zphy.BoxShapeSettings.create([3]f32{b.width / 2.0, b.height / 2.0, b.depth / 2.0})).asShapeSettings(),
        .ModelCompoundConvexHull => |m|
            (try (try eng.get().asset_manager.get_asset(eng.assets.ModelAsset, m)).gen_static_compound_physics_shape()).asShapeSettings(),
        };
    defer shape_settings.release();

    if (zm.any(shape.offset_transform.scale != zm.f32x4s(1.0), 3)) {
        const scale_shape = try zphy.DecoratedShapeSettings.createScaled(shape_settings, zm.vecToArr3(shape.offset_transform.scale));

        shape_settings.release();
        shape_settings = scale_shape.asShapeSettings();
    }

    if (zm.any(shape.offset_transform.position != zm.f32x4s(0.0), 3) or zm.any(shape.offset_transform.rotation != zm.qidentity(), 4)) {
        const decorated_shape = try zphy.DecoratedShapeSettings.createRotatedTranslated(
            shape_settings, 
            shape.offset_transform.rotation, 
            zm.vecToArr3(shape.offset_transform.position)
        );

        shape_settings.release();
        shape_settings = decorated_shape.asShapeSettings();
    }

    return try shape_settings.createShape();
}

pub const BodyReadLock = struct {
    lock_interface: *const zphy.BodyLockInterface,
    read_lock: zphy.BodyLockRead,
    body: *const zphy.Body,

    pub fn deinit(self: *BodyReadLock) void {
        self.read_lock.unlock();
    }

    pub fn init(body_id: zphy.BodyId, physics_system: *Self) !BodyReadLock {
        const lock_interface = physics_system.zphysics.system.getBodyLockInterface();

        var read_lock: zphy.BodyLockRead = .{};
        read_lock.lock(lock_interface, body_id);
        errdefer read_lock.unlock();

        if (read_lock.body) |locked_body| {
            return BodyReadLock {
                .lock_interface = lock_interface,
                .read_lock = read_lock,
                .body = locked_body,
            };
        } else {
            return error.UnableToLockBody;
        }
    }
};

pub fn init_body_read_lock(self: *Self, body_id: zphy.BodyId) !BodyReadLock {
    return BodyReadLock.init(body_id, self);
}

pub const BodyWriteLock = struct {
    lock_interface: *zphy.BodyLockInterface,
    write_lock: zphy.BodyLockWrite,
    body: *zphy.Body,

    pub fn deinit(self: *BodyWriteLock) void {
        self.write_lock.unlock();
    }

    pub fn init(body_id: zphy.BodyId, physics_system: *Self) !BodyWriteLock {
        const lock_interface = physics_system.zphysics.system.getBodyLockInterface();

        var write_lock: zphy.BodyLockWrite = .{};
        write_lock.lock(lock_interface, body_id);
        errdefer write_lock.unlock();

        if (write_lock.body) |locked_body| {
            return BodyWriteLock {
                .lock_interface = @constCast(lock_interface),
                .write_lock = write_lock,
                .body = locked_body,
            };
        } else {
            return error.UnableToLockBody;
        }
    }
};

pub fn init_body_write_lock(self: *Self, body_id: zphy.BodyId) !BodyWriteLock {
    return BodyWriteLock.init(body_id, self);
}

const UserDataStruct = packed struct(u64) {
    index: u32,
    generation: u16,
    additional_data: u16,
};

pub fn construct_entity_user_data(generational_idx: eng.util.gen.GenerationalIndex, additional_data: u16) u64 {
    const entity_user_data = UserDataStruct {
        .index = @intCast(generational_idx.index),
        .generation = generational_idx.generation,
        .additional_data = additional_data,
    };
    return @bitCast(entity_user_data);
}

pub fn extract_entity_from_user_data(user_data: u64) struct{ entity: eng.util.gen.GenerationalIndex, additional_data: u16 } {
    const entity_user_data: UserDataStruct = @bitCast(user_data);
    return .{
        .entity = eng.util.gen.GenerationalIndex {
            .index = @intCast(entity_user_data.index),
            .generation = entity_user_data.generation,
        },
        .additional_data = entity_user_data.additional_data,
    };
}

pub fn get_raycast_normal(self: *Self, position: zm.F32x4, body_id: zphy.BodyId, sub_shape_id: zphy.SubShapeId) ?zm.F32x4 {
    const lock_interface = self.zphysics.system.getBodyLockInterface();
    var lock: zphy.BodyLockRead = .{};
    lock.lock(lock_interface, body_id);
    defer lock.unlock();

    if (lock.body) |body| {
        const hit_normal = body.getWorldSpaceSurfaceNormal(sub_shape_id, zm.vecToArr3(position));
        return zm.loadArr3(hit_normal);
    }

    return null;
}

pub fn raycast(self: *const Self, ray: eng.util.Ray) ?RaycastHit {
    const zphy_ray = zphy.RRayCast {
        .origin = zm.vecToArr4(ray.origin),
        .direction = zm.vecToArr4(ray.direction),
    };
    const r = self.zphysics.system.getNarrowPhaseQuery().castRay(
        zphy_ray,
        .{}
    );
    if (!r.has_hit) return null;
    return RaycastHit.init_from_zphy(r.hit, zphy_ray);
}

pub const RaycastHit = struct {
    position: zm.F32x4,
    body_id: zphy.BodyId,
    sub_shape_id: zphy.SubShapeId,

    fn init_from_zphy(raycast_result: zphy.RayCastResult, ray: zphy.RRayCast) RaycastHit {
        return RaycastHit {
            .position = zm.loadArr4(ray.origin) + zm.loadArr4(ray.direction) * zm.f32x4s(raycast_result.fraction),
            .body_id = raycast_result.body_id,
            .sub_shape_id = raycast_result.sub_shape_id,
        };
    }

    pub inline fn get_normal(self: *const RaycastHit) ?zm.F32x4 {
        return eng.get().physics.get_raycast_normal(self.position, self.body_id, self.sub_shape_id);
    }
};
