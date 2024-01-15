const std = @import("std");
const zwin32 = @import("zwin32");
const zm = @import("zmath");
const zphy = @import("zphysics");
const w32 = zwin32.w32;
const d3d11 = zwin32.d3d11;

const engine = @import("engine.zig");
const Transform = engine.Transform;
const window = @import("window.zig");
const kc = @import("input/keycode.zig");
const cm = @import("engine/camera.zig");
const ms = @import("engine/mesh.zig");
const ent = @import("engine/entity.zig");
const ph = @import("engine/physics.zig");
const path = @import("engine/path.zig");
const es = @import("easings.zig");

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
        chara_data: ?struct {
            character_shape: *zphy.Shape,
            character_physics: *zphy.CharacterVirtual,
        } = null,

        pub fn deinit(self: *EntityData) void {
            if (self.chara_data) |*c| {
                c.character_physics.destroy();
                c.character_shape.release();
            }
        }
    };

    const triangle_vertices: [3 * 3]zwin32.w32.FLOAT = [_]zwin32.w32.FLOAT{
        0.0, 0.5, 0.0,
        -0.5, -0.5, 0.0,
        0.5, -0.5, 0.0,
    };

    const RasterizationStates = struct {
        double_sided: *d3d11.IRasterizerState,
        cull_back_face: *d3d11.IRasterizerState,
    };

    engine: *engine.Engine(Self),

    depth_stencil_view: *d3d11.IDepthStencilView,

    vso: *d3d11.IVertexShader,
    pso: *d3d11.IPixelShader,
    vso_input_layout: *d3d11.IInputLayout,
    vertex_buffer: *d3d11.IBuffer,
    rasterizer_states: RasterizationStates,
    
    camera_data_buffer: *d3d11.IBuffer,
    camera: cm.Camera,
    camera_idx: ent.GenerationalIndex,

    model_buffer: *d3d11.IBuffer,
    model_idx: ent.GenerationalIndex,

    chara_model: ms.Model,
    tree_model: ms.Model,

    ui: _ui.UiRenderer,

    pub fn init(eng: *engine.Engine(Self)) !Self {
        std.log.info("App init!", .{});

        var depth_stencil_view: *d3d11.IDepthStencilView = try create_depth_stencil_view(eng);
        errdefer _ = depth_stencil_view.Release();

        // Load Shader file
        const shader_file_path = try (path.Path{.ExeRelative = "../../src/shader.hlsl"})
            .resolve_path(eng.general_allocator.allocator());
        defer eng.general_allocator.allocator().free(shader_file_path);

        var shader_file = try std.fs.cwd().openFile(shader_file_path, std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
        defer shader_file.close();

        const shader_file_size = try shader_file.getEndPos();

        var shader_buffer: []u8 = try std.heap.page_allocator.alloc(u8, shader_file_size);
        defer std.heap.page_allocator.free(shader_buffer);

        if (try shader_file.readAll(shader_buffer) != shader_file_size) {
            return error.FAILED_SHADER_FILE_READ;
        }
        
        // Compile VS and PS shader blobs from hlsl source
        var vs_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&shader_buffer[0], shader_file_size, null, null, null, "vs_main", "vs_5_0", 0, 0, @ptrCast(&vs_blob), null));
        defer _ = vs_blob.Release();

        var vso: *d3d11.IVertexShader = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, @ptrCast(&vso)));
        errdefer _ = vso.Release();

        var ps_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&shader_buffer[0], shader_file_size, null, null, null, "ps_main", "ps_5_0", 0, 0, @ptrCast(&ps_blob), null));
        defer _ = ps_blob.Release();

        // Create vertex and pixel shaders
        var pso: *d3d11.IPixelShader = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&pso)));
        errdefer _ = pso.Release();

        const vso_input_layout_desc = [_]d3d11.INPUT_ELEMENT_DESC {
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "POS",
                .SemanticIndex = 0,
                .Format = zwin32.dxgi.FORMAT.R32G32B32_FLOAT,
                .InputSlot = 0,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
                .InstanceDataStepRate = 0,
            },
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "NORMAL",
                .SemanticIndex = 0,
                .Format = zwin32.dxgi.FORMAT.R32G32B32_FLOAT,
                .InputSlot = 1,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
                .InstanceDataStepRate = 0,
            },
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "TEXCOORD",
                .SemanticIndex = 0,
                .Format = zwin32.dxgi.FORMAT.R32G32_FLOAT,
                .InputSlot = 2,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
                .InstanceDataStepRate = 0,
            },
        };
        var vso_input_layout: *d3d11.IInputLayout = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateInputLayout(vso_input_layout_desc[0..], vso_input_layout_desc.len, vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), @ptrCast(&vso_input_layout)));
        errdefer _ = vso_input_layout.Release();

        // Define vertex buffer input
        const vertex_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(f32) * 3 * 3,
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        var vertex_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&vertex_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = &triangle_vertices, }, @ptrCast(&vertex_buffer)));
        errdefer _ = vertex_buffer.Release();

        // Define rasterizer state
        var rasterization_states = RasterizationStates {
            .double_sided = undefined,
            .cull_back_face = undefined,
        };
        var rasterizer_state_desc = d3d11.RASTERIZER_DESC {
            .FillMode = d3d11.FILL_MODE.SOLID,
            .CullMode = d3d11.CULL_MODE.BACK,
        };
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterization_states.cull_back_face)));
        errdefer _ = rasterization_states.cull_back_face.Release();

        rasterizer_state_desc.CullMode = d3d11.CULL_MODE.NONE;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterization_states.double_sided)));
        errdefer _ = rasterization_states.double_sided.Release();

        // Create camera constant buffer
        const camera_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(CameraStruct),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var camera_data_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&camera_constant_buffer_desc, null, @ptrCast(&camera_data_buffer)));
        errdefer _ = camera_data_buffer.Release();

        // Create the camera entity
        const camera_transform_idx = try eng.entities.insert(.{});
        (try eng.entities.get(camera_transform_idx)).transform.position = zm.f32x4(0.0, 1.0, -1.0, 0.0);

        // Load model
        const chara_model = try ms.Model.init_from_file(
            eng.general_allocator.allocator(), 
            path.Path{.ExeRelative = "../../res/SK_Character_Dummy_Male_01.glb"}, 
            eng.gfx.device
        );
        const tree_model = try ms.Model.init_from_file(
            eng.general_allocator.allocator(), 
            path.Path{.ExeRelative = "../../res/Demonstration.glb"}, 
            eng.gfx.device
        );

        // Use the model as a 'prefab' of sorts and create a number of entities from its nodes
        const chara_root_idx = (try eng.create_entities_from_model(&chara_model, null)).?;
        (try eng.entities.get(chara_root_idx)).transform.position = zm.f32x4(-0.5, 0.0, 0.5, 1.0);

        var world_entities = std.ArrayList(ent.GenerationalIndex).init(eng.general_allocator.allocator());
        defer world_entities.deinit();
        _ = try eng.create_entities_from_model(&tree_model, &world_entities);

        // Add physics bodies to static world entities
        for (world_entities.items) |ent_idx| {
            const entity = try eng.entities.get(ent_idx);
            if (entity.physics_body == null) {
                if (entity.mesh) |mesh| {
                    const sc = entity.transform.scale;
                    const scaled_shape_settings = zphy.DecoratedShapeSettings.createScaled(mesh.physics_shape_settings, [3]zphy.Real{sc[0], sc[1], sc[2]})
                        catch unreachable;
                    defer scaled_shape_settings.release();

                    const shape = zphy.ShapeSettings.createShape(@ptrCast(scaled_shape_settings))
                        catch unreachable;
                    defer shape.release();

                    var body_inderface = eng.physics.zphy.getBodyInterfaceMut();
                    entity.physics_body = body_inderface.createAndAddBody(.{
                        .position = entity.transform.position,
                        .rotation = entity.transform.rotation,
                        .shape = shape,
                        .motion_type = .static,
                        .object_layer = ph.object_layers.non_moving,
                    }, .activate) catch unreachable;
                }
            }
        }

        const chara_shape_settings = try zphy.CapsuleShapeSettings.create(0.7, 0.2);
        defer chara_shape_settings.release();

        const chara_offset_shape_settings = try zphy.DecoratedShapeSettings.createRotatedTranslated(
            @ptrCast(chara_shape_settings), 
            zm.qidentity(), 
            [3]f32{0.0, chara_shape_settings.getHalfHeight() + chara_shape_settings.getRadius(), 0.0}
        );
        defer chara_offset_shape_settings.release();

        const chara_shape = try chara_offset_shape_settings.createShape();
        errdefer chara_shape.release();

        const chara_ent = (try eng.entities.get(chara_root_idx));
        // chara_ent.physics_body = try eng.physics.zphy.getBodyInterfaceMut().createAndAddBody(.{
        //     .position = chara_ent.transform.position,
        //     .rotation = chara_ent.transform.rotation,
        //     .shape = chara_shape,
        //     .motion_type = .dynamic,
        //     .motion_quality = .linear_cast,
        //     .object_layer = ph.object_layers.moving,
        // }, .activate);

        // {
        //     var lock_interface = eng.physics.zphy.getBodyLockInterface();
        //
        //     var write_lock: zphy.BodyLockWrite = .{};
        //     write_lock.lock(lock_interface, chara_ent.physics_body.?);
        //     defer write_lock.unlock();
        //
        //     if (write_lock.body) |locked_body| {
        //         locked_body.getMotionPropertiesMut().setInverseMass(1.0 / 70.0);
        //         // disables rotation somehow (from jolt 3.0.1 Character.cpp line 45)
        //         locked_body.getMotionPropertiesMut().setInverseInertia([3]f32{0.0, 0.0, 0.0}, zm.qidentity());
        //         locked_body.setFriction(0.0);
        //     }
        // }

        var zphy_character_settings = try zphy.CharacterVirtualSettings.create(); 
        defer zphy_character_settings.release();

        zphy_character_settings.base.up = [4]f32{0.0, 1.0, 0.0, 0.0};
        zphy_character_settings.base.max_slope_angle = 70.0;
        zphy_character_settings.base.shape = chara_shape;
        zphy_character_settings.character_padding = 0.02;
        //zphy_character_settings.layer = ph.object_layers.moving;
        zphy_character_settings.mass = 70.0;
        //zphy_character_settings.friction = 0.0; // will handle manually
        //zphy_character_settings.gravity_factor = 0.0; // will handle manually

        chara_ent.app.chara_data = .{
            .character_physics = try zphy.CharacterVirtual.create(
                zphy_character_settings,
                zm.vecToArr3(chara_ent.transform.position),
                chara_ent.transform.rotation,
                eng.physics.zphy
            ),
            .character_shape = chara_shape,
        };

        const model_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(zm.Mat),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var model_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&model_constant_buffer_desc, null, @ptrCast(&model_buffer)));
        errdefer _ = model_buffer.Release();

        eng.physics.zphy.optimizeBroadPhase();

        const ui = try _ui.UiRenderer.init(eng.general_allocator.allocator(), &eng.gfx);
        errdefer ui.deinit();

        return Self {
            .engine = eng,
            .depth_stencil_view = depth_stencil_view,
            .vso = vso,
            .pso = pso,
            .vso_input_layout = vso_input_layout,
            .vertex_buffer = vertex_buffer,
            .rasterizer_states = rasterization_states,

            .camera_data_buffer = camera_data_buffer,
            .camera = cm.Camera {
                .field_of_view_y = 20.0,
                .near_field = 0.1,
                .far_field = 100.0,
                .move_speed = 2.0,
                .mouse_sensitivity = 0.001,
                .max_orbit_distance = 10.0,
                .min_orbit_distance = 1.0,
                .orbit_distance = 2.0,
            },
            .camera_idx = camera_transform_idx,

            .model_idx = chara_root_idx,
            .model_buffer = model_buffer,

            .chara_model = chara_model,
            .tree_model = tree_model,

            .ui = ui,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("App deinit!", .{});
        for (self.engine.entities.data.items) |*maybe_ent| {
            if (maybe_ent.item_data) |*en| {
                en.app.deinit();
            }
        }

        self.engine.gfx.context.Flush();
        self.ui.deinit();

        self.chara_model.deinit();
        self.tree_model.deinit();

        _ = self.camera_data_buffer.Release();
        _ = self.model_buffer.Release();
        _ = self.rasterizer_states.double_sided.Release();
        _ = self.rasterizer_states.cull_back_face.Release();
        _ = self.vertex_buffer.Release();
        _ = self.vso_input_layout.Release();
        _ = self.vso.Release();
        _ = self.pso.Release();
        _ = self.depth_stencil_view.Release();
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

    fn update(self: *Self) void {

        // Input to move the model around
        if (self.engine.entities.get(self.model_idx)) |model_entity| {
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

            const character = model_entity.app.chara_data.?.character_physics;
            var current_movement = zm.loadArr3(character.getLinearVelocity());

            var current_movement_direction = current_movement;
            current_movement_direction[1] = 0.0;

            if (character_is_supported(character)) {
                // remove any gravity
                current_movement[1] = 0.0;

                const character_movement_speed = 3.0;
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

            model_entity.app.chara_data.?.character_physics.setLinearVelocity(zm.vecToArr3(current_movement));

            // Rotate character model to match the input desired direction
            // If no input desired direction (normalized to nan) then remain in last rotation
            const dir = zm.normalize3(movement_direction);
            if (!std.math.isNan(dir[0])) {
                const rot = zm.lookAtRh(zm.f32x4s(0.0), dir * zm.f32x4(1.0, 1.0, -1.0, 0.0), zm.f32x4(0.0, 1.0, 0.0, 0.0));
                model_entity.transform.rotation =
                    zm.slerp(model_entity.transform.rotation, zm.matToQuat(rot), self.engine.time.delta_time_f32() * 10.0);
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
        var character_velocity = zm.f32x4s(0.0);
        if (self.engine.time.last_frame_time_s > 1.0) {
            std.log.warn("Skipping physics for this frame since the frame time was too large at {}s", .{self.engine.time.last_frame_time_s});
        } else {
            self.engine.physics.zphy.update(self.engine.time.delta_time_f32(), .{}) 
                catch std.log.err("Unable to update physics", .{});

            if (self.engine.entities.get(self.model_idx)) |model_entity| {
                const p0 = zm.loadArr3(model_entity.app.chara_data.?.character_physics.getPosition());
                //model_entity.app.chara_data.?.character_physics.update(self.engine.time.delta_time_f32(), [3]f32{0.0, -9.8, 0.0}, .{});
                model_entity.app.chara_data.?.character_physics.extendedUpdate(
                    self.engine.time.delta_time_f32(), 
                    [3]f32{0.0, -9.8, 0.0}, 
                    .{},
                    .{}
                );
                const p1 = zm.loadArr3(model_entity.app.chara_data.?.character_physics.getPosition());
                character_velocity = (p1 - p0) / zm.f32x4s(self.engine.time.delta_time_f32());

                // Update character virtual linear velocity based on physics interactions from update
                // because apparently this doesn't happen automatically???
                //model_entity.app.chara_data.?.character_physics.setLinearVelocity(zm.vecToArr3(character_velocity));
            } else |_| {}

            if (self.engine.entities.get(self.model_idx)) |model_entity| {
                const pos = model_entity.app.chara_data.?.character_physics.getPosition();
                model_entity.transform.position = zm.f32x4(pos[0], pos[1], pos[2], 1.0);
            } else |_| {}

            // After physics update set all entity transforms to match physics bodies
            {
                const body_interface = self.engine.physics.zphy.getBodyInterface();
                for (self.engine.entities.data.items) |*it| {
                    if (it.item_data) |*en| {
                        if (en.physics_body) |body_id| {
                            const pos = body_interface.getPosition(body_id);
                            en.transform.position = zm.f32x4(pos[0], pos[1], pos[2], 1.0);
                            en.transform.rotation = body_interface.getRotation(body_id);
                        }
                    }
                }
            }
        }

        // Camera input and buffer data management
        if (self.engine.entities.get(self.camera_idx)) |camera_entity| {
        if (self.engine.entities.get(self.model_idx)) |model_entity| {
            self.camera.update(&camera_entity.transform, model_entity.transform.position + zm.f32x4(0.0, 1.5, 0.0, 0.0), self.engine);

            { // Update camera buffer
                var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.camera_data_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                defer self.engine.gfx.context.Unmap(@ptrCast(self.camera_data_buffer), 0);

                var buffer_data: *CameraStruct = @ptrCast(@alignCast(mapped_subresource.pData));
                buffer_data.view = self.camera.view_matrix;
                buffer_data.projection = self.camera.generate_perspective_matrix(self.engine.gfx.swapchain_aspect());
            }
        } else |_| {}
        } else |_| {}

        // Draw frame
        var rtv = self.engine.gfx.begin_frame() catch |err| {
            std.log.err("unable to begin frame: {}", .{err});
            return;
        };
        self.engine.gfx.context.ClearRenderTargetView(rtv, &[4]zwin32.w32.FLOAT{30.0/255.0, 30.0/255.0, 46.0/255.0, 1.0});
        self.engine.gfx.context.ClearDepthStencilView(self.depth_stencil_view, d3d11.CLEAR_FLAG {.CLEAR_DEPTH = true,}, 1, 0);

        const viewport = d3d11.VIEWPORT {
            .Width = @floatFromInt(self.engine.gfx.swapchain_size.width),
            .Height = @floatFromInt(self.engine.gfx.swapchain_size.height),
            .TopLeftX = 0,
            .TopLeftY = 0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        self.engine.gfx.context.RSSetViewports(1, @ptrCast(&viewport));

        self.engine.gfx.context.PSSetShader(self.pso, null, 0);

        self.engine.gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), self.depth_stencil_view);
        self.engine.gfx.context.OMSetBlendState(null, null, 0xffffffff);

        self.engine.gfx.context.VSSetShader(self.vso, null, 0);
        self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_data_buffer));

        self.engine.gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        self.engine.gfx.context.IASetInputLayout(self.vso_input_layout);

        // Iterate through all entities finding those which contain a mesh to be rendered
        for (self.engine.entities.data.items) |*it| {
            if (it.item_data) |*entity| {
                // Find the transform of the entity to be rendered taking into account it's parent
                if (entity.mesh) |m| {
                    const pos_stride: c_uint = @sizeOf(f32) * 3;
                    const tex_coord_stride: c_uint = @sizeOf(f32) * 2;
                    const offset: c_uint = 0;
                    self.engine.gfx.context.IASetVertexBuffers(0, 1, @ptrCast(&m.buffers.positions), @ptrCast(&pos_stride), @ptrCast(&offset));
                    self.engine.gfx.context.IASetVertexBuffers(1, 1, @ptrCast(&m.buffers.normals), @ptrCast(&pos_stride), @ptrCast(&offset));
                    self.engine.gfx.context.IASetVertexBuffers(2, 1, @ptrCast(&m.buffers.tex_coords), @ptrCast(&tex_coord_stride), @ptrCast(&offset));
                    self.engine.gfx.context.IASetIndexBuffer(m.buffers.indices, zwin32.dxgi.FORMAT.R32_UINT, 0);

                    { // Setup model buffer from transform
                        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                        zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.model_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                        defer self.engine.gfx.context.Unmap(@ptrCast(self.model_buffer), 0);

                        const buffer_data: *zm.Mat = @ptrCast(@alignCast(mapped_subresource.pData));
                        buffer_data.* = entity.transform.generate_model_matrix();
                    }
                    
                    // Set model constant buffer
                    self.engine.gfx.context.VSSetConstantBuffers(1, 1, @ptrCast(&self.model_buffer));

                    // Finally, render the mesh
                    for (m.primitives) |*p| {
                        if (p.material_descriptor.double_sided) {
                            self.engine.gfx.context.RSSetState(self.rasterizer_states.double_sided);
                        } else {
                            self.engine.gfx.context.RSSetState(self.rasterizer_states.cull_back_face);
                        }

                        if (p.has_indices()) {
                            self.engine.gfx.context.DrawIndexed(@intCast(p.num_indices), @intCast(p.indices_offset), @intCast(p.pos_offset));
                        } else {
                            self.engine.gfx.context.Draw(@intCast(p.num_vertices), @intCast(p.pos_offset));
                        }
                    }
                }
            }
        }

        // Draw Physics Debug Wireframes
        if (self.engine.input.get_key(kc.KeyCode.C)) {
            if (self.engine.entities.get(self.camera_idx)) |camera_entity| {
                _ = camera_entity;
                self.engine.physics._interfaces.debug_renderer.draw_bodies(
                    self.engine.physics.zphy, 
                    rtv, 
                    self.engine.gfx.swapchain_size.width,
                    self.engine.gfx.swapchain_size.height,
                    &self.camera, 
                    zm.matToArr(self.camera.view_matrix),
                );
            } else |_| {}
        }

        self.render_text_over_quad(
            &self.ui.fonts[@intFromEnum(FontEnum.GeistMono)],
            "Hello World.\nThis is the next line.",
            100,
            100,
            .{
                .size = .{.Pixels = 15},
            }, 
            .{
                .colour = zm.f32x4(0.0, 0.0, 0.0, 1.0),
            },
            rtv,
            self.engine.gfx.swapchain_size.width, 
            self.engine.gfx.swapchain_size.height, 
        );

        const vel_text = std.fmt.allocPrint(self.engine.general_allocator.allocator(), "character speed: {d:.2}\nvelocity: {d:.2}\nis supported: {}", .{
            zm.length3(character_velocity)[0],
            character_velocity,
            character_is_supported((self.engine.entities.get(self.model_idx) catch unreachable).app.chara_data.?.character_physics),
        }) catch unreachable;
        defer self.engine.general_allocator.allocator().free(vel_text);

        self.ui.render_text_2d(
            FontEnum.GeistMono,
            vel_text, 
            100, 
            500, 
            .{
                .size = .{.Pixels = 15},
            }, 
            rtv, 
            self.engine.gfx.swapchain_size.width, 
            self.engine.gfx.swapchain_size.height, 
            &self.engine.gfx
        );

        var fps_buf: [64]u8 = [_]u8{0} ** 64;
        const fps_text = std.fmt.bufPrint(fps_buf[0..], "frame time: {d:2.3}ms\nfps: {d:0.1}", .{
            self.engine.time.delta_time_f32() * std.time.ms_per_s,
            self.engine.time.get_fps(),
        }) catch unreachable;

        self.ui.render_text_2d(
            FontEnum.GeistMono,
            fps_text, 
            10,
            self.engine.gfx.swapchain_size.height - @as(i32, @intFromFloat(self.ui.fonts[@intFromEnum(FontEnum.GeistMono)].font_metrics.ascender * 12.0)),
            .{
                .size = .{.Pixels = 12},
            }, 
            rtv, 
            self.engine.gfx.swapchain_size.width, 
            self.engine.gfx.swapchain_size.height, 
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
            10, 
            - @as(i32, @intFromFloat(self.ui.fonts[@intFromEnum(FontEnum.GeistMono)].font_metrics.descender * 12.0)),
            .{
                .size = .{.Pixels = 12},
            }, 
            rtv, 
            self.engine.gfx.swapchain_size.width, 
            self.engine.gfx.swapchain_size.height, 
            &self.engine.gfx
        );

        self.engine.gfx.end_frame(rtv) catch |err| {
            std.log.err("unable to end frame: {}", .{err});
            return;
        };
        return;
    }

    pub fn create_depth_stencil_view(eng: *engine.Engine(Self)) !*d3d11.IDepthStencilView {
        const depth_texture_desc = d3d11.TEXTURE2D_DESC {
            .Width = @intCast(eng.gfx.swapchain_size.width),
            .Height = @intCast(eng.gfx.swapchain_size.height),
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = zwin32.dxgi.FORMAT.D16_UNORM,
            .SampleDesc = zwin32.dxgi.SAMPLE_DESC {
                .Count = 1,
                .Quality = 0,
            },
            .Usage = d3d11.USAGE.DEFAULT,
            .BindFlags = d3d11.BIND_FLAG {.DEPTH_STENCIL = true,},
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG {},
            .MiscFlags = d3d11.RESOURCE_MISC_FLAG {},
        };
        var depth_texture: *d3d11.ITexture2D = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateTexture2D(&depth_texture_desc, null, @ptrCast(&depth_texture)));
        defer _ = depth_texture.Release();

        const depth_stencil_desc = d3d11.DEPTH_STENCIL_VIEW_DESC {
            .Format = zwin32.dxgi.FORMAT.D16_UNORM,
            .ViewDimension = d3d11.DSV_DIMENSION.TEXTURE2D,
            .u = .{
                .Texture2D = d3d11.TEX2D_DSV {
                    .MipSlice = 0,
                },
            },
            .Flags = d3d11.DSV_FLAGS {},
        };
        var depth_stencil_view: *d3d11.IDepthStencilView = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateDepthStencilView(@ptrCast(depth_texture), &depth_stencil_desc, @ptrCast(&depth_stencil_view)));
        errdefer _ = depth_stencil_view.Release();

        return depth_stencil_view;
    }
    
    pub fn window_event_received(self: *Self, event: *const window.WindowEvent) void {
        switch (event.*) {
            .EVENTS_CLEARED => { self.update(); },
            .RESIZED => |new_size| {
                if (new_size.width > 0 and new_size.height > 0) {
                    _ = self.depth_stencil_view.Release();
                    self.depth_stencil_view = create_depth_stencil_view(self.engine) catch unreachable;
                }
            },
            else => {},
        }
    }

    fn render_text_over_quad(
        self: *Self,
        font_: *font.Font,
        text: []const u8,
        x_pos: i32,
        y_pos: i32,
        text_props: font.Font.FontRenderProperties2D,
        quad_props: _ui.QuadRenderer.QuadProperties,
        rtv: *d3d11.IRenderTargetView,
        rtv_width: i32,
        rtv_height: i32,
    ) void {
        self.ui.quad_renderer.render_quad(
            font_.text_bounds_2d(text, x_pos, y_pos, text_props, rtv_width, rtv_height),
            quad_props,
            rtv,
            rtv_width,
            rtv_height,
            &self.engine.gfx
        );
        font_.render_text_2d(
            text,
            x_pos,
            y_pos,
            text_props,
            rtv,
            rtv_width,
            rtv_height,
            &self.engine.gfx
        );
    }

    fn character_is_supported(chr: *zphy.CharacterVirtual) bool {
        return chr.getGroundState() == zphy.CharacterGroundState.on_ground;
    }
};

