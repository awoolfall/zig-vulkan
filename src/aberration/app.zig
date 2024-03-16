const std = @import("std");
const zwin32 = @import("zwin32");
const zm = @import("zmath");
const zphy = @import("zphysics");
const w32 = zwin32.w32;
const d3d11 = zwin32.d3d11;

const engine = @import("../engine.zig");
const Transform = engine.Transform;
const window = @import("../window.zig");
const kc = @import("../input/keycode.zig");
const ent = @import("../engine/entity.zig");
const ph = @import("../engine/physics.zig");
const path = @import("../engine/path.zig");
const es = @import("../easings.zig");

const font = @import("../engine/font.zig");
const _ui = @import("../engine/ui.zig");
const FontEnum = _ui.FontEnum;

const gitrev = @import("build_options").gitrev;
const gitchanged = @import("build_options").gitchanged;

const CameraStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
};

const QuadVsBufferStruct = extern struct {
    quad_bounds: zm.F32x4,
};

const QuadPsBufferStruct = extern struct {
    colour: zm.F32x4,
    texture_flags: i32,
};

const EntityProperties = struct {
    scene_name: []u8,
    alloc: std.mem.Allocator,
    is_god: bool = false,

    max_speed: ?f32 = null,
    acceleration: ?f32 = null,
    velocity: ?f32 = null,

    health_points: ?i32 = null,
    attack_damage: ?i32 = null,
    attack_interval: ?f32 = null,


    pub fn deinit(self: *const EntityProperties) void {
        self.alloc.free(self.scene_name);
    }

    pub fn adjust_value(self: *EntityProperties, prop_id: u8, up: bool) void {
        switch (prop_id) {
            1 => { // is god
                self.is_god = !self.is_god;
            },
            2 => { // max speed
                if (self.max_speed) |*ms| {
                    if (up) { ms.* += 10.0; } else { ms.* -= 10.0; }
                }
            },
            3 => { // acceleration
                if (self.acceleration) |*ac| {
                    if (up) { ac.* += 1.0; } else { ac.* -= 1.0; }
                }
            },
            4 => { // velocity
                if (self.velocity) |*vel| {
                    if (up) { vel.* += 10.0; } else { vel.* -= 10.0; }
                }
            },
            5 => { // health points
                if (self.health_points) |*hp| {
                    if (up) { hp.* += 10; } else { hp.* -= 10; }
                }
            },
            6 => { // attack damage
                if (self.attack_damage) |*ad| {
                    if (up) { ad.* += 10; } else { ad.* -= 10; }
                }
            },
            7 => { // attack interval
                if (self.attack_interval) |*at| {
                    if (up) { at.* += 0.1; } else { at.* -= 0.1; }
                }
            },
            else => {},
        }
    }
};

