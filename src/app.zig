const std = @import("std");
const zwin32 = @import("zwin32");
const zm = @import("zmath");
const zphy = @import("zphysics");
const w32 = zwin32.w32;
const d3d11 = zwin32.d3d11;

const engine = @import("engine.zig");
const Transform = engine.Transform;
const gfx = @import("gfx/gfx.zig");
const window = @import("window.zig");
const kc = @import("input/keycode.zig");
const cm = @import("engine/camera.zig");
const ms = @import("engine/mesh.zig");
const ent = @import("engine/entity.zig");
const ph = @import("engine/physics.zig");
const path = @import("engine/path.zig");
const particle = @import("engine/particles.zig");
const es = @import("easings.zig");
const ac = @import("engine/anim_controller.zig");

const font = @import("engine/font.zig");
const _ui = @import("engine/ui.zig");
const FontEnum = _ui.FontEnum;

const gitrev = @import("build_options").gitrev;
const gitchanged = @import("build_options").gitchanged;

const CameraStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
};

pub const Engine = engine.Engine(App);
pub const App = struct {
    const Self = @This();

    pub const EntityData = struct {
        health_points: ?i32 = null,

        pub fn deinit(self: *EntityData) void {
            _ = self;
        }
    };

    engine: *engine.Engine(Self),

    depth_stencil_view: gfx.DepthStencilView,
    depth_stencil_view_read_only_depth: gfx.DepthStencilView,

    vertex_shader: gfx.VertexShader,
    pixel_shader: gfx.PixelShader,
    
    camera_data_buffer: gfx.Buffer,
    camera: cm.Camera,
    target_old_pos: zm.F32x4 = zm.f32x4s(0.0),
    camera_idx: ent.GenerationalIndex,

    model_buffer: gfx.Buffer,
    character_idx: ent.GenerationalIndex,

    bone_matrix_buffer: gfx.Buffer,

    chara_model: *ms.Model,
    terrain_model: *ms.Model,
    cone_model: *ms.Model,

    anim_controller: ac.AnimController,

    ui: _ui.UiRenderer,
    imui: _ui.Imui,

    zero_particle_system: particle.ParticleSystem,
    player_attack_particle_system: particle.ParticleSystem,

    button_2_pos: [2]i32 = .{100,100},

    pub fn deinit(self: *Self) void {
        std.log.info("App deinit!", .{});

        self.engine.gfx.context.Flush();
        self.ui.deinit();
        self.imui.deinit();
        self.zero_particle_system.deinit();
        self.player_attack_particle_system.deinit();

        self.cone_model.deinit();
        self.engine.general_allocator.allocator().destroy(self.cone_model);
        self.chara_model.deinit();
        self.engine.general_allocator.allocator().destroy(self.chara_model);
        self.terrain_model.deinit();
        self.engine.general_allocator.allocator().destroy(self.terrain_model);
        self.anim_controller.deinit();

        self.bone_matrix_buffer.deinit();
        self.camera_data_buffer.deinit();
        self.model_buffer.deinit();

        self.depth_stencil_view.deinit();
        self.depth_stencil_view_read_only_depth.deinit();

        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
    }

    pub fn init(eng: *engine.Engine(Self)) !Self {
        std.log.info("App init!", .{});
        eng.time.set_target_frame_rate(140.0);

        var depth_struct = try create_depth_stencil_view(eng);
        errdefer { depth_struct.view.deinit(); depth_struct.view_read_only.deinit(); }

        const vertex_shader = try gfx.VertexShader.init_file(
            eng.general_allocator.allocator(), 
            path.Path{.ExeRelative = "../../src/shader.hlsl"}, 
            "vs_main",
            ([_]gfx.VertexInputLayoutEntry {
                .{ .name = "POS",                   .format = .F32x3,   .per = .Vertex, .slot = 0, },
                .{ .name = "NORMAL",                .format = .F32x3,   .per = .Vertex, .slot = 1, },
                .{ .name = "TEXCOORD",  .index = 0, .format = .F32x2,   .per = .Vertex, .slot = 2, },
                .{ .name = "TEXCOORD",  .index = 1, .format = .I32x4,   .per = .Vertex, .slot = 3, },
                .{ .name = "TEXCOORD",  .index = 2, .format = .F32x4,   .per = .Vertex, .slot = 4, },
            })[0..],
            &eng.gfx
        );
        errdefer vertex_shader.deinit();

        const pixel_shader = try gfx.PixelShader.init_file(
            eng.general_allocator.allocator(), 
            path.Path{.ExeRelative = "../../src/shader.hlsl"}, 
            "ps_main",
            &eng.gfx
        );
        errdefer pixel_shader.deinit();

        // Create camera constant buffer
        const camera_constant_buffer = try gfx.Buffer.init(
            @sizeOf(CameraStruct),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            &eng.gfx
        );
        errdefer camera_constant_buffer.deinit();

        // Create the camera entity
        const camera_transform_idx = try eng.entities.insert(.{});
        (try eng.entities.get(camera_transform_idx)).transform.position = zm.f32x4(0.0, 1.0, -1.0, 0.0);

        // Create bone matrix constant buffer
        const bone_matrix_buffer = try gfx.Buffer.init(
            @sizeOf(zm.Mat) * ms.MAX_BONES,
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            &eng.gfx
        );
        errdefer bone_matrix_buffer.deinit();

        // Load model
        const chara_model = try eng.general_allocator.allocator().create(ms.Model);
        errdefer eng.general_allocator.allocator().destroy(chara_model);
        chara_model.* = try ms.Model.init_from_file_assimp(
            eng.general_allocator.allocator(), 
            path.Path{.ExeRelative = "../../res/SK_Character_Dummy_Male_01_anim2.glb"},
            &eng.gfx
        );
        errdefer chara_model.deinit();

        // var terrain_model = try ms.Model.init_from_file_assimp(
        //      eng.general_allocator.allocator(),
        //      path.Path{.ExeRelative = "../../res/Demonstration.glb"},
        //      eng.gfx.device
        // );
        // errdefer terrain_model.deinit();
        const terrain_model = try eng.general_allocator.allocator().create(ms.Model);
        errdefer eng.general_allocator.allocator().destroy(terrain_model);
        terrain_model.* = try ms.Model.plane(
            eng.general_allocator.allocator(),
            1, 1,
            &eng.gfx
        );
        errdefer terrain_model.deinit();

        const cone_model = try eng.general_allocator.allocator().create(ms.Model);
        errdefer eng.general_allocator.allocator().destroy(cone_model);
        cone_model.* = try ms.Model.cone(
            eng.general_allocator.allocator(), 
            8, 
            &eng.gfx
        );
        errdefer cone_model.deinit();

        var anim_controller = try ac.AnimController.init(eng.general_allocator.allocator());
        errdefer anim_controller.deinit();

        // Use the model as a 'prefab' of sorts and create a number of entities from its nodes
        const demo_compound_shape_settings = try terrain_model.gen_static_compound_physics_shape();
        defer demo_compound_shape_settings.release();

        const scaled_demo_shape = try zphy.DecoratedShapeSettings.createScaled(demo_compound_shape_settings.asShapeSettings(), [3]f32{100.0, 1.0, 100.0});
        defer scaled_demo_shape.release();

        const demo_compound_shape = try scaled_demo_shape.createShape();
        defer demo_compound_shape.release();

        _ = try eng.entities.insert(Engine.EntitySuperStruct {
            .name = "ground entity",
            .model = terrain_model,
            .physics = .{ .Body = 
                try eng.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                    .position = zm.f32x4(-50.0, -5.0, 50.0, 1.0),
                    .rotation = zm.qidentity(),
                    .shape = demo_compound_shape,
                    .motion_type = .static,
                    .object_layer = ph.object_layers.non_moving,
                }, .activate)
            },
            .transform = Transform {
                .scale = zm.f32x4s(100.0),
            },
        });

        const chara_transform = Transform {
            .position = zm.f32x4(-0.5, 0.0, 0.5, 1.0),
        };

        const chara_shape_settings = try zphy.CapsuleShapeSettings.create(0.7, 0.2);
        defer chara_shape_settings.release();

        const chara_offset_shape_settings = try zphy.DecoratedShapeSettings.createRotatedTranslated(
            @ptrCast(chara_shape_settings), 
            zm.qidentity(), 
            [3]f32{0.0, chara_shape_settings.getHalfHeight() + chara_shape_settings.getRadius(), 0.0}
        );
        defer chara_offset_shape_settings.release();

        const chara_shape = try chara_offset_shape_settings.createShape();
        defer chara_shape.release();

        const chara_smaller_settings = try zphy.DecoratedShapeSettings.createScaled(chara_offset_shape_settings.asShapeSettings(), [3]f32{0.9, 0.9, 0.9});
        defer chara_smaller_settings.release();

        const chara_smaller_offset_settings = try zphy.DecoratedShapeSettings.createRotatedTranslated(
            @ptrCast(chara_smaller_settings), 
            zm.qidentity(), 
            [3]f32{0.0, 0.1, 0.0}
        );
        defer chara_smaller_offset_settings.release();

        const chara_smaller_shape = try chara_smaller_offset_settings.createShape();
        defer chara_smaller_shape.release();

        // if (eng.physics.init_body_write_lock(chara_ent.physics..?)) |write_lock| {
        //     defer write_lock.deinit();
        //
        //     write_lock.body.getMotionPropertiesMut().setInverseMass(1.0 / 70.0);
        //     // disables rotation somehow (from jolt 3.0.1 Character.cpp line 45)
        //     write_lock.body.getMotionPropertiesMut().setInverseInertia([3]f32{0.0, 0.0, 0.0}, zm.qidentity());
        //     write_lock.body.setFriction(0.0);
        // } else |_| {}

        var zphy_character_settings = try zphy.CharacterVirtualSettings.create(); 
        defer zphy_character_settings.release();

        zphy_character_settings.base.up = [4]f32{0.0, 1.0, 0.0, 0.0};
        zphy_character_settings.base.max_slope_angle = 70.0;
        zphy_character_settings.base.shape = chara_shape;
        chara_shape.addRef();
        zphy_character_settings.character_padding = 0.02;
        //zphy_character_settings.layer = ph.object_layers.moving;
        zphy_character_settings.mass = 70.0;
        //zphy_character_settings.friction = 0.0; // will handle manually
        //zphy_character_settings.gravity_factor = 0.0; // will handle manually

        var character_settings = try zphy.CharacterSettings.create();
        defer character_settings.release();

        character_settings.base.up = [4]f32{0.0, 1.0, 0.0, 0.0};
        character_settings.base.max_slope_angle = 70.0;
        character_settings.base.shape = chara_smaller_shape;
        chara_smaller_shape.addRef();
        character_settings.layer = ph.object_layers.moving;
        character_settings.mass = 70.0;
        character_settings.friction = 1.0; // will handle manually
        character_settings.gravity_factor = 1.0; // will handle manually

        const chara_root_idx = try eng.entities.insert(Engine.EntitySuperStruct {
            .name = "character entity",
            .model = chara_model,
            .transform = chara_transform,
            .physics = .{ .CharacterVirtual = .{
                .virtual = try zphy.CharacterVirtual.create(
                    zphy_character_settings,
                    zm.vecToArr3(chara_transform.position),
                    chara_transform.rotation,
                    eng.physics.zphy
                ),
                .character = null,
                .extended_update_settings = .{},
            } },
            .app = .{
                .health_points = 100,
            },
        });
        (eng.entities.get(chara_root_idx) catch unreachable).physics.?.CharacterVirtual.character = try zphy.Character.create(
            character_settings,
            [3]f32{0.0, 0.0, 0.0},
            zm.qidentity(),
            ph.PhysicsSystem.construct_entity_user_data(chara_root_idx, 0),
            eng.physics.zphy
        );
        (eng.entities.get(chara_root_idx) catch unreachable).physics.?.CharacterVirtual.character.?.addToPhysicsSystem(.{});

        const opponent_idx = try eng.entities.insert(Engine.EntitySuperStruct {
            .name = "opponent entity",
            .model = chara_model,
            .transform = chara_transform,
            .physics = null,
            .app = .{
                .health_points = 100,
            },
        });
        (eng.entities.get(opponent_idx) catch unreachable).physics = .{ .Character = try zphy.Character.create(
            character_settings,
            [3]f32{0.0, 0.0, 0.0},
            zm.qidentity(),
            ph.PhysicsSystem.construct_entity_user_data(opponent_idx, 0),
            eng.physics.zphy
        ) };
        (eng.entities.get(opponent_idx) catch unreachable).physics.?.Character.addToPhysicsSystem(.{});

        const model_buffer = try gfx.Buffer.init(
            @sizeOf(zm.Mat),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            &eng.gfx
        );
        errdefer model_buffer.deinit();

        eng.physics.zphy.optimizeBroadPhase();

        var ui = try _ui.UiRenderer.init(eng.general_allocator.allocator(), &eng.gfx);
        errdefer ui.deinit();

        var imui = try _ui.Imui.init(eng.general_allocator.allocator(), &eng.input, &eng.time, &eng.gfx);
        errdefer imui.deinit();

        var zero_particle_system = try particle.ParticleSystem.init(
            eng.general_allocator.allocator(),
            2000,
            .{
                .alignment = .{ .VelocityAligned = 200.0 },
                .shape = .Circle,
                .spawn_origin = zm.f32x4(0.0, -4.0, 0.0, 0.0),
                .spawn_offset = zm.f32x4s(0.0),
                .spawn_radius = 1.0,
                .spawn_rate = 0.01,
                .spawn_rate_variance = 0.01,
                .burst_count = 1,
                .particle_lifetime = 10.0,
                .initial_velocity = zm.f32x4(0.0, 0.0, 0.0, 0.0),
                .scale = .{
                    .{ .value = zm.f32x4s(0.03), .key_time = 0.0, },
                    .{ .value = zm.f32x4s(0.03), .key_time = 0.95, },
                    .{ .value = zm.f32x4s(0.0), .key_time = 1.0, },
                    null
                },
                .colour = .{
                    .{ .value = srgb_to_rgb(zm.f32x4(90.0/255.0, 195.0/255.0, 232.0/255.0, 0.0)) * zm.f32x4(10.0, 10.0, 10.0, 1.0), .key_time = 0.0, },
                    .{ .value = srgb_to_rgb(zm.f32x4(90.0/255.0, 195.0/255.0, 232.0/255.0, 1.0)) * zm.f32x4(10.0, 10.0, 10.0, 1.0), .key_time = 0.05, },
                    null,
                    null,
                },
                .forces = .{
                    //.{ .Constant = zm.f32x4(0.0, -9.8, 0.0, 0.0) },
                    .{ .Curl = 0.05 },
                    .{ .Drag = 1.0 },
                    .{ .Vortex = .{ .axis = zm.f32x4(1.0, 0.0, 0.0, 0.0), .force = 1.0, .origin_pull = 0.5,  } },
                    null,
                },
            },
            &eng.gfx
        );
        errdefer zero_particle_system.deinit();

        var player_attack_particle_system = try particle.ParticleSystem.init(
            eng.general_allocator.allocator(),
            60,
            .{
                .alignment = .{ .VelocityAligned = 5.0 },
                .shape = .Circle,
                .spawn_origin = zm.f32x4(0.0, 0.0, 0.0, 0.0),
                .spawn_offset = zm.f32x4s(0.0),
                .spawn_radius = 1.0,
                .spawn_rate = 0.0,
                .spawn_rate_variance = 0.0,
                .burst_count = 60,
                .particle_lifetime = 1.0,
                .scale = .{
                    .{ .value = zm.f32x4s(0.05), },
                    null,
                    null,
                    null,
                },
                .colour = .{
                    .{ .value = srgb_to_rgb(zm.f32x4(0.0, 0.0, 0.0, 1.0)), .key_time = 0.0, },
                    .{ .value = srgb_to_rgb(zm.f32x4(0.0, 0.0, 0.0, 0.0)), .key_time = 1.0, .easing_into = .OutLinear },
                    null,
                    null,
                    // .{ .value = zm.hsvToRgb(zm.f32x4(0.0, 1.0, 1.0, 1.0)), .key_time = 0.0, },
                    // .{ .value = zm.hsvToRgb(zm.f32x4(0.5, 1.0, 1.0, 1.0)), .key_time = 0.5, },
                    // .{ .value = zm.hsvToRgb(zm.f32x4(0.999, 1.0, 1.0, 1.0)), .key_time = 1.0, },
                    // null
                },
                .forces = .{
                    .{ .Vortex = .{ .axis = zm.f32x4(0.0, 1.0, 0.0, 0.0), .force = 50.0, .origin_pull = 50.0, } },
                    .{ .Drag = 5.0 },
                    null,
                    null,
                },
            },
            &eng.gfx
        );
        errdefer player_attack_particle_system.deinit();

        return Self {
            .engine = eng,
            .depth_stencil_view = depth_struct.view,
            .depth_stencil_view_read_only_depth = depth_struct.view_read_only,
            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,

            .camera_data_buffer = camera_constant_buffer,
            .camera = cm.Camera {
                .field_of_view_y = 20.0,
                .near_field = 0.3,
                .far_field = 1000.0,
                .move_speed = 2.0,
                .mouse_sensitivity = 0.001,
                .max_orbit_distance = 10.0,
                .min_orbit_distance = 1.0,
                .orbit_distance = 5.0,
            },
            .camera_idx = camera_transform_idx,

            .character_idx = chara_root_idx,
            .model_buffer = model_buffer,

            .bone_matrix_buffer = bone_matrix_buffer,

            .chara_model = chara_model,
            .terrain_model = terrain_model,
            .cone_model = cone_model,
            .anim_controller = anim_controller,

            .ui = ui,
            .imui = imui,
            .zero_particle_system = zero_particle_system,
            .player_attack_particle_system = player_attack_particle_system,
        };
    }

    inline fn srgb_to_rgb(srgb: zm.F32x4) zm.F32x4 {
        return zm.f32x4(
            std.math.pow(f32, srgb[0], 2.2), 
            std.math.pow(f32, srgb[1], 2.2), 
            std.math.pow(f32, srgb[2], 2.2), 
            srgb[3]
        );
    }

    fn vecAngle(v0: zm.F32x4, v1: zm.F32x4) f32 {
        const angle = std.math.acos(zm.dot3(v0, v1)[0] / (zm.length3(v0)[0] * zm.length3(v1)[0]));
        if (std.math.isNan(angle)) {
            return 0.0;
        }
        return angle;
    }

    fn vecProject(v0: zm.F32x4, v1: zm.F32x4) f32 {
        return zm.length3(v0)[0] * std.math.cos(vecAngle(v0, v1));
    }

    fn forward_vector_2d(transform: *const Transform) zm.F32x4 {
        var forward_direction = transform.forward_direction();
        forward_direction[1] = 0.0;
        return zm.normalize3(forward_direction);
    }

    fn update(self: *Self) void {
        // Input to move the model around
        if (self.engine.entities.get(self.character_idx)) |character_entity| {
            var movement_direction = zm.f32x4s(0.0);
            if (self.engine.input.get_key(kc.KeyCode.W)) {
                movement_direction[2] += 1.0;
            }
            if (self.engine.input.get_key(kc.KeyCode.S)) {
                movement_direction[2] -= 1.0;
            }
            if (self.engine.input.get_key(kc.KeyCode.D)) {
                movement_direction[0] += 1.0;
            }
            if (self.engine.input.get_key(kc.KeyCode.A)) {
                movement_direction[0] -= 1.0;
            }

            const camera_right = self.camera.right_direction();
            const camera_forward_no_pitch = zm.cross3(camera_right, zm.f32x4(0.0, 1.0, 0.0, 0.0));

            movement_direction = 
                camera_forward_no_pitch * zm.f32x4s(movement_direction[2])
                + camera_right * zm.f32x4s(movement_direction[0]);

            if (@reduce(.Add, @abs(movement_direction)) != 0.0) {
                movement_direction = zm.normalize3(movement_direction);
            }

            const character = character_entity.physics.?.CharacterVirtual.virtual;
            var current_movement = zm.loadArr3(character.getLinearVelocity());

            var current_movement_direction = current_movement;
            current_movement_direction[1] = 0.0;

            if (character_is_supported(character)) {
                // remove any gravity
                current_movement[1] = 0.0;

                const character_movement_speed = 8.0;
                const ramp_speed = 10.0;

                // apply supported movement
                current_movement += movement_direction * 
                    zm.f32x4s(character_movement_speed * ramp_speed * self.engine.time.delta_time_f32());

                // apply friction
                current_movement -=
                    current_movement_direction * zm.f32x4s(ramp_speed * self.engine.time.delta_time_f32());
            } else {
                // if not supported then apply gravity
                current_movement = current_movement
                    + zm.loadArr3(self.engine.physics.zphy.getGravity()) * zm.f32x4s(self.engine.time.delta_time_f32());
            }

            character.setLinearVelocity(zm.vecToArr3(current_movement));

            // Rotate character model to match the input desired direction
            // If no input desired direction (normalized to nan) then remain in last rotation
            const dir = zm.normalize3(movement_direction);
            if (!std.math.isNan(dir[0])) {
                const rot = zm.lookAtRh(zm.f32x4s(0.0), dir * zm.f32x4(1.0, 1.0, -1.0, 0.0), zm.f32x4(0.0, 1.0, 0.0, 0.0));
                character.setRotation(
                    zm.slerp(character_entity.transform.rotation, zm.matToQuat(rot), self.engine.time.delta_time_f32() * 15.0)
                );
            }

            if (self.engine.input.get_key_down(kc.KeyCode.MouseLeft)) {
                var collector = CollideShapeCollector.init(self.engine.general_allocator.allocator());
                defer collector.deinit();

                const box_shape_settings = zphy.BoxShapeSettings.create([3]f32{0.5, 0.5, 0.5}) catch unreachable;
                defer box_shape_settings.release();

                const box_shape = box_shape_settings.createShape() catch unreachable;
                defer box_shape.release();

                var camera_forward_2d = self.camera.forward_direction();
                camera_forward_2d[1] = 0.0;
                camera_forward_2d = zm.normalize3(camera_forward_2d);

                const shape_position = character_entity.transform.position + zm.f32x4(0.0, 0.6, 0.0, 0.0) + (camera_forward_2d);
                
                const matrix = zm.matToArr((Transform {
                        .position = shape_position
                    }).generate_model_matrix());

                // particles!
                self.player_attack_particle_system.settings.spawn_origin = shape_position;
                self.player_attack_particle_system.settings.spawn_offset = camera_right;
                self.player_attack_particle_system.settings.initial_velocity = zm.f32x4s(0.0); //camera_forward_2d * zm.f32x4s(10.0);
                self.player_attack_particle_system.emit_particle_burst();

                self.engine.physics.zphy.getNarrowPhaseQuery().collideShape(
                    box_shape,
                    [3]f32{1.0, 1.0, 1.0},
                    matrix,
                    [3]zphy.Real{0.0, 0.0, 0.0},
                    @ptrCast(&collector),
                    .{}
                );

                std.log.info("hits: {}", .{collector.hits.items.len});
                for (collector.hits.items) |hit| {
                    var read_lock = self.engine.physics.init_body_read_lock(hit.body2_id) catch unreachable;
                    defer read_lock.deinit();

                    const user_data = ph.PhysicsSystem.extract_entity_from_user_data(read_lock.body.getUserData());
                    if (self.engine.entities.get(user_data.entity)) |entity| {
                        const unnamed_name = "unnamed";
                        var entity_name: []const u8 = unnamed_name;
                        if (entity.name) |name| {
                            std.log.info("- {s}", .{name});
                            entity_name = name;
                        } else {
                            std.log.info("- unnamed", .{});
                        }

                        if (entity.app.health_points) |*hp| {
                            hp.* -= 10;
                            if (hp.* < 0) {
                                std.log.info("'{s}' fainted!", .{entity_name});
                            }
                        }
                    } else |e| { std.log.warn("{}", .{e}); }
                }
            }
        } else |_| {}

        // // Cast ray from camera
        // if (self.engine.entities.get(self.camera_idx)) |camera_entity| {
        //     var raycast_result = self.engine.physics.zphy.getNarrowPhaseQuery().castRay(.{
        //         .origin = camera_entity.transform.position,
        //         .direction = camera_entity.transform.forward_direction(),
        //     }, .{});
        //     if (raycast_result.has_hit) {
        //         std.log.info("  raycast hit! id:{}", .{raycast_result.hit.body_id});
        //     }
        // } else |_| {}

        // Update physics. If frame time is greater than 1 second then skip physics for this frame.
        // @TODO: It is most likely we loaded something in and caused a spike... Fix this permanently 
        // by adding async loads and/or loading screens.

        // Camera input and buffer data management
        if (self.engine.entities.get(self.camera_idx)) |camera_entity| {
        if (self.engine.entities.get(self.character_idx)) |character_entity| {
            self.target_old_pos = zm.lerpVOverTime(
                self.target_old_pos,
                character_entity.transform.position + zm.f32x4(0.0, 1.5, 0.0, 0.0),
                zm.f32x4s(10.0),
                zm.f32x4s(self.engine.time.delta_time_f32())
            );
            self.camera.update(&camera_entity.transform, self.target_old_pos, self.engine);

            { // Update camera buffer
                const mapped_buffer = self.camera_data_buffer.map(CameraStruct, &self.engine.gfx) catch unreachable;
                defer mapped_buffer.unmap();

                mapped_buffer.data.view = self.camera.view_matrix;
                mapped_buffer.data.projection = self.camera.generate_perspective_matrix(self.engine.gfx.swapchain_aspect());
            }

            const bone_transforms = self.anim_controller.calculate_bone_transforms(
                character_entity.model.?,
                &character_entity.model.?.animations[0],
                .{
                    .animation_1 = &character_entity.model.?.animations[1],
                    .lerp_amount = 1.0,
                },
                &self.engine.time
            );

            { // Update bone matrix buffer
                const mapped_buffer = self.bone_matrix_buffer.map([ms.MAX_BONES]zm.Mat, &self.engine.gfx) catch unreachable;
                defer mapped_buffer.unmap();

                @memcpy(mapped_buffer.data.*[0..], bone_transforms[0..]);
            }
        } else |_| {}
        } else |_| {}

        // Draw frame
        var rtv = self.engine.gfx.begin_frame() catch |err| {
            std.log.err("unable to begin frame: {}", .{err});
            return;
        };
        self.engine.gfx.context.ClearRenderTargetView(rtv.view, &zm.vecToArr4(srgb_to_rgb(zm.f32x4(
            135.0/255.0, 
            206.0/255.0, 
            235.0/255.0, 
            1.0
        ))));
        self.engine.gfx.context.ClearDepthStencilView(self.depth_stencil_view.view, d3d11.CLEAR_FLAG {.CLEAR_DEPTH = true,}, 1, 0);

        const viewport = d3d11.VIEWPORT {
            .Width = @floatFromInt(self.engine.gfx.swapchain_size.width),
            .Height = @floatFromInt(self.engine.gfx.swapchain_size.height),
            .TopLeftX = 0,
            .TopLeftY = 0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        self.engine.gfx.context.RSSetViewports(1, @ptrCast(&viewport));

        self.engine.gfx.context.PSSetShader(self.pixel_shader.pso, null, 0);

        self.engine.gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv.view), self.depth_stencil_view.view);
        self.engine.gfx.context.OMSetBlendState(null, null, 0xffffffff);

        self.engine.gfx.context.VSSetShader(self.vertex_shader.vso, null, 0);
        self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_data_buffer.buffer));
        self.engine.gfx.context.VSSetConstantBuffers(2, 1, @ptrCast(&self.bone_matrix_buffer.buffer));

        self.engine.gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        self.engine.gfx.context.IASetInputLayout(self.vertex_shader.layout);

        // Iterate through all entities finding those which contain a mesh to be rendered
        for (self.engine.entities.data.items) |*it| {
            if (it.item_data) |*entity| {
                // Find the transform of the entity to be rendered taking into account it's parent
                if (entity.model) |m| {
                    const strides = [_]zwin32.w32.UINT{
                        @truncate(m.buffers.strides.positions),
                        @truncate(m.buffers.strides.normals),
                        @truncate(m.buffers.strides.texcoords),
                        @truncate(m.buffers.strides.bone_ids),
                        @truncate(m.buffers.strides.bone_weights),
                    };
                    const offsets = [_]zwin32.w32.UINT{
                        @truncate(m.buffers.offsets.positions),
                        @truncate(m.buffers.offsets.normals),
                        @truncate(m.buffers.offsets.texcoords),
                        @truncate(m.buffers.offsets.bone_ids),
                        @truncate(m.buffers.offsets.bone_weights),
                    };
                    self.engine.gfx.context.IASetVertexBuffers(0, 1, @ptrCast(&m.buffers.vertices.buffer), @ptrCast(&strides[0]), @ptrCast(&offsets[0]));
                    self.engine.gfx.context.IASetVertexBuffers(1, 1, @ptrCast(&m.buffers.vertices.buffer), @ptrCast(&strides[1]), @ptrCast(&offsets[1]));
                    self.engine.gfx.context.IASetVertexBuffers(2, 1, @ptrCast(&m.buffers.vertices.buffer), @ptrCast(&strides[2]), @ptrCast(&offsets[2]));
                    self.engine.gfx.context.IASetVertexBuffers(3, 1, @ptrCast(&m.buffers.vertices.buffer), @ptrCast(&strides[3]), @ptrCast(&offsets[3]));
                    self.engine.gfx.context.IASetVertexBuffers(4, 1, @ptrCast(&m.buffers.vertices.buffer), @ptrCast(&strides[4]), @ptrCast(&offsets[4]));

                    self.engine.gfx.context.IASetIndexBuffer(m.buffers.indices.buffer, zwin32.dxgi.FORMAT.R32_UINT, 0);
                    // Set model constant buffer
                    self.engine.gfx.context.VSSetConstantBuffers(1, 1, @ptrCast(&self.model_buffer.buffer));

                    // Finally, render the model
                    self.recursive_render_model(m, &m.nodes_list[m.root_nodes[0]], entity.transform.generate_model_matrix());
                }
            }
        }

        self.zero_particle_system.update(&self.engine.time);
        self.zero_particle_system.draw(
            self.camera.view_matrix, 
            self.camera.generate_perspective_matrix(self.engine.gfx.swapchain_aspect()), 
            &rtv,
            &self.depth_stencil_view_read_only_depth,
            &self.engine.gfx
        );

        self.player_attack_particle_system.update(&self.engine.time);
        self.player_attack_particle_system.draw(
            self.camera.view_matrix, 
            self.camera.generate_perspective_matrix(self.engine.gfx.swapchain_aspect()), 
            &rtv,
            &self.depth_stencil_view_read_only_depth,
            &self.engine.gfx
        );

        // find bone transforms for chara
        //
        // if (self.engine.entities.get(self.character_idx)) |chara| {
        //     self.engine.gfx.context.ClearDepthStencilView(self.depth_stencil_view, d3d11.CLEAR_FLAG {.CLEAR_DEPTH = true,}, 1, 0);
        //
        //     const pos_stride: c_uint = @sizeOf(f32) * 3;
        //     const tex_coord_stride: c_uint = @sizeOf(f32) * 2;
        //     const bone_id_stride: c_uint = @sizeOf([4]i32);
        //     const bone_weight_stride: c_uint = @sizeOf([4]f32);
        //     const offset: c_uint = 0;
        //     self.engine.gfx.context.IASetVertexBuffers(0, 1, @ptrCast(&self.cone_model.buffers.positions), @ptrCast(&pos_stride), @ptrCast(&offset));
        //     self.engine.gfx.context.IASetVertexBuffers(1, 1, @ptrCast(&self.cone_model.buffers.normals), @ptrCast(&pos_stride), @ptrCast(&offset));
        //     self.engine.gfx.context.IASetVertexBuffers(2, 1, @ptrCast(&self.cone_model.buffers.tex_coords), @ptrCast(&tex_coord_stride), @ptrCast(&offset));
        //     self.engine.gfx.context.IASetVertexBuffers(3, 1, @ptrCast(&self.cone_model.buffers.bone_ids), @ptrCast(&bone_id_stride), @ptrCast(&offset));
        //     self.engine.gfx.context.IASetVertexBuffers(4, 1, @ptrCast(&self.cone_model.buffers.bone_weights), @ptrCast(&bone_weight_stride), @ptrCast(&offset));
        //     self.engine.gfx.context.IASetIndexBuffer(self.cone_model.buffers.indices, zwin32.dxgi.FORMAT.R32_UINT, 0);
        //
        //     // Set model constant buffer
        //     self.engine.gfx.context.VSSetConstantBuffers(1, 1, @ptrCast(&self.model_buffer));
        //
        //     self.render_model_bones(
        //         &self.cone_model, 
        //         &(Transform {
        //             .scale = zm.f32x4(0.05, 0.2, 0.05, 0.0),
        //             //.rotation = zm.quatFromRollPitchYaw(std.math.degreesToRadians(f32, 90.0), 0.0, 0.0),
        //         }).generate_model_matrix(),
        //         chara.model.?, 
        //         chara.transform.generate_model_matrix(),
        //     );
        // } else |_| {}

        // Draw Physics Debug Wireframes
        if (self.engine.input.get_key(kc.KeyCode.C)) {
            if (self.engine.entities.get(self.camera_idx)) |camera_entity| {
                _ = camera_entity;
                self.engine.physics._interfaces.debug_renderer.draw_bodies(
                    self.engine.physics.zphy, 
                    rtv.view, 
                    self.engine.gfx.swapchain_size.width,
                    self.engine.gfx.swapchain_size.height,
                    zm.matToArr(self.camera.generate_perspective_matrix(self.engine.gfx.swapchain_aspect())),
                    zm.matToArr(self.camera.view_matrix),
                );
            } else |_| {}
        }

        self.render_text_over_quad(
            FontEnum.GeistMono,
            "Hello World.\nThis is the next line.",
            .{
                .position = .{ .x = 100, .y = 100, },
                .pixel_height = 15,
            }, 
            .{
                .colour = zm.f32x4(0.0, 0.0, 0.0, 1.0),
                .border_colour = zm.f32x4(1.0, 0.0, 0.0, 1.0),
                .corner_radii_px = .{},
            },
            rtv,
        );

        if (self.engine.entities.get(self.character_idx)) |character_entity| {
            const character = character_entity.physics.?.CharacterVirtual.virtual;
            const character_velocity = zm.loadArr3(character.getLinearVelocity());
            const vel_text = std.fmt.allocPrint(self.engine.general_allocator.allocator(), "character speed: {d:.2}\nvelocity: {d:.2}\nis supported: {}", .{
                zm.length3(character_velocity)[0],
                character_velocity,
                character_is_supported((self.engine.entities.get(self.character_idx) catch unreachable).physics.?.CharacterVirtual.virtual),
            }) catch unreachable;
            defer self.engine.general_allocator.allocator().free(vel_text);

            self.ui.render_text_2d(
                FontEnum.GeistMono,
                vel_text, 
                .{
                    .position = .{ .x = 100, .y = 500, },
                    .pixel_height = 15,
                }, 
                rtv, 
                &self.engine.gfx
            );
        } else |_| {}

        const top_layout = self.imui.push_floating_layout(.X, 500, 500);
        if (self.imui.get_widget(top_layout)) |top_widget| {
            top_widget.flags.render = true;
            top_widget.background_colour = zm.f32x4(1.0, 1.0, 1.0, 1.0);
            top_widget.border_colour = zm.f32x4(0.5, 0.5, 0.5, 1.0);
            top_widget.border_width_px = 2;
            top_widget.padding_px = .{
                .left = 10,
                .right = 10,
                .top = 10,
                .bottom = 10,
            };
            top_widget.corner_radii_px = .{
                .top_left = 10,
                .top_right = 10,
                .bottom_left = 10,
                .bottom_right = 10,
            };
            top_widget.children_gap = 20.0;
        }

        const labels_layout = self.imui.push_layout(.Y);
        self.imui.get_widget(labels_layout).?.children_gap = 5.0;
        self.imui.pop_layout();
        const buttons_layout = self.imui.push_layout(.Y);
        self.imui.get_widget(buttons_layout).?.children_gap = 5.0;
        self.imui.pop_layout();
        self.imui.push_layout_id(labels_layout);
        self.imui.label("Option 1:");
        self.imui.pop_layout();
        self.imui.push_layout_id(buttons_layout);
        _ = self.imui.button("Option 1 button", 1);
        self.imui.pop_layout();
        self.imui.push_layout_id(labels_layout);
        self.imui.label("Option 2 longlonglong:");
        self.imui.pop_layout();
        self.imui.push_layout_id(buttons_layout);
        _ = self.imui.button("Option 2 button", 2);
        self.imui.pop_layout();
        self.imui.push_layout_id(labels_layout);
        self.imui.label("Option 3:");
        self.imui.pop_layout();
        self.imui.push_layout_id(buttons_layout);
        _ = self.imui.button("Option 3 button longlonglong", 3);
        self.imui.pop_layout();
        self.imui.pop_layout();

        var fps_buf: [128]u8 = [_]u8{0} ** 128;
        const fps_text = std.fmt.bufPrint(fps_buf[0..], "fps: {d:0.1}\nframe time: {d:2.3}ms\nwait time: {d:2.3}ms\nwait %: {d:0.0}", .{
            self.engine.time.get_fps(),
            (self.engine.time.delta_time_f32() - self.engine.time.last_frame_wait_time_s) * std.time.ms_per_s,
            self.engine.time.last_frame_wait_time_s * std.time.ms_per_s,
            (self.engine.time.last_frame_wait_time_s / self.engine.time.last_frame_time_s) * 100.0
        }) catch unreachable;

        self.ui.render_text_2d(
            FontEnum.GeistMono,
            fps_text, 
            .{
                .position = .{
                    .x = 10,
                    .y = 
                        @as(i32, @intFromFloat(self.ui.fonts[@intFromEnum(FontEnum.GeistMono)].font_metrics.line_height * 12.0)),
                },
                .pixel_height = 12,
            }, 
            rtv, 
            &self.engine.gfx
        );

        var rev_buf: [64]u8 = [_]u8{0} ** 64;
        const rev_text = std.fmt.bufPrint(rev_buf[0..], "zig-dx11 - {x}{s}", .{
            gitrev,
            blk: { if (gitchanged) { break :blk "*"; } else { break :blk ""; } },
        }) catch unreachable;
        self.ui.render_text_2d(
            FontEnum.GeistMono,
            rev_text, 
            .{
                .position = .{
                    .x = 10,
                    .y = self.engine.gfx.swapchain_size.height -
                        @as(i32, @intFromFloat(self.ui.fonts[@intFromEnum(FontEnum.GeistMono)].font_metrics.descender * 12.0)),
                },
                .pixel_height = 12,
            }, 
            rtv, 
            &self.engine.gfx
        );

        self.imui.compute_widget_rects();
        self.imui.render_imui(&rtv, &self.engine.gfx);
        self.imui.end_frame(&self.engine.gfx);

        self.engine.gfx.end_frame(rtv) catch |err| {
            std.log.err("unable to end frame: {}", .{err});
            return;
        };
        return;
    }

    pub fn recursive_render_model(self: *Self, model: *const ms.Model, model_node: *const ms.ModelNode, mat: zm.Mat) void {
        const node_model_matrix = zm.mul(model_node.transform.generate_model_matrix(), mat);

        if (model_node.mesh) |*mesh_set| {
            { // Setup model buffer from transform
                const mapped_buffer = self.model_buffer.map(zm.Mat, &self.engine.gfx) catch unreachable;
                defer mapped_buffer.unmap();

                mapped_buffer.data.* = node_model_matrix;
            }

            for (mesh_set.primitives) |maybe_prim| {
                if (maybe_prim) |prim_idx| {
                    const p = &model.mesh_list[prim_idx];

                    if (p.material_descriptor.double_sided) {
                        self.engine.gfx.context.RSSetState(self.engine.gfx.rasterization_state(
                            .{ .FillFront = true, .FillBack = true, }
                        ).state);
                    } else {
                        self.engine.gfx.context.RSSetState(self.engine.gfx.rasterization_state(
                            .{ .FillFront = true, .FillBack = false, }
                        ).state);
                    }

                    if (p.has_indices()) {
                        self.engine.gfx.context.DrawIndexed(@intCast(p.num_indices), @intCast(p.indices_offset), @intCast(p.pos_offset));
                    } else {
                        self.engine.gfx.context.Draw(@intCast(p.num_vertices), @intCast(p.pos_offset));
                    }
                }
            }
        }

        for (model_node.children) |c| {
            self.recursive_render_model(model, &model.nodes_list[c], node_model_matrix);
        }
    }

    pub fn render_model_bones(
        self: *Self, 
        render_model: *const ms.Model, 
        render_model_transform: *const zm.Mat, 
        model: *const ms.Model, 
        mat: zm.Mat,
    ) void {
        const global_transform = zm.inverse(model.global_inverse_transform);
        for (model.nodes_list) |*node| {
            if (node.name) |node_name| {
                if (model.bone_mapping.get(node_name)) |bone_id| {
                    const bone_data = &model.bone_info.items[@intCast(bone_id)];

                    const node_model_matrix_transformed = 
                        zm.mul(
                            zm.inverse(bone_data.bone_offset), 
                            zm.mul(
                                bone_data.final_transform, 
                                zm.mul(global_transform, mat)
                            )
                        );

                    self.recursive_render_model(
                        render_model, 
                        &render_model.nodes_list[render_model.root_nodes[0]], 
                        zm.mul(render_model_transform.*, node_model_matrix_transformed)
                    );
                }
            }
        }
    }

    pub fn create_depth_stencil_view(eng: *engine.Engine(Self)) !struct{view: gfx.DepthStencilView, view_read_only: gfx.DepthStencilView} {
        const depth_texture = try gfx.Texture2D.init(
            gfx.Texture2D.Descriptor {
                .width = @intCast(eng.gfx.swapchain_size.width),
                .height = @intCast(eng.gfx.swapchain_size.height),
                .format = .D24S8_Unorm_Uint,
            },
            .{ .DepthStencil = true, },
            .{ .GpuWrite = true, },
            null,
            &eng.gfx
        );
        defer depth_texture.deinit();

        const view = try gfx.DepthStencilView.init_from_texture2d(&depth_texture, .{}, &eng.gfx);
        const view_read_only = try gfx.DepthStencilView.init_from_texture2d(&depth_texture, .{ .read_only_depth = true, }, &eng.gfx);
        return .{ .view = view, .view_read_only = view_read_only, };
    }
    
    pub fn window_event_received(self: *Self, event: *const window.WindowEvent) void {
        switch (event.*) {
            .EVENTS_CLEARED => { self.update(); },
            .RESIZED => |new_size| {
                if (new_size.width > 0 and new_size.height > 0) {
                    self.depth_stencil_view.deinit();
                    self.depth_stencil_view_read_only_depth.deinit();
                    const d = create_depth_stencil_view(self.engine) catch unreachable;
                    self.depth_stencil_view = d.view;
                    self.depth_stencil_view_read_only_depth = d.view_read_only;
                }
            },
            else => {},
        }
    }

    fn render_text_over_quad(
        self: *Self,
        font_: _ui.FontEnum,
        text: []const u8,
        text_props: font.Font.FontRenderProperties2D,
        quad_props: _ui.QuadRenderer.QuadProperties,
        rtv: gfx.RenderTargetView,
    ) void {
        const text_bounds = self.ui.get_font(font_).text_bounds_2d_pixels(text, text_props.pixel_height);
        self.ui.quad_renderer.render_quad(
            text_bounds.translate(text_props.position.x, text_props.position.y),
            quad_props,
            rtv,
            &self.engine.gfx
        );
        self.ui.render_text_2d(
            font_,
            text,
            text_props,
            rtv,
            &self.engine.gfx
        );
    }

    fn character_is_supported(chr: *zphy.CharacterVirtual) bool {
        return chr.getGroundState() == zphy.CharacterGroundState.on_ground;
    }
};