pub const Engine = engine.Engine(AberrationApp);
pub const AberrationApp = struct {
    const Self = @This();

    pub const EntityData = struct {
        quad_data: ?struct {
            colour: zm.F32x4,
            size: struct { width: f32, height: f32, },
            texture_view: ?*d3d11.IShaderResourceView,
            flip_texture_h: bool = false,
        } = null,
        doe: ?struct {
            character: *zphy.CharacterVirtual,
            contact_listener: DoeCharacterContactListener,
            shape: *zphy.ShapeSettings,
            coyote_end_time_ns: i128,
        } = null,
        properties: ?EntityProperties = null,

        pub fn deinit(self: *EntityData) void {
            if (self.doe) |*doe| {
                doe.character.destroy();
                doe.shape.release();
            }
            if (self.properties) |properties| {
                properties.deinit();
            }
            if (self.quad_data) |quad_data| {
                if (quad_data.texture_view) |tex_view| {
                    _ = tex_view.Release();
                }
            }
        }

        pub fn create_phys_shape_settings(self: *EntityData) !*zphy.BoxShapeSettings {
            if (self.quad_data) |*quad_data| {
                return try zphy.BoxShapeSettings.create([3]f32{ quad_data.size.width / 2.0, quad_data.size.height / 2.0, 0.5 });
            }
            return error.NoQuadData;
        }
    };

    const textured_quad_shader = @embedFile("textured_quad_shader.hlsl");

    const sprite_sheet = @embedFile("assets/spritesheet.png");
    const sprite_sheet_json = @embedFile("assets/spritesheet.json");

    const triangle_vertices: [3 * 3]zwin32.w32.FLOAT = [_]zwin32.w32.FLOAT{
        0.0, 0.5, 0.0,
        -0.5, -0.5, 0.0,
        0.5, -0.5, 0.0,
    };

    const RasterizationStates = struct {
        double_sided: *d3d11.IRasterizerState,
        cull_back_face: *d3d11.IRasterizerState,
    };

    const MAX_PLATFORMS: usize = 32;

    engine: *engine.Engine(Self),
    contact_listener: *ContactListener,

    depth_stencil_view: *d3d11.IDepthStencilView,

    vso: *d3d11.IVertexShader,
    pso: *d3d11.IPixelShader,
    vso_input_layout: *d3d11.IInputLayout,
    rasterizer_states: RasterizationStates,
    
    camera_data_buffer: *d3d11.IBuffer,
    camera_idx: ent.GenerationalIndex,
    camera_view_matrix: zm.Mat,
    camera_proj_matrix: zm.Mat,

    quad_vs_buffer: *d3d11.IBuffer,
    quad_ps_buffer: *d3d11.IBuffer,

    blend_state: *d3d11.IBlendState,
    sampler: *d3d11.ISamplerState,

    game_viewport: d3d11.VIEWPORT,
    editor_viewport: d3d11.VIEWPORT,

    doe_idx: ent.GenerationalIndex,

    properties_panel_selected_entity: ent.GenerationalIndex,
    scene_and_properties_platforms: [MAX_PLATFORMS]zphy.BodyId,

    // We create editor phys using UI rects. Only know these after 1st frame...
    editor_phys_created: bool = false,

    ui: _ui.UiRenderer,

    pub fn deinit(self: *Self) void {
        std.log.info("App deinit!", .{});
        for (self.engine.entities.data.items) |*maybe_ent| {
            if (maybe_ent.item_data) |*en| {
                en.app.deinit();
            }
        }

        for (self.scene_and_properties_platforms) |pid| {
            self.engine.physics.zphy.getBodyInterfaceMut().removeAndDestroyBody(pid);
        }
        self.engine.physics.zphy.setContactListener(null);
        self.engine.general_allocator.allocator().destroy(self.contact_listener);

        self.engine.gfx.context.Flush();
        self.ui.deinit();

        _ = self.blend_state.Release();
        _ = self.sampler.Release();
        _ = self.camera_data_buffer.Release();
        _ = self.quad_vs_buffer.Release();
        _ = self.quad_ps_buffer.Release();
        _ = self.rasterizer_states.double_sided.Release();
        _ = self.rasterizer_states.cull_back_face.Release();
        _ = self.vso_input_layout.Release();
        _ = self.vso.Release();
        _ = self.pso.Release();
        _ = self.depth_stencil_view.Release();
    }

    pub fn init(eng: *engine.Engine(Self)) !Self {
        std.log.info("App init!", .{});

        var depth_stencil_view: *d3d11.IDepthStencilView = try create_depth_stencil_view(eng);
        errdefer _ = depth_stencil_view.Release();

        // Compile VS and PS shader blobs from hlsl source
        var vs_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&textured_quad_shader[0], textured_quad_shader.len, null, null, null, "vs_main", "vs_5_0", 0, 0, @ptrCast(&vs_blob), null));
        defer _ = vs_blob.Release();

        var vso: *d3d11.IVertexShader = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, @ptrCast(&vso)));
        errdefer _ = vso.Release();

        var ps_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&textured_quad_shader[0], textured_quad_shader.len, null, null, null, "ps_main", "ps_5_0", 0, 0, @ptrCast(&ps_blob), null));
        defer _ = ps_blob.Release();

        // Create vertex and pixel shaders
        var pso: *d3d11.IPixelShader = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&pso)));
        errdefer _ = pso.Release();

        const vso_input_layout_desc = [_]d3d11.INPUT_ELEMENT_DESC {
        };
        var vso_input_layout: *d3d11.IInputLayout = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateInputLayout(vso_input_layout_desc[0..], vso_input_layout_desc.len, vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), @ptrCast(&vso_input_layout)));
        errdefer _ = vso_input_layout.Release();

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

        const vs_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(QuadVsBufferStruct),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var quad_vs_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&vs_constant_buffer_desc, null, @ptrCast(&quad_vs_buffer)));
        errdefer _ = quad_vs_buffer.Release();

        const ps_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(QuadPsBufferStruct),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var quad_ps_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&ps_constant_buffer_desc, null, @ptrCast(&quad_ps_buffer)));
        errdefer _ = quad_ps_buffer.Release();

        // create sampler
        const sampler_desc = d3d11.SAMPLER_DESC {
            .Filter = d3d11.FILTER.MIN_MAG_MIP_POINT,
            .AddressU = d3d11.TEXTURE_ADDRESS_MODE.BORDER,
            .AddressV = d3d11.TEXTURE_ADDRESS_MODE.BORDER,
            .AddressW = d3d11.TEXTURE_ADDRESS_MODE.BORDER,
            .MipLODBias = 0.0,
            .MaxAnisotropy = 1,
            .ComparisonFunc = d3d11.COMPARISON_FUNC.NEVER,
            .BorderColor = [4]w32.FLOAT{0.0, 0.0, 0.0, 0.0},
            .MinLOD = 0.0,
            .MaxLOD = 0.0,
        };
        var sampler: *d3d11.ISamplerState = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateSamplerState(&sampler_desc, @ptrCast(&sampler)));
        errdefer _ = sampler.Release();

        // create blend state
        var blend_state_desc = d3d11.BLEND_DESC {
            .AlphaToCoverageEnable = 0,
            .IndependentBlendEnable = 0,
            .RenderTarget = [_]d3d11.RENDER_TARGET_BLEND_DESC {undefined} ** 8,
        };
        blend_state_desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .RenderTargetWriteMask = d3d11.COLOR_WRITE_ENABLE.ALL,
            .SrcBlend = d3d11.BLEND.SRC_ALPHA,
            .DestBlend = d3d11.BLEND.INV_SRC_ALPHA,
            .BlendOp = d3d11.BLEND_OP.ADD,
            .SrcBlendAlpha = d3d11.BLEND.ONE,
            .DestBlendAlpha = d3d11.BLEND.ZERO,
            .BlendOpAlpha = d3d11.BLEND_OP.ADD,
        };
        var blend_state: *d3d11.IBlendState = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBlendState(&blend_state_desc, @ptrCast(&blend_state)));
        errdefer _ = blend_state.Release();

        eng.physics.zphy.optimizeBroadPhase();

        const contact_listener = try eng.general_allocator.allocator().create(ContactListener);
        errdefer eng.general_allocator.allocator().destroy(contact_listener);
        contact_listener.* = .{};
        eng.physics.zphy.setContactListener(contact_listener);

        var ui = try _ui.UiRenderer.init(eng.general_allocator.allocator(), &eng.gfx);
        errdefer ui.deinit();

        var sprite_sheet_image = try eng.image.load_from_memory(sprite_sheet);
        defer sprite_sheet_image.deinit();

        const doe_texture_desc = d3d11.TEXTURE2D_DESC {
            .Width = sprite_sheet_image.width,
            .Height = sprite_sheet_image.height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = zwin32.dxgi.FORMAT.R8G8B8A8_UNORM_SRGB,
            .SampleDesc = zwin32.dxgi.SAMPLE_DESC {
                .Count = 1,
                .Quality = 0,
            },
            .Usage = d3d11.USAGE.DEFAULT,
            .BindFlags = d3d11.BIND_FLAG {.SHADER_RESOURCE = true,},
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG {},
            .MiscFlags = d3d11.RESOURCE_MISC_FLAG {},
        };
        var doe_texture: *d3d11.ITexture2D = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateTexture2D(
                &doe_texture_desc, 
                &d3d11.SUBRESOURCE_DATA {
                    .pSysMem = @ptrCast(sprite_sheet_image.data), 
                    .SysMemPitch = sprite_sheet_image.width * @sizeOf([4]u8),
                }, 
                @ptrCast(&doe_texture)
        ));
        defer _ = doe_texture.Release();

        const doe_texture_resource_view_desc = d3d11.SHADER_RESOURCE_VIEW_DESC {
            .Format = zwin32.dxgi.FORMAT.R8G8B8A8_UNORM_SRGB,
            .ViewDimension = d3d11.SRV_DIMENSION.TEXTURE2D,
            .u = .{
                .Texture2D = d3d11.TEX2D_SRV {
                    .MostDetailedMip = 0,
                    .MipLevels = 1,
                },
            },
        };
        var doe_texture_view: *d3d11.IShaderResourceView = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateShaderResourceView(
                @ptrCast(doe_texture), 
                &doe_texture_resource_view_desc, 
                @ptrCast(&doe_texture_view)
        ));
        errdefer _ = doe_texture_view.Release();

        const doe_idx = try eng.entities.insert(.{
            .app = .{
                .properties = .{
                    .scene_name = try std.fmt.allocPrint(eng.general_allocator.allocator(), "Doe", .{}),
                    .alloc = eng.general_allocator.allocator(),
                    .is_god = true,
                    .max_speed = 120.0,
                    .acceleration = 10.0,

                    .health_points = 20,
                    .attack_damage = 1,
                },
            },
        });
        if (eng.entities.get(doe_idx)) |doe| {
            doe.transform.position = zm.f32x4(0.0, 200.0, 0.0, 1.0);
            // doe.transform.position = zm.f32x4(100.0, 100.0, 20.0, 1.0);
            doe.app.quad_data = .{
                .colour = zm.f32x4(1.0,1.0,1.0,1.0),
                .size = .{ .width = 40.0, .height = 40.0, },
                .texture_view = doe_texture_view,
            };

            var zphy_character_settings = try zphy.CharacterVirtualSettings.create(); 
            defer zphy_character_settings.release();

            const doe_shape_settings = try zphy.CapsuleShapeSettings.create(0.5, doe.app.quad_data.?.size.width / 2.0);
            defer doe_shape_settings.release();

            const rotated_settings = try zphy.DecoratedShapeSettings.createRotatedTranslated(
                doe_shape_settings.asShapeSettings(), 
                zm.vecToArr4(zm.quatFromRollPitchYaw(0.0, std.math.degreesToRadians(f32, 90.0), 0.0)),
                [3]f32{0.0, 0.0, 0.0});

            const doe_shape = try rotated_settings.asShapeSettings().createShape();
            defer doe_shape.release();

            zphy_character_settings.base.up = [4]f32{0.0, 1.0, 0.0, 0.0};
            zphy_character_settings.base.max_slope_angle = 1.0;
            zphy_character_settings.base.shape = doe_shape;
            zphy_character_settings.character_padding = 0.02;
            //zphy_character_settings.layer = ph.object_layers.moving;
            zphy_character_settings.mass = 70.0;
            //zphy_character_settings.friction = 0.0; // will handle manually
            //zphy_character_settings.gravity_factor = 1.0;

            doe.app.doe = .{
                .character = try zphy.CharacterVirtual.create(
                    zphy_character_settings,
                    zm.vecToArr3(doe.transform.position),
                    zm.qidentity(),
                    eng.physics.zphy
                ),
                .contact_listener = DoeCharacterContactListener {
                    .physics_system = eng.physics.zphy,
                },
                .shape = @constCast(rotated_settings.asShapeSettings()),
                .coyote_end_time_ns = 0,
            };
            doe.app.doe.?.character.setListener(@ptrCast(&doe.app.doe.?.contact_listener));
        } else |_| { unreachable; }

        // ground
        const entId = try eng.entities.insert(.{
            .transform = Transform {
                .position = zm.f32x4(0.0, -500.0, 0.0, 1.0),
            },
            .app = .{
                .properties = .{
                    .scene_name = try std.fmt.allocPrint(eng.general_allocator.allocator(), "Ground", .{}),
                    .alloc = eng.general_allocator.allocator(),
                },
                .quad_data = .{
                    .colour = zm.f32x4(109.0/255.0, 76.0/255.0, 65.0/255.0, 1.0),
                    .size = .{ .width = 5000.0, .height = 1000.0, },
                    .texture_view = null,
                },
            },
        });

        if (eng.entities.get(entId)) |entt| {
            const ent_shape_settings = try entt.app.create_phys_shape_settings();
            defer ent_shape_settings.release();

            const ent_shape = try ent_shape_settings.asShapeSettings().createShape();
            defer ent_shape.release();

            entt.physics_body = try eng.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = zm.vecToArr4(entt.transform.position),
                .rotation = zm.qidentity(),
                .shape = ent_shape,
                .motion_type = .static,
                .object_layer = ph.object_layers.non_moving,
            }, .activate);
            PhysicsBodyUserBitfield.setBodyIdUserData(
                eng.physics.zphy,
                entt.physics_body.?,
                PhysicsBodyUserBitfield { .doe_can_jump_through = true, }
            );
        } else |_| { unreachable; }

        // Village
        const villageId = try eng.entities.insert(.{
            .transform = Transform {
                .position = zm.f32x4(500.0, 50.0, 0.0, 1.0),
            },
            .app = .{
                .properties = .{
                    .scene_name = try std.fmt.allocPrint(eng.general_allocator.allocator(), "Village", .{}),
                    .alloc = eng.general_allocator.allocator(),
                    .velocity = 0,

                    .health_points = 100,
                    .attack_damage = 10,
                    .attack_interval = 0,
                },
                .quad_data = .{
                    .colour = zm.f32x4(0.8, 0.8, 0.8, 1.0),
                    .size = .{ .width = 400.0, .height = 100.0, },
                    .texture_view = null,
                },
            },
        });

        if (eng.entities.get(villageId)) |entt| {
            const ent_shape_settings = try entt.app.create_phys_shape_settings();
            defer ent_shape_settings.release();

            const ent_shape = try ent_shape_settings.asShapeSettings().createShape();
            defer ent_shape.release();

            entt.physics_body = try eng.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = zm.vecToArr4(entt.transform.position),
                .rotation = zm.qidentity(),
                .shape = ent_shape,
                .motion_type = .static,
                .object_layer = ph.object_layers.non_moving,
                .is_sensor = true,
            }, .dont_activate);
            PhysicsBodyUserBitfield.setBodyIdUserData(
                eng.physics.zphy,
                entt.physics_body.?,
                PhysicsBodyUserBitfield {}
            );
        } else |_| { unreachable; }

        // Dragon
        const dragonId = try eng.entities.insert(.{
            .transform = Transform {
                .position = zm.f32x4(2400.0, 50.0, 0.0, 1.0),
            },
            .app = .{
                .properties = .{
                    .scene_name = try std.fmt.allocPrint(eng.general_allocator.allocator(), "Dragon", .{}),
                    .alloc = eng.general_allocator.allocator(),
                    .velocity = -10.0,

                    .health_points = 1000,
                    .attack_damage = 100,
                    .attack_interval = 0.5,
                },
                .quad_data = .{
                    .colour = zm.f32x4(0.8, 0.1, 0.1, 1.0),
                    .size = .{ .width = 200.0, .height = 150.0, },
                    .texture_view = null,
                },
            },
        });

        if (eng.entities.get(dragonId)) |entt| {
            const ent_shape_settings = try entt.app.create_phys_shape_settings();
            defer ent_shape_settings.release();

            const ent_shape = try ent_shape_settings.asShapeSettings().createShape();
            defer ent_shape.release();

            entt.physics_body = try eng.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = zm.vecToArr4(entt.transform.position),
                .rotation = zm.qidentity(),
                .shape = ent_shape,
                .motion_type = .dynamic,
                .object_layer = ph.object_layers.moving,
                .is_sensor = true,
            }, .activate);
            PhysicsBodyUserBitfield.setBodyIdUserData(
                eng.physics.zphy,
                entt.physics_body.?,
                PhysicsBodyUserBitfield {}
            );
        } else |_| { unreachable; }

        const window_w: f32 = @floatFromInt(eng.gfx.swapchain_size.width);
        const window_h: f32 = @floatFromInt(eng.gfx.swapchain_size.height);

        const editor_viewport = d3d11.VIEWPORT {
            .Width = window_w,
            .Height = window_h,
            .TopLeftX = 0.0,
            .TopLeftY = 0.0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        const game_viewport = d3d11.VIEWPORT {
            .Width = (window_w * 2.0) / 3.0,
            .Height = (window_h * 2.0) / 3.0,
            .TopLeftX = window_w / 6.0,
            .TopLeftY = window_h * 0.1,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        
        const box_shape_settings = try zphy.BoxShapeSettings.create([3]f32{ (window_w / 13.0) - 50.0, 5.0 / 2.0, 0.5 });
        defer box_shape_settings.release();

        const box_shape = try box_shape_settings.asShapeSettings().createShape();
        defer box_shape.release();

        var platform_ids: [MAX_PLATFORMS]zphy.BodyId = [_]zphy.BodyId{undefined} ** MAX_PLATFORMS;

        for (0..MAX_PLATFORMS) |i| {
            platform_ids[i] = try eng.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = zm.vecToArr4(zm.f32x4(0.0, 0.0, -100.0, 1.0)),
                .rotation = zm.qidentity(),
                .shape = box_shape,
                .motion_type = .static,
                .object_layer = ph.object_layers.non_moving,
            }, .dont_activate);

            PhysicsBodyUserBitfield.setBodyIdUserData(
                eng.physics.zphy,
                platform_ids[i],
                PhysicsBodyUserBitfield { 
                    .doe_can_drop_through = true,
                    .doe_can_jump_through = true,
                }
            );
        }

        return Self {
            .engine = eng,
            .contact_listener = contact_listener,
            .depth_stencil_view = depth_stencil_view,
            .vso = vso,
            .pso = pso,
            .vso_input_layout = vso_input_layout,
            .rasterizer_states = rasterization_states,

            .camera_data_buffer = camera_data_buffer,
            .camera_idx = camera_transform_idx,
            .camera_view_matrix = zm.inverse(zm.translation(0.0, 0.0, -10.0)),
            .camera_proj_matrix = zm.orthographicLh(
                @floatFromInt(eng.gfx.swapchain_size.width), 
                @floatFromInt(eng.gfx.swapchain_size.height),
                0.1, 
                100.1
            ),

            .quad_vs_buffer = quad_vs_buffer,
            .quad_ps_buffer = quad_ps_buffer,

            .sampler = sampler,
            .blend_state = blend_state,

            .game_viewport = game_viewport,
            .editor_viewport = editor_viewport,

            .doe_idx = doe_idx,
            .properties_panel_selected_entity = doe_idx,
            .scene_and_properties_platforms = platform_ids,

            .ui = ui,
        };
    }

    fn update(self: *Self) void {
        const window_w: f32 = @floatFromInt(self.engine.gfx.swapchain_size.width);
        const window_h: f32 = @floatFromInt(self.engine.gfx.swapchain_size.height);

        self.editor_viewport = d3d11.VIEWPORT {
            .Width = window_w,
            .Height = window_h,
            .TopLeftX = 0.0,
            .TopLeftY = 0.0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        self.game_viewport = d3d11.VIEWPORT {
            .Width = (window_w * 2.0) / 3.0,
            .Height = (window_h * 2.0) / 3.0,
            .TopLeftX = window_w / 6.0,
            .TopLeftY = window_h * 0.1,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };

        // Camera follows doe when in game space
        if (self.engine.entities.get(self.doe_idx)) |doe| {
            if (doe.transform.position[2] < 1.0) {
                self.camera_view_matrix[3][0] = std.math.lerp(self.camera_view_matrix[3][0], @min(0.0, -doe.transform.position[0]), 0.1);
            }
        } else |_| {}

        for (self.engine.entities.data.items) |*ent_item| {
            if (ent_item.item_data) |*e| {
                if (e.app.properties) |*props| {
                    const body_interface = self.engine.physics.zphy.getBodyInterfaceMut();
                    if (props.velocity) |v| {
                        body_interface.setLinearVelocity(e.physics_body.?, [3]f32 { v, 0.0, 0.0 });
                    }
                }
            }
        }

        // Doe controls
        if (self.engine.entities.get(self.doe_idx)) |doe| {
            if (doe.app.doe) |*doe_data| {
                var desired_movement = zm.f32x4s(0.0);
                if (self.engine.input.get_key(kc.KeyCode.A)) {
                    desired_movement[0] -= 1.0;
                }
                if (self.engine.input.get_key(kc.KeyCode.D)) {
                    desired_movement[0] += 1.0;
                }

                var current_movement = zm.loadArr3(doe_data.character.getLinearVelocity());
                const ground_state = doe_data.character.getGroundState();
                const max_speed = doe.app.properties.?.max_speed.?;

                switch (ground_state) {
                    .on_ground => {
                        // remove gravity
                        current_movement[1] = 0.0;
                    },
                    .on_steep_ground => {
                        const slide_speed = -20.0;
                        // slowly slide down vertical wall
                        current_movement += 
                            zm.loadArr3(self.engine.physics.zphy.getGravity()) * zm.f32x4s(self.engine.time.delta_time_f32() * 20.0);
                        if (current_movement[1] < slide_speed) {
                            current_movement[1] = slide_speed;
                        }
                    },
                    else => {
                        // Apply gravity
                        current_movement += 
                            zm.loadArr3(self.engine.physics.zphy.getGravity()) * zm.f32x4s(self.engine.time.delta_time_f32() * 20.0);
                    },
                }

                const acceleration = doe.app.properties.?.acceleration.?;

                if (ground_state == .on_ground) {
                    const on_ground_acceleration = acceleration * 2.0;

                    // if no movement keys, then apply friction
                    if (desired_movement[0] != 0.0) {
                        current_movement += (zm.normalize2(desired_movement) * zm.f32x4s(self.engine.time.delta_time_f32() * 20.0 * on_ground_acceleration));
                        current_movement[0] = @min(max_speed, @max(-max_speed, current_movement[0]));
                    } else {
                        if (@reduce(.Add, @abs(current_movement)) != 0.0) {
                            current_movement -= (zm.normalize2(current_movement) * zm.f32x4s(self.engine.time.delta_time_f32() * 20.0 * 20.0));
                        }
                    }
                } else {
                    const in_air_acceleration = acceleration * 1.0;

                    if (desired_movement[0] != 0.0) {
                        current_movement += (zm.normalize2(desired_movement) * zm.f32x4s(self.engine.time.delta_time_f32() * 20.0 * in_air_acceleration));
                        current_movement[0] = @min(max_speed, @max(-max_speed, current_movement[0]));
                    }
                }

                const given_coyote_time_s: f32 = 0.3;
                const given_coyote_time_ns: i128 = given_coyote_time_s * std.time.ns_per_s;

                if (ground_state == .on_ground or ground_state == .on_steep_ground) {
                    doe_data.coyote_end_time_ns = self.engine.time.frame_start_time_ns + given_coyote_time_ns;
                }

                // can jump within coyote time 
                if (self.engine.input.get_key_down(kc.KeyCode.Space)) {
                    if (self.engine.time.frame_start_time_ns < doe_data.coyote_end_time_ns) {
                        current_movement[1] = 120.0;
                        doe_data.coyote_end_time_ns = 0;
                    }
                }
                
                doe_data.character.setLinearVelocity(zm.vecToArr3(current_movement));
                if (doe.app.quad_data) |*quad_data| {
                    if (current_movement[0] < -5.0) quad_data.flip_texture_h = true;
                    if (current_movement[0] >  5.0)  quad_data.flip_texture_h = false;
                }

                // Charge
                if (self.engine.input.get_key_down(kc.KeyCode.E)) {
                    self.doe_perform_charge(zm.vecToArr3(desired_movement));
                }

                // Editor interactions
                if (self.engine.input.get_key_down(kc.KeyCode.ArrowDown)) {
                    if (doe_data.character.getGroundBodyID()) |ground_id| {
                        if (PhysicsBodyUserBitfield.getBodyIdUserData(self.engine.physics.zphy, ground_id)) |user_data| {
                            if (user_data.entity_id != 0) {
                                self.properties_panel_selected_entity = ent.GenerationalIndex {
                                    .index = user_data.entity_id,
                                    .generation = self.engine.entities.data.items[user_data.entity_id].generation,
                                };
                            }
                            if (user_data.property_id != 0) {
                                if (self.engine.entities.get(self.properties_panel_selected_entity)) |entt| {
                                    if (entt.app.properties) |*props| {
                                        props.adjust_value(user_data.property_id, false);
                                    }
                                } else |_| {}
                            }
                        }
                    }
                }
                if (self.engine.input.get_key_down(kc.KeyCode.ArrowUp)) {
                    if (doe_data.character.getGroundBodyID()) |ground_id| {
                        if (PhysicsBodyUserBitfield.getBodyIdUserData(self.engine.physics.zphy, ground_id)) |user_data| {
                            if (user_data.entity_id != 0) {
                                self.properties_panel_selected_entity = ent.GenerationalIndex {
                                    .index = user_data.entity_id,
                                    .generation = self.engine.entities.data.items[user_data.entity_id].generation,
                                };
                            }
                            if (user_data.property_id != 0) {
                                if (self.engine.entities.get(self.properties_panel_selected_entity)) |entt| {
                                    if (entt.app.properties) |*props| {
                                        props.adjust_value(user_data.property_id, true);
                                    }
                                } else |_| {}
                            }
                        }
                    }
                }

                // Drop down
                doe_data.contact_listener.drop_key_pressed = 
                    self.engine.input.get_key(kc.KeyCode.S);
            }
        } else |_| {}

        // Update physics. If frame time is greater than 1 second then skip physics for this frame.
        // @TODO: It is most likely we loaded something in and caused a spike... Fix this permanently 
        // by adding async loads and/or loading screens.
        if (self.engine.time.last_frame_time_s > 1.0) {
            std.log.warn("Skipping physics for this frame since the frame time was too large at {}s", .{self.engine.time.last_frame_time_s});
        } else {
            self.engine.physics.zphy.update(self.engine.time.delta_time_f32(), .{}) 
                catch std.log.err("Unable to update physics", .{});

            if (self.engine.entities.get(self.doe_idx)) |doe| {
                if (doe.app.doe) |*doe_data| {
                    doe_data.character.extendedUpdate(
                        self.engine.time.delta_time_f32(), 
                        [3]f32{0.0, -9.8 * 20.0, 0.0}, 
                        .{},
                        .{}
                    );

                    // Remove any z movement
                    var vel = doe_data.character.getLinearVelocity();
                    vel[2] = 0.0;
                    doe_data.character.setLinearVelocity(vel);

                    // wrap Doe when exiting game or editor viewport
                    var doe_pos = doe_data.character.getPosition();
                    doe_pos[2] = @round(doe_pos[2]);
                    if (doe_pos[2] > 19.0) {
                        if (doe_pos[1] < 0.0) {
                            doe_pos[1] = self.editor_viewport.Height;
                        }
                        else if (doe_pos[1] > self.editor_viewport.Height) {
                            doe_pos[1] = 0.0;
                        }
                        if (doe_pos[0] < 0.0) {
                            doe_pos[0] = self.editor_viewport.Width;
                        }
                        else if (doe_pos[0] > self.editor_viewport.Width) {
                            doe_pos[0] = 0.0;
                        }
                    }
                    else if (doe_pos[2] < 1.0) {
                        if (doe_pos[1] < (-self.game_viewport.Height / 2.0)) {
                            doe_pos[1] = self.game_viewport.Height / 2.0;
                        }
                    }
                    doe_data.character.setPosition(doe_pos);

                    doe.transform.position = zm.loadArr3(doe_data.character.getPosition());
                    doe.transform.position[3] = 1.0;
                }
            } else |_| {}

            // After physics update set all entity transforms to match physics bodies
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

        // Camera input and buffer data management
        if (self.engine.entities.get(self.camera_idx)) |camera_entity| {
            _ = camera_entity;
            //self.camera.update(&camera_entity.transform, model_entity.transform.position + zm.f32x4(0.0, 1.5, 0.0, 0.0), self.engine);

            { // Update camera buffer
                var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.camera_data_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                defer self.engine.gfx.context.Unmap(@ptrCast(self.camera_data_buffer), 0);

                var buffer_data: *CameraStruct = @ptrCast(@alignCast(mapped_subresource.pData));
                buffer_data.view = self.camera_view_matrix;
                buffer_data.projection = self.camera_proj_matrix;
            }
        } else |_| {}

        // Draw frame
        const rtv = self.engine.gfx.begin_frame() catch |err| {
            std.log.err("unable to begin frame: {}", .{err});
            return;
        };
        self.engine.gfx.context.ClearRenderTargetView(rtv, &[4]zwin32.w32.FLOAT{30.0/255.0, 30.0/255.0, 46.0/255.0, 1.0});
        self.engine.gfx.context.ClearDepthStencilView(self.depth_stencil_view, d3d11.CLEAR_FLAG {.CLEAR_DEPTH = true,}, 1, 0);

        self.engine.gfx.context.RSSetViewports(1, @ptrCast(&self.editor_viewport));

        const game_window_border = 1;

        // game window border
        self.ui.render_quad(
            _ui.RectPixels {
                .left = @as(i32, @intFromFloat(self.game_viewport.TopLeftX)) - game_window_border,
                .bottom = @as(i32, @intFromFloat(window_h - (self.game_viewport.TopLeftY + self.game_viewport.Height))) - game_window_border,
                .width = @as(i32, @intFromFloat(self.game_viewport.Width)) + (game_window_border * 2),
                .height = @as(i32, @intFromFloat(self.game_viewport.Height)) + (game_window_border * 2),
            },
            _ui.QuadRenderer.QuadProperties {
                .colour = zm.f32x4(94.0 / 255.0, 97.0 / 255.0, 114.0 / 255.0, 1.0),
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        // clear game window to background colour
        self.ui.render_quad(
            _ui.RectPixels {
                .left = @as(i32, @intFromFloat(self.game_viewport.TopLeftX)),
                .bottom = @as(i32, @intFromFloat(window_h - (self.game_viewport.TopLeftY + self.game_viewport.Height))),
                .width = @as(i32, @intFromFloat(self.game_viewport.Width)),
                .height = @as(i32, @intFromFloat(self.game_viewport.Height)),
            },
            _ui.QuadRenderer.QuadProperties {
                .colour = zm.f32x4(135.0/255.0, 206.0/255.0, 235.0/255.0, 1.0),
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        self.camera_proj_matrix = zm.orthographicLh(
            self.game_viewport.Width, 
            self.game_viewport.Height,
            0.1, 
            100.1
        );

        self.engine.gfx.context.RSSetViewports(1, @ptrCast(&self.game_viewport));

        self.engine.gfx.context.PSSetShader(self.pso, null, 0);

        self.engine.gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), self.depth_stencil_view);
        self.engine.gfx.context.OMSetBlendState(@ptrCast(self.blend_state), null, 0xffffffff);

        self.engine.gfx.context.VSSetShader(self.vso, null, 0);
        self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_data_buffer));

        self.engine.gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        self.engine.gfx.context.IASetInputLayout(self.vso_input_layout);

        self.engine.gfx.context.RSSetState(self.rasterizer_states.double_sided);
        self.engine.gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler));

        {
            const vp_mat = zm.mul(self.camera_view_matrix, self.camera_proj_matrix);

            // Iterate through all entities finding those which contain a mesh to be rendered
            for (self.engine.entities.data.items) |*it| {
                if (it.item_data) |*entity| {
                    // render Doe later
                    if (entity.app.doe) |_| { continue; }

                    if (entity.app.quad_data) |*quad_data| {
                        const ent_model = entity.transform.generate_model_matrix();
                        const mvp = zm.mul(ent_model, vp_mat);
                        var ent_bl_pos = zm.f32x4(
                            -quad_data.size.width / 2.0, 
                            -quad_data.size.height / 2.0, 
                            0.0, 
                            1.0);
                        var ent_tr_pos = zm.f32x4(
                            quad_data.size.width / 2.0, 
                            quad_data.size.height / 2.0, 
                            0.0, 
                            1.0);
                        ent_bl_pos = zm.mul(ent_bl_pos, mvp);
                        ent_tr_pos = zm.mul(ent_tr_pos, mvp);
                        const ent_quad_bounds = zm.f32x4(ent_bl_pos[0], ent_bl_pos[1], ent_tr_pos[0], ent_tr_pos[1]);

                        { // Update quad vs buffer
                            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                            zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.quad_vs_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                            defer self.engine.gfx.context.Unmap(@ptrCast(self.quad_vs_buffer), 0);

                            var buffer_data: *QuadVsBufferStruct = @ptrCast(@alignCast(mapped_subresource.pData));
                            buffer_data.quad_bounds = ent_quad_bounds;
                        }

                        { // Update quad ps buffer
                            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                            zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.quad_ps_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                            defer self.engine.gfx.context.Unmap(@ptrCast(self.quad_ps_buffer), 0);

                            var buffer_data: *QuadPsBufferStruct = @ptrCast(@alignCast(mapped_subresource.pData));
                            buffer_data.colour = quad_data.colour;
                            buffer_data.texture_flags = 0x00;
                            if (quad_data.texture_view != null) buffer_data.texture_flags |= 1 << 0;
                            if (quad_data.flip_texture_h)       buffer_data.texture_flags |= 1 << 1;
                        }

                        if (quad_data.texture_view) |tex| {
                            self.engine.gfx.context.PSSetShaderResources(0, 1, @ptrCast(&tex));
                        }

                        self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.quad_vs_buffer));
                        self.engine.gfx.context.PSSetConstantBuffers(1, 1, @ptrCast(&self.quad_ps_buffer));
                        self.engine.gfx.context.Draw(6, 0);
                    }
                }
            }
        }

        // Draw editor (z = 20)
        self.render_editor_ui_and_create_collisions(rtv);

        // Draw Doe
        if (self.engine.entities.get(self.doe_idx)) |doe| {
            if (doe.app.doe) |*doe_data| {
                _ = doe_data;
                var proj_mat: zm.Mat = undefined;
                var cam_mat: zm.Mat = undefined;
                if (doe.transform.position[2] < 1.0) {
                    // Render Doe in game
                    self.engine.gfx.context.RSSetViewports(1, @ptrCast(&self.game_viewport));
                    proj_mat = self.camera_proj_matrix;
                    cam_mat = self.camera_view_matrix;
                } else {
                    // Render Doe in editor
                    self.engine.gfx.context.RSSetViewports(1, @ptrCast(&self.editor_viewport));
                    proj_mat = zm.orthographicLh(
                        1600.0, 
                        900.0,
                        0.1, 
                        100.1
                    );
                    cam_mat = zm.inverse(zm.translation(1600.0 / 2.0, 900.0 / 2.0, -10.0));
                }

                self.engine.gfx.context.PSSetShader(self.pso, null, 0);

                self.engine.gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), null);
                self.engine.gfx.context.OMSetBlendState(@ptrCast(self.blend_state), null, 0xffffffff);

                self.engine.gfx.context.VSSetShader(self.vso, null, 0);
                self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_data_buffer));

                self.engine.gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
                self.engine.gfx.context.IASetInputLayout(self.vso_input_layout);

                self.engine.gfx.context.RSSetState(self.rasterizer_states.double_sided);
                self.engine.gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler));

                const vp_mat = zm.mul(cam_mat, proj_mat);

                if (doe.app.quad_data) |*quad_data| {
                    const ent_model = doe.transform.generate_model_matrix();
                    const mvp = zm.mul(ent_model, vp_mat);
                    var ent_bl_pos = zm.f32x4(
                        -quad_data.size.width / 2.0, 
                        -quad_data.size.height / 2.0, 
                        0.0, 
                        1.0);
                    var ent_tr_pos = zm.f32x4(
                        quad_data.size.width / 2.0, 
                        quad_data.size.height / 2.0, 
                        0.0, 
                        1.0);
                    ent_bl_pos = zm.mul(ent_bl_pos, mvp);
                    ent_tr_pos = zm.mul(ent_tr_pos, mvp);
                    const ent_quad_bounds = zm.f32x4(ent_bl_pos[0], ent_bl_pos[1], ent_tr_pos[0], ent_tr_pos[1]);

                    { // Update quad vs buffer
                        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                        zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.quad_vs_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                        defer self.engine.gfx.context.Unmap(@ptrCast(self.quad_vs_buffer), 0);

                        var buffer_data: *QuadVsBufferStruct = @ptrCast(@alignCast(mapped_subresource.pData));
                        buffer_data.quad_bounds = ent_quad_bounds;
                    }

                    { // Update quad ps buffer
                        var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                        zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.quad_ps_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                        defer self.engine.gfx.context.Unmap(@ptrCast(self.quad_ps_buffer), 0);

                        var buffer_data: *QuadPsBufferStruct = @ptrCast(@alignCast(mapped_subresource.pData));
                        buffer_data.colour = quad_data.colour;
                        buffer_data.texture_flags = 0x00;
                        if (quad_data.texture_view != null) buffer_data.texture_flags |= 1 << 0;
                        if (quad_data.flip_texture_h)       buffer_data.texture_flags |= 1 << 1;
                    }

                    if (quad_data.texture_view) |tex| {
                        self.engine.gfx.context.PSSetShaderResources(0, 1, @ptrCast(&tex));
                    }

                    self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.quad_vs_buffer));
                    self.engine.gfx.context.PSSetConstantBuffers(1, 1, @ptrCast(&self.quad_ps_buffer));
                    self.engine.gfx.context.Draw(6, 0);
                }
            }
        } else |_| {}
        
        // Draw Physics Debug Wireframes
        if (self.engine.input.get_key(kc.KeyCode.C)) {
            self.engine.physics._interfaces.debug_renderer.draw_bodies(
                self.engine.physics.zphy, 
                rtv, 
                self.engine.gfx.swapchain_size.width,
                self.engine.gfx.swapchain_size.height,
                zm.matToArr(zm.orthographicLh(
                        1600.0, 
                        900.0,
                        0.1, 
                        100.1
                )),
                zm.matToArr(zm.inverse(zm.translation(1600.0/2.0, 900.0/2.0, -10.0))),
            );
        }

        // Render additional debug UI
        self.render_text_over_quad(
            &self.ui.fonts[@intFromEnum(FontEnum.GeistMono)],
            "Hello World.\nThis is the next line.\nWelcome to GodDoe.",
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

    const EditorUiKeyRects = struct {
        scene_inner_rect: Rect,
        file_system_inner_rect: Rect,
        properties_inner_rect: Rect,
        bottom_bar_inner_rect: Rect,
    };

    fn render_editor_ui_and_create_collisions(self: *Self, rtv: *d3d11.IRenderTargetView) void {
        const window_w: f32 = @floatFromInt(self.engine.gfx.swapchain_size.width);
        const window_h: f32 = @floatFromInt(self.engine.gfx.swapchain_size.height);

        const panel_sunk_colour = zm.f32x4(38.0 / 255.0, 44.0 / 255.0, 60.0 / 255.0, 1.0);
        const panel_colour = zm.f32x4(51.0 / 255.0, 57.0 / 255.0, 79.0 / 255.0, 1.0);

        const editor_panel_border = 5;
        const tab_height = 40;

        var next_platform_id: usize = 0;

        const editor_rect = Rect{
            .left = 0.0, 
            .bottom = 0.0, 
            .right = window_w, 
            .top = window_h - tab_height
        };
        
        const left_rect = Rect{
            .left = editor_rect.left + editor_panel_border,
            .bottom = editor_rect.bottom + editor_panel_border,
            .right = (editor_rect.right / 6.0) - (editor_panel_border * 2.0),
            .top = editor_rect.top - editor_panel_border,
        };

        const right_rect = Rect{
            .left = (editor_rect.left + (editor_rect.right * 5.0 / 6.0)) + (editor_panel_border * 2.0),
            .bottom = editor_rect.bottom + editor_panel_border,
            .right = editor_rect.right - editor_panel_border,
            .top = editor_rect.top - editor_panel_border,
        };

        var file_system_area_rect = left_rect;
        file_system_area_rect.top = (file_system_area_rect.top / 2.0) - editor_panel_border;

        var file_system_rect = file_system_area_rect;
        file_system_rect.top = (file_system_area_rect.top - tab_height);

        self.ui.render_quad(
            file_system_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        var file_system_inner_rect = file_system_rect;
        file_system_inner_rect.top -= editor_panel_border;
        file_system_inner_rect.bottom += editor_panel_border;
        file_system_inner_rect.left += editor_panel_border;
        file_system_inner_rect.right -= editor_panel_border;

        self.ui.render_quad(
            file_system_inner_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_sunk_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        var file_system_tab_rect = file_system_area_rect;
        file_system_tab_rect.bottom = file_system_area_rect.top - tab_height;
        file_system_tab_rect.top = file_system_tab_rect.bottom + tab_height;
        const file_system_text = "FileSystem";
        const file_system_font_metrics = self.ui.fonts[@intFromEnum(_ui.FontEnum.GeistMono)].text_bounds_2d(
            file_system_text,
            editor_panel_border,
            editor_panel_border + @as(i32, @intFromFloat(window_h / 2.0)) - (editor_panel_border * 2) - tab_height,
            .{
                .size = _ui.Size{.Pixels = 16},
            },
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height
        );
        file_system_tab_rect.right = file_system_tab_rect.left + @as(f32, @floatFromInt(file_system_font_metrics.width)) + 20.0;

        self.ui.render_quad(
            file_system_tab_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );
        self.ui.render_text_2d(
            _ui.FontEnum.GeistMono,
            "FileSystem",
            @intFromFloat(file_system_tab_rect.left + 10.0),
            @intFromFloat(file_system_tab_rect.bottom + (tab_height / 2.0) - @as(f32, @floatFromInt(file_system_font_metrics.height)) / 2.0),
            .{
                .size = _ui.Size{.Pixels = 16},
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        var scene_area_rect = left_rect;
        scene_area_rect.bottom = scene_area_rect.bottom + (scene_area_rect.top / 2.0) + editor_panel_border;

        var scene_rect = scene_area_rect;
        scene_rect.top -= editor_panel_border;
        scene_rect.top = scene_rect.top - tab_height;

        self.ui.render_quad(
            scene_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        var scene_inner_rect = scene_rect;
        scene_inner_rect.top -= editor_panel_border;
        scene_inner_rect.bottom += editor_panel_border;
        scene_inner_rect.left += editor_panel_border;
        scene_inner_rect.right -= editor_panel_border;

        self.ui.render_quad(
            scene_inner_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_sunk_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        var scene_item_y: f32 = 1.0;
        for (self.engine.entities.data.items, 0..) |*entt, entid| {
            if (entt.item_data) |*item| {
                if (item.app.properties) |properties| {
                    const y: f32 = scene_inner_rect.top - 10.0 - (50.0 * scene_item_y);

                    // Underline
                    self.ui.render_quad(
                        (Rect {
                            .top = y - 2,
                            .bottom = y - 4,
                            .left = scene_inner_rect.left + 30.0,
                            .right = scene_inner_rect.right - 50.0,
                        }).toRectPixels(),
                        _ui.QuadRenderer.QuadProperties {
                            .colour = panel_colour,
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    // Name Text
                    self.ui.render_text_2d(
                        _ui.FontEnum.GeistMono,
                        properties.scene_name,
                        @intFromFloat(scene_inner_rect.left + 30.0),
                        @intFromFloat(y),
                        .{
                            .size = _ui.Size{.Pixels = 15},
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    scene_item_y += 1.0;

                    // Move platform
                    self.move_and_activate_properties_platform(
                        &next_platform_id,
                        [3]f32 {
                            scene_inner_rect.left + ((scene_inner_rect.right - scene_inner_rect.left) / 2.0),
                            y,
                            20.0
                        },
                        @intCast(entid),
                        0
                    );

                    // Selected quad on selected entity line
                    if (self.properties_panel_selected_entity.index == entid) {
                        self.ui.render_quad(
                            (Rect {
                                .top = y + 10,
                                .bottom = y,
                                .left = scene_inner_rect.left + 10.0,
                                .right = scene_inner_rect.left + 20.0,
                            }).toRectPixels(),
                            _ui.QuadRenderer.QuadProperties {
                                .colour = zm.f32x4(0.8, 0.8, 0.8, 1.0),
                            },
                            rtv,
                            self.engine.gfx.swapchain_size.width,
                            self.engine.gfx.swapchain_size.height,
                            &self.engine.gfx
                        );
                    }
                }
            }
        }

        var scene_tab_rect = scene_rect;
        scene_tab_rect.bottom = scene_area_rect.top - tab_height - editor_panel_border;
        scene_tab_rect.top = scene_tab_rect.bottom + tab_height;
        const scene_text = "Scene";
        const scene_text_font_metrics = self.ui.fonts[@intFromEnum(_ui.FontEnum.GeistMono)].text_bounds_2d(
            scene_text,
            editor_panel_border,
            editor_panel_border + @as(i32, @intFromFloat(window_h / 2.0)) - (editor_panel_border * 2) - tab_height,
            .{
                .size = _ui.Size{.Pixels = 16},
            },
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height
        );
        scene_tab_rect.right = scene_tab_rect.left + @as(f32, @floatFromInt(scene_text_font_metrics.width)) + 20.0;

        self.ui.render_quad(
            scene_tab_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );
        self.ui.render_text_2d(
            _ui.FontEnum.GeistMono,
            scene_text,
            @intFromFloat(scene_tab_rect.left + 10.0),
            @intFromFloat(scene_tab_rect.bottom + (tab_height / 2.0) - @as(f32, @floatFromInt(scene_text_font_metrics.height)) / 2.0),
            .{
                .size = _ui.Size{.Pixels = 16},
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        const properties_area_rect = right_rect;

        var properties_rect = properties_area_rect;
        properties_rect.top = (properties_area_rect.top - tab_height);

        self.ui.render_quad(
            properties_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        var properties_inner_rect = properties_rect;
        properties_inner_rect.top -= editor_panel_border;
        properties_inner_rect.bottom += editor_panel_border;
        properties_inner_rect.left += editor_panel_border;
        properties_inner_rect.right -= editor_panel_border;

        self.ui.render_quad(
            properties_inner_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_sunk_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        var properties_tab_rect = properties_area_rect;
        properties_tab_rect.bottom = properties_area_rect.top - tab_height;
        properties_tab_rect.top = properties_tab_rect.bottom + tab_height;
        const properties_text = "Properties";
        const properties_font_metrics = self.ui.fonts[@intFromEnum(_ui.FontEnum.GeistMono)].text_bounds_2d(
            properties_text,
            editor_panel_border,
            editor_panel_border + @as(i32, @intFromFloat(window_h / 2.0)) - (editor_panel_border * 2) - tab_height,
            .{
                .size = _ui.Size{.Pixels = 16},
            },
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height
        );
        properties_tab_rect.right = properties_tab_rect.left + @as(f32, @floatFromInt(properties_font_metrics.width)) + 20.0;

        self.ui.render_quad(
            properties_tab_rect.toRectPixels(),
            _ui.QuadRenderer.QuadProperties {
                .colour = panel_colour,
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );
        self.ui.render_text_2d(
            _ui.FontEnum.GeistMono,
            "Properties",
            @intFromFloat(properties_tab_rect.left + 10.0),
            @intFromFloat(properties_tab_rect.bottom + (tab_height / 2.0) - @as(f32, @floatFromInt(properties_font_metrics.height)) / 2.0),
            .{
                .size = _ui.Size{.Pixels = 16},
            },
            rtv,
            self.engine.gfx.swapchain_size.width,
            self.engine.gfx.swapchain_size.height,
            &self.engine.gfx
        );

        // List properties for entity
        var prop_item_y: f32 = 1.0;
        if (self.engine.entities.get(self.properties_panel_selected_entity)) |entt| {
            if (entt.app.properties) |*properties| {
                var arena = std.heap.ArenaAllocator.init(self.engine.general_allocator.allocator());
                defer arena.deinit();
                const alloc = arena.allocator();

                // Name
                self.ui.render_quad(
                    (Rect {
                        .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                        .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                        .left = properties_inner_rect.left + 30.0,
                        .right = properties_inner_rect.right - 50.0,
                    }).toRectPixels(),
                    _ui.QuadRenderer.QuadProperties {
                        .colour = panel_colour,
                    },
                    rtv,
                    self.engine.gfx.swapchain_size.width,
                    self.engine.gfx.swapchain_size.height,
                    &self.engine.gfx
                );
                self.ui.render_text_2d(
                    _ui.FontEnum.GeistMono,
                    std.fmt.allocPrint(alloc, "name: {s}", .{properties.scene_name}) catch unreachable,
                    @intFromFloat(properties_inner_rect.left + 30.0),
                    @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                    .{
                        .size = _ui.Size{.Pixels = 15},
                    },
                    rtv,
                    self.engine.gfx.swapchain_size.width,
                    self.engine.gfx.swapchain_size.height,
                    &self.engine.gfx
                );
                self.move_and_activate_properties_platform(
                    &next_platform_id,
                    [3]f32 {
                        properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                        calc_property_y(properties_inner_rect, prop_item_y),
                        20.0
                    },
                    0,
                    0
                );
                prop_item_y += 1.0;

                // Is God 
                self.ui.render_quad(
                    (Rect {
                        .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                        .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                        .left = properties_inner_rect.left + 30.0,
                        .right = properties_inner_rect.right - 50.0,
                    }).toRectPixels(),
                    _ui.QuadRenderer.QuadProperties {
                        .colour = panel_colour,
                    },
                    rtv,
                    self.engine.gfx.swapchain_size.width,
                    self.engine.gfx.swapchain_size.height,
                    &self.engine.gfx
                );
                self.ui.render_text_2d(
                    _ui.FontEnum.GeistMono,
                    std.fmt.allocPrint(alloc, "is_god: {}", .{properties.is_god}) catch unreachable,
                    @intFromFloat(properties_inner_rect.left + 30.0),
                    @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                    .{
                        .size = _ui.Size{.Pixels = 15},
                    },
                    rtv,
                    self.engine.gfx.swapchain_size.width,
                    self.engine.gfx.swapchain_size.height,
                    &self.engine.gfx
                );
                self.move_and_activate_properties_platform(
                    &next_platform_id,
                    [3]f32 {
                        properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                        calc_property_y(properties_inner_rect, prop_item_y),
                        20.0
                    },
                    0,
                    1
                );
                prop_item_y += 1.0;

                // Max Speed
                if (properties.max_speed) |max_speed| {
                    self.ui.render_quad(
                        (Rect {
                            .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                            .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                            .left = properties_inner_rect.left + 30.0,
                            .right = properties_inner_rect.right - 50.0,
                        }).toRectPixels(),
                        _ui.QuadRenderer.QuadProperties {
                            .colour = panel_colour,
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.ui.render_text_2d(
                        _ui.FontEnum.GeistMono,
                        std.fmt.allocPrint(alloc, "max_speed: {d}", .{max_speed}) catch unreachable,
                        @intFromFloat(properties_inner_rect.left + 30.0),
                        @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                        .{
                            .size = _ui.Size{.Pixels = 15},
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.move_and_activate_properties_platform(
                        &next_platform_id,
                        [3]f32 {
                            properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                            calc_property_y(properties_inner_rect, prop_item_y),
                            20.0
                        },
                        0,
                        2
                    );
                    prop_item_y += 1.0;
                }

                // Acceleration
                if (properties.acceleration) |acceleration| {
                    self.ui.render_quad(
                        (Rect {
                            .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                            .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                            .left = properties_inner_rect.left + 30.0,
                            .right = properties_inner_rect.right - 50.0,
                        }).toRectPixels(),
                        _ui.QuadRenderer.QuadProperties {
                            .colour = panel_colour,
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.ui.render_text_2d(
                        _ui.FontEnum.GeistMono,
                        std.fmt.allocPrint(alloc, "acceleration: {d}", .{acceleration}) catch unreachable,
                        @intFromFloat(properties_inner_rect.left + 30.0),
                        @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                        .{
                            .size = _ui.Size{.Pixels = 15},
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.move_and_activate_properties_platform(
                        &next_platform_id,
                        [3]f32 {
                            properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                            calc_property_y(properties_inner_rect, prop_item_y),
                            20.0
                        },
                        0,
                        3
                    );
                    prop_item_y += 1.0;
                }

                // Velocity
                if (properties.velocity) |vel| {
                    self.ui.render_quad(
                        (Rect {
                            .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                            .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                            .left = properties_inner_rect.left + 30.0,
                            .right = properties_inner_rect.right - 50.0,
                        }).toRectPixels(),
                        _ui.QuadRenderer.QuadProperties {
                            .colour = panel_colour,
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.ui.render_text_2d(
                        _ui.FontEnum.GeistMono,
                        std.fmt.allocPrint(alloc, "velocity: {d}", .{vel}) catch unreachable,
                        @intFromFloat(properties_inner_rect.left + 30.0),
                        @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                        .{
                            .size = _ui.Size{.Pixels = 15},
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.move_and_activate_properties_platform(
                        &next_platform_id,
                        [3]f32 {
                            properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                            calc_property_y(properties_inner_rect, prop_item_y),
                            20.0
                        },
                        0,
                        4
                    );
                    prop_item_y += 1.0;
                }

                // health points
                if (properties.health_points) |hp| {
                    self.ui.render_quad(
                        (Rect {
                            .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                            .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                            .left = properties_inner_rect.left + 30.0,
                            .right = properties_inner_rect.right - 50.0,
                        }).toRectPixels(),
                        _ui.QuadRenderer.QuadProperties {
                            .colour = panel_colour,
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.ui.render_text_2d(
                        _ui.FontEnum.GeistMono,
                        std.fmt.allocPrint(alloc, "health_points: {d}", .{hp}) catch unreachable,
                        @intFromFloat(properties_inner_rect.left + 30.0),
                        @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                        .{
                            .size = _ui.Size{.Pixels = 15},
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.move_and_activate_properties_platform(
                        &next_platform_id,
                        [3]f32 {
                            properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                            calc_property_y(properties_inner_rect, prop_item_y),
                            20.0
                        },
                        0,
                        5
                    );
                    prop_item_y += 1.0;
                }

                // attack damage
                if (properties.attack_damage) |ad| {
                    self.ui.render_quad(
                        (Rect {
                            .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                            .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                            .left = properties_inner_rect.left + 30.0,
                            .right = properties_inner_rect.right - 50.0,
                        }).toRectPixels(),
                        _ui.QuadRenderer.QuadProperties {
                            .colour = panel_colour,
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.ui.render_text_2d(
                        _ui.FontEnum.GeistMono,
                        std.fmt.allocPrint(alloc, "attack_damage: {d}", .{ad}) catch unreachable,
                        @intFromFloat(properties_inner_rect.left + 30.0),
                        @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                        .{
                            .size = _ui.Size{.Pixels = 15},
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.move_and_activate_properties_platform(
                        &next_platform_id,
                        [3]f32 {
                            properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                            calc_property_y(properties_inner_rect, prop_item_y),
                            20.0
                        },
                        0,
                        6
                    );
                    prop_item_y += 1.0;
                }

                // attack interval
                if (properties.attack_interval) |at| {
                    self.ui.render_quad(
                        (Rect {
                            .top = calc_property_y(properties_inner_rect, prop_item_y) - 2,
                            .bottom = calc_property_y(properties_inner_rect, prop_item_y) - 4,
                            .left = properties_inner_rect.left + 30.0,
                            .right = properties_inner_rect.right - 50.0,
                        }).toRectPixels(),
                        _ui.QuadRenderer.QuadProperties {
                            .colour = panel_colour,
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.ui.render_text_2d(
                        _ui.FontEnum.GeistMono,
                        std.fmt.allocPrint(alloc, "attack_interval: {d}", .{at}) catch unreachable,
                        @intFromFloat(properties_inner_rect.left + 30.0),
                        @intFromFloat(calc_property_y(properties_inner_rect, prop_item_y)),
                        .{
                            .size = _ui.Size{.Pixels = 15},
                        },
                        rtv,
                        self.engine.gfx.swapchain_size.width,
                        self.engine.gfx.swapchain_size.height,
                        &self.engine.gfx
                    );
                    self.move_and_activate_properties_platform(
                        &next_platform_id,
                        [3]f32 {
                            properties_inner_rect.left + ((properties_inner_rect.right - properties_inner_rect.left) / 2.0),
                            calc_property_y(properties_inner_rect, prop_item_y),
                            20.0
                        },
                        0,
                        7
                    );
                    prop_item_y += 1.0;
                }
            }
        } else |_| {}

        // Move remaining platforms to initial position
        for (next_platform_id..MAX_PLATFORMS) |pid| {
            var vpid = pid;
            self.move_and_activate_properties_platform(
                &vpid, [3]f32 { 0.0, 0.0, -100.0 }, 0, 0
            );
        }

        // Create editor collisions if they have not yet been created.
        // This feels so bad.
        if (!self.editor_phys_created) {
            const editor_ui_rects = EditorUiKeyRects {
                .scene_inner_rect = scene_inner_rect,
                .file_system_inner_rect = file_system_inner_rect,
                .properties_inner_rect = properties_inner_rect,
                .bottom_bar_inner_rect = undefined,
            };
            self.create_editor_collisions(editor_ui_rects) catch unreachable;
            self.editor_phys_created = true;
        }
    }

    fn calc_property_y(properties_inner_rect: Rect, prop_item_y: f32) f32 {
        return properties_inner_rect.top - 10.0 - (50.0 * prop_item_y);
    }

    fn move_and_activate_properties_platform(
        self: *Self, 
        next_platform_id: *usize, 
        position: [3]f32,
        entity_id: u8,
        property_id: u8
    ) void {
        const platform_id = self.scene_and_properties_platforms[next_platform_id.*];
        next_platform_id.* += 1;

        // Move platform down slightly
        var adjusted_position = position;
        adjusted_position[1] -= 4;

        const body_interface = self.engine.physics.zphy.getBodyInterfaceMut();
        body_interface.setPosition(platform_id, adjusted_position, .activate);
        PhysicsBodyUserBitfield.setBodyIdUserData(self.engine.physics.zphy, platform_id, 
            PhysicsBodyUserBitfield {
                .doe_can_jump_through = true,
                .doe_can_drop_through = true,
                .entity_id = entity_id,
                .property_id = property_id,
            }
        );
    }

    fn create_editor_physics_box_from_rect(self: *Self, rect: Rect) !void {
        const box_settings = try zphy.BoxShapeSettings.create([3]f32 { 
            0.5, 
            0.5,
            1.0
        });
        defer box_settings.release();
        const border_size = 5.0;

        var topid: zphy.BodyId = undefined;
        var bottomid: zphy.BodyId = undefined;
        var leftid: zphy.BodyId = undefined;
        var rightid: zphy.BodyId = undefined;
        { // Top/Bottom
            const scaled_settings = try zphy.DecoratedShapeSettings.createScaled(box_settings.asShapeSettings(), [3]f32{
                rect.right - rect.left,
                border_size,
                1.0
            });
            defer scaled_settings.release();

            const shape = try scaled_settings.createShape();
            defer shape.release();

            // Top
            topid = try self.engine.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = [4]f32 {
                    rect.left + ((rect.right - rect.left) / 2.0),
                    rect.top + (border_size / 2.0),
                    20.0,
                    1.0
                },
                .rotation = zm.qidentity(),
                .shape = shape,
                .motion_type = .static,
                .object_layer = ph.object_layers.non_moving,
            }, .activate);
            PhysicsBodyUserBitfield.setBodyIdUserData(
                self.engine.physics.zphy,
                topid,
                PhysicsBodyUserBitfield {
                    .doe_can_jump_through = true,
                    .doe_can_drop_through = true,
                }
            );

            // Bottom
            bottomid = try self.engine.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = [4]f32 {
                    rect.left + ((rect.right - rect.left) / 2.0),
                    rect.bottom - (border_size / 2.0),
                    20.0,
                    1.0
                },
                .rotation = zm.qidentity(),
                .shape = shape,
                .motion_type = .static,
                .object_layer = ph.object_layers.non_moving,
            }, .activate);
            PhysicsBodyUserBitfield.setBodyIdUserData(
                self.engine.physics.zphy,
                bottomid,
                PhysicsBodyUserBitfield {
                    .doe_can_jump_through = true,
                    .doe_can_drop_through = true,
                }
            );
        }

        { // Left/Right
            const scaled_settings = try zphy.DecoratedShapeSettings.createScaled(box_settings.asShapeSettings(), [3]f32{
                border_size,
                rect.top - rect.bottom,
                1.0
            });
            defer scaled_settings.release();

            const shape = try scaled_settings.createShape();
            defer shape.release();

            // Left
            leftid = try self.engine.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = [4]f32 {
                    rect.left - (border_size / 2.0),
                    rect.bottom + ((rect.top - rect.bottom) / 2.0),
                    20.0,
                    1.0
                },
                .rotation = zm.qidentity(),
                .shape = shape,
                .motion_type = .static,
                .object_layer = ph.object_layers.non_moving,
            }, .activate);

            // Right
            rightid = try self.engine.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
                .position = [4]f32 {
                    rect.right + (border_size / 2.0),
                    rect.bottom + ((rect.top - rect.bottom) / 2.0),
                    20.0,
                    1.0
                },
                .rotation = zm.qidentity(),
                .shape = shape,
                .motion_type = .static,
                .object_layer = ph.object_layers.non_moving,
            }, .activate);
        }
        std.log.info("top id is {x}, bottom id is {x}, left id is {x}, right id is {x}", .{topid, bottomid, leftid, rightid});
    }

    fn create_editor_collisions(self: *Self, rects: EditorUiKeyRects) !void {
        try self.create_editor_physics_box_from_rect(rects.scene_inner_rect);
        try self.create_editor_physics_box_from_rect(rects.file_system_inner_rect);
        try self.create_editor_physics_box_from_rect(rects.properties_inner_rect);
        // try self.create_editor_physics_box_from_rect(rects.bottom_bar_inner_rect);

        // Top of game scene
        const box_settings = try zphy.BoxShapeSettings.create([3]f32 { 
            0.5, 
            0.5,
            1.0
        });
        defer box_settings.release();
        const border_size = 5.0;

        const scaled_settings = try zphy.DecoratedShapeSettings.createScaled(box_settings.asShapeSettings(), [3]f32{
            rects.properties_inner_rect.left - rects.scene_inner_rect.right,
            border_size,
            1.0
        });
        defer scaled_settings.release();

        const shape = try scaled_settings.createShape();
        defer shape.release();

        const topgameid = try self.engine.physics.zphy.getBodyInterfaceMut().createAndAddBody(zphy.BodyCreationSettings {
            .position = [4]f32 {
                rects.scene_inner_rect.right + ((rects.properties_inner_rect.left - rects.scene_inner_rect.right) / 2.0),
                rects.scene_inner_rect.top + (border_size / 2.0),
                20.0,
                1.0
            },
            .rotation = zm.qidentity(),
            .shape = shape,
            .motion_type = .static,
            .object_layer = ph.object_layers.non_moving,
        }, .activate);
        PhysicsBodyUserBitfield.setBodyIdUserData(
            self.engine.physics.zphy,
            topgameid,
            PhysicsBodyUserBitfield {
                .doe_can_jump_through = true,
                .doe_can_drop_through = true,
            }
        );
        
    }

    pub fn create_depth_stencil_view(eng: *engine.Engine(Self)) !*d3d11.IDepthStencilView {
        const depth_format = zwin32.dxgi.FORMAT.D24_UNORM_S8_UINT;
        const depth_texture_desc = d3d11.TEXTURE2D_DESC {
            .Width = @intCast(eng.gfx.swapchain_size.width),
            .Height = @intCast(eng.gfx.swapchain_size.height),
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = depth_format,
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
            .Format = depth_format,
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

    fn transform_game_pos_to_editor_pos(self: *const Self, game_pos: zm.F32x4) zm.F32x4 {
        const game_vp_mat = zm.mul(self.camera_view_matrix, self.camera_proj_matrix);
        var editor_pos = zm.mul(game_pos, game_vp_mat);
        editor_pos = editor_pos * zm.f32x4(0.5, 0.5, 1.0, 1.0); 
        editor_pos = editor_pos + zm.f32x4(0.5, 0.5, 0.0, 0.0);
        editor_pos = editor_pos * zm.f32x4(self.game_viewport.Width, self.game_viewport.Height, 1.0, 1.0);
        editor_pos = editor_pos + zm.f32x4(
            self.game_viewport.TopLeftX, 
            self.editor_viewport.Height - (self.game_viewport.TopLeftY + self.game_viewport.Height),
            0.0,
            0.0
        );

        editor_pos[2] = 20.0;
        return editor_pos;
    }

    fn transform_editor_pos_to_game_pos(self: *const Self, editor_pos: zm.F32x4) zm.F32x4 {
        var game_pos = editor_pos - zm.f32x4(
            self.game_viewport.TopLeftX, 
            self.editor_viewport.Height - (self.game_viewport.TopLeftY + self.game_viewport.Height),
            0.0,
            0.0
        );

        game_pos = game_pos - zm.f32x4(self.game_viewport.Width * 0.5, self.game_viewport.Height * 0.5, 1.0, 1.0);
        game_pos = game_pos - self.camera_view_matrix[3];

        game_pos[2] = 0.0;
        game_pos[3] = 1.0;
        return game_pos;
    }

    fn game_pos_is_within_view(self: *const Self, game_pos: zm.F32x4) bool {
        const half_size = zm.f32x4(self.game_viewport.Width, self.game_viewport.Height, 0.0, 0.0) * zm.f32x4(0.5, 0.5, 1.0, 1.0);
        const cam_min = self.camera_view_matrix[3] - half_size;
        const cam_max = self.camera_view_matrix[3] + half_size;
        return  game_pos[0] >= cam_min[0] and game_pos[0] <= cam_max[0] and
                game_pos[1] >= cam_min[1] and game_pos[1] <= cam_max[1];
    }

    fn doe_perform_charge(self: *Self, desired_movement: [3]f32) void {
        const charge_distance = 50.0;

        if (self.engine.entities.get(self.doe_idx)) |doe| {
            if (doe.app.doe) |*doe_data| {
                if (desired_movement[0] != 0.0) {
                    const pos = doe_data.character.getPosition();

                    // Check collisions in doe current Space
                    const doe_is_in_editor = (pos[2] > 19.0);
                    if (!doe_is_in_editor) {
                        // game to editor
                        var game_pos = zm.loadArr3(pos);
                        game_pos[3] = 1.0;

                        const current_space_ray_result = self.engine.physics.zphy.getNarrowPhaseQuery().castRay(
                            .{
                                .origin = [4]f32{pos[0], pos[1], pos[2], 1.0},
                                .direction = [4]f32{ desired_movement[0] * charge_distance, 0.0, 0.0, 0.0 },
                            },
                            .{}
                        );

                        if (current_space_ray_result.has_hit) {
                            std.log.info("charge hit in current game space!", .{});
                            doe_data.character.setPosition([3]f32{pos[0] + (desired_movement[0] * charge_distance), pos[1], pos[2]});

                            return;
                        }

                        const editor_pos = self.transform_game_pos_to_editor_pos(game_pos);
                        const editor_space_ray_result = self.engine.physics.zphy.getNarrowPhaseQuery().castRay(
                            .{
                                .origin = zm.vecToArr4(editor_pos),
                                .direction = [4]f32{ desired_movement[0] * charge_distance, 0.0, 0.0, 0.0 },
                            },
                            .{}
                        );

                        if (editor_space_ray_result.has_hit) {
                            std.log.info("charge hit in editor space!", .{});

                            doe_data.character.setPosition([3]f32{editor_pos[0] + desired_movement[0] * charge_distance, editor_pos[1], editor_pos[2]});
                            std.log.info("game pos {} to editor pos {}", .{game_pos, editor_pos});

                            return;
                        }
                    } else {
                        // editor to game
                        var editor_pos = zm.loadArr3(pos);
                        editor_pos[3] = 1.0;

                        const game_pos = self.transform_editor_pos_to_game_pos(editor_pos + zm.f32x4(desired_movement[0] * charge_distance, 0.0, 0.0, 0.0));

                        if (self.game_pos_is_within_view(game_pos)) {
                            // do charge
                            doe_data.character.setPosition([3]f32{game_pos[0], game_pos[1], game_pos[2]});
                            std.log.info("editor pos {} to game pos {}", .{editor_pos, game_pos});

                            return;
                        }
                    }
                }
            }
        } else |_| {}
    }
};

const DoeCharacterContactListener = extern struct {
    usingnamespace zphy.CharacterContactListener.Methods(@This());
    __v: *const zphy.CharacterContactListener.VTable = &vtable,

    physics_system: *zphy.PhysicsSystem,
    drop_key_pressed: bool = false,

    const vtable = zphy.CharacterContactListener.VTable{ 
        .OnAdjustBodyVelocity = OnAdjustBodyVelocity,
        .OnContactValidate = OnContactValidate,
        .OnContactAdded = OnContactAdded,
        .OnContactSolve = OnContactSolve,
    };

    fn cast(pself: *zphy.CharacterContactListener) *DoeCharacterContactListener {
        return @ptrCast(pself);
    }

    fn OnAdjustBodyVelocity(
        self: *zphy.CharacterContactListener,
        character: *const zphy.CharacterVirtual,
        body: *const zphy.Body,
        io_linear_velocity: *[3]f32,
        io_angular_velocity: *[3]f32,
    ) callconv(.C) void {
        _ = self;
        _ = character;
        _ = body;
        _ = io_linear_velocity;
        _ = io_angular_velocity;
    }

    fn OnContactValidate(
        self: *zphy.CharacterContactListener,
        character: *const zphy.CharacterVirtual,
        body: *const zphy.BodyId,
        sub_shape_id: *const zphy.SubShapeId,
    ) callconv(.C) bool {
        // _ = self;
        // _ = character;
        // _ = body;
        _ = sub_shape_id;
        if (PhysicsBodyUserBitfield.getBodyIdUserData(cast(self).physics_system, body.*)) |user_data| {
            if (user_data.doe_can_drop_through and cast(self).drop_key_pressed) {
                return false;
            }
            if (user_data.doe_can_jump_through) {
                if (character.getGroundBodyID()) |ground_body_id| {
                    if (ground_body_id == body.*) {
                        const ground_normal = zm.loadArr3(character.getGroundNormal());
                        const dot = zm.dot3(ground_normal, zm.f32x4(0.0, 1.0, 0.0, 0.0))[0];
                        return @abs(dot - 1.0) < 0.2;
                    }
                }
            }
        }
        return true;
    }
    
    fn OnContactAdded(
        self: *zphy.CharacterContactListener,
        character: *const zphy.CharacterVirtual,
        body: *const zphy.BodyId,
        sub_shape_id: *const zphy.SubShapeId,
        contact_position: *const [3]zphy.Real,
        contact_normal: *const [3]f32,
        io_settings: *zphy.CharacterContactSettings,
    ) callconv(.C) void {
        _ = self;
        _ = character;
        _ = body;
        _ = sub_shape_id;
        _ = contact_position;
        _ = contact_normal;
        _ = io_settings;
    }

    fn OnContactSolve(
        self: *zphy.CharacterContactListener,
        character: *const zphy.CharacterVirtual,
        body: *const zphy.BodyId,
        sub_shape_id: *const zphy.SubShapeId,
        contact_position: *const [3]zphy.Real,
        contact_normal: *const [3]f32,
        contact_velocity: *const [3]f32,
        contact_material: *const zphy.Material,
        character_velocity: *const [3]f32,
        character_velocity_out: *[3]f32,
    ) callconv(.C) void {
        _ = self;
        _ = character;
        _ = body;
        _ = sub_shape_id;
        _ = contact_position;
        _ = contact_normal;
        _ = contact_velocity;
        _ = contact_material;
        _ = character_velocity;
        _ = character_velocity_out;
    }
};

const Rect = struct {
    left: f32,
    bottom: f32,
    right: f32,
    top: f32,

    pub fn toRectPixels(self: *const Rect) _ui.RectPixels {
        return _ui.RectPixels {
            .left = @intFromFloat(self.left),
            .bottom = @intFromFloat(self.bottom),
            .width = @intFromFloat(self.right - self.left),
            .height = @intFromFloat(self.top - self.bottom),
        };
    }
};

const PhysicsBodyUserBitfield = packed struct(u64) {
    doe_can_drop_through: bool = false,
    doe_can_jump_through: bool = false,
    entity_id: u8 = 0,
    property_id: u8 = 0,

    _padding: u46 = 0,

    pub fn setBodyIdUserData(physics_system: *zphy.PhysicsSystem, body_id: zphy.BodyId, user_data: PhysicsBodyUserBitfield) void {
        const lock_interface = physics_system.getBodyLockInterface();

        var write_lock: zphy.BodyLockWrite = .{};
        write_lock.lock(lock_interface, body_id);
        defer write_lock.unlock();

        if (write_lock.body) |locked_body| {
            locked_body.setUserData(@bitCast(user_data));
        }
    }

    pub fn getBodyIdUserData(physics_system: *const zphy.PhysicsSystem, body_id: zphy.BodyId) ?PhysicsBodyUserBitfield {
        const lock_interface = physics_system.getBodyLockInterfaceNoLock();

        var read_lock: zphy.BodyLockRead = .{};
        read_lock.lock(lock_interface, body_id);
        defer read_lock.unlock();

        if (read_lock.body) |locked_body| {
            return @as(PhysicsBodyUserBitfield, @bitCast(locked_body.getUserData()));
        }

        return null;
    }
};

const ContactListener = extern struct {
    usingnamespace zphy.ContactListener.Methods(@This());
    __v: *const zphy.ContactListener.VTable = &vtable,

    const vtable = zphy.ContactListener.VTable{ 
        .onContactValidate = _onContactValidate,
        .onContactPersisted = _OnContactPersisted,
    };

    fn _onContactValidate(
        self: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        base_offset: *const [3]zphy.Real,
        collision_result: *const zphy.CollideShapeResult,
    ) callconv(.C) zphy.ValidateResult {
        _ = self;
        _ = body1;
        _ = body2;
        _ = base_offset;
        _ = collision_result;
        return .accept_all_contacts;
    }

    fn _OnContactPersisted(
        self: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        manifold: *const zphy.ContactManifold,
        settings: *zphy.ContactSettings
    ) callconv(.C) void {
        _ = self;
        // _ = body1;
        // _ = body2;
        _ = manifold;
        _ = settings;
        std.log.info("{} persisted {}", .{body1.getId(), body2.getId()});
    }
};