const CollideShapeCollector = extern struct {
    usingnamespace zphy.CollideShapeCollector.Methods(@This());
    __v: *const zphy.CollideShapeCollector.VTable = &vtable,

    hits: *std.ArrayList(zphy.CollideShapeResult),

    const vtable = zphy.CollideShapeCollector.VTable{ 
        .reset = _Reset,
        .onBody = _OnBody,
        .addHit = _AddHit,
    };

    fn _Reset(
        self: *zphy.CollideShapeCollector,
    ) callconv(.C) void { 
        _ = self;
    }
    fn _OnBody(
        self: *zphy.CollideShapeCollector,
        in_body: *const zphy.Body,
    ) callconv(.C) void { 
        _ = self;
        _ = in_body;
    }
    fn _AddHit(
        self: *zphy.CollideShapeCollector,
        collide_shape_result: *const zphy.CollideShapeResult,
    ) callconv(.C) void {
        @as(*CollideShapeCollector, @ptrCast(self)).hits.append(collide_shape_result.*) catch unreachable;
    }

    pub fn deinit(self: *CollideShapeCollector) void {
        self.hits.deinit();
        self.hits.allocator.destroy(self.hits);
    }

    pub fn init(alloc: std.mem.Allocator) CollideShapeCollector {
        const hits = alloc.create(std.ArrayList(zphy.CollideShapeResult)) catch unreachable;
        hits.* = std.ArrayList(zphy.CollideShapeResult).init(alloc);
        return CollideShapeCollector {
            .hits = hits,
        };
    }
};

fn custom_easing(_: f32) f32 {
    return 1.0;
}
