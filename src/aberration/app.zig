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
};

pub const Engine = engine.Engine(AberrationApp);
pub const AberrationApp = struct {
    const Self = @This();

    pub const EntityData = struct {
        quad_data: ?struct {
            colour: zm.F32x4,
            size: struct { width: f32, height: f32, }
        } = null,
        phys: ?struct {
            dynamic: bool = false,
            velocity: zm.F32x4 = zm.f32x4s(0.0),
            is_grounded: bool = false,
            can_doe_drop_through: bool = false,
        } = null,
        is_doe: bool = false,

        pub fn deinit(self: *EntityData) void {
            _ = self;
        }
    };

    const textured_quad_shader = @embedFile("textured_quad_shader.hlsl");

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
    rasterizer_states: RasterizationStates,
    
    camera_data_buffer: *d3d11.IBuffer,
    camera_idx: ent.GenerationalIndex,
    camera_view_matrix: zm.Mat,
    camera_proj_matrix: zm.Mat,

    quad_vs_buffer: *d3d11.IBuffer,
    quad_ps_buffer: *d3d11.IBuffer,

    doe_idx: ent.GenerationalIndex,

    ui: _ui.UiRenderer,

    pub fn deinit(self: *Self) void {
        std.log.info("App deinit!", .{});
        for (self.engine.entities.data.items) |*maybe_ent| {
            if (maybe_ent.item_data) |*en| {
                en.app.deinit();
            }
        }

        self.engine.gfx.context.Flush();
        self.ui.deinit();

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

        eng.physics.zphy.optimizeBroadPhase();

        var ui = try _ui.UiRenderer.init(eng.general_allocator.allocator(), &eng.gfx);
        errdefer ui.deinit();

        const doe_idx = try eng.entities.insert(.{});
        if (eng.entities.get(doe_idx)) |doe| {
            doe.app.is_doe = true;
            doe.transform.position = zm.f32x4(0.0, 100.0, 0.0, 1.0);
            doe.app.quad_data = .{
                .colour = zm.f32x4(1.0,1.0,1.0,1.0),
                .size = .{ .width = 20.0, .height = 20.0, },
            };
            doe.app.phys = .{ .dynamic = true, };
        } else |_| { unreachable; }

        // ground
        _ = try eng.entities.insert(.{
            .transform = Transform {
                .position = zm.f32x4(0.0, -50.0, 0.0, 1.0),
            },
            .app = .{
                .quad_data = .{
                    .colour = zm.f32x4(0.3, 0.3, 0.3, 1.0),
                    .size = .{ .width = 5000.0, .height = 100.0, },
                },
                .phys = .{},
            },
        });

        return Self {
            .engine = eng,
            .depth_stencil_view = depth_stencil_view,
            .vso = vso,
            .pso = pso,
            .vso_input_layout = vso_input_layout,
            .rasterizer_states = rasterization_states,

            .camera_data_buffer = camera_data_buffer,
            .camera_idx = camera_transform_idx,
            .camera_view_matrix = zm.inverse(zm.identity()),
            .camera_proj_matrix = zm.orthographicLh(
                @floatFromInt(eng.gfx.swapchain_size.width), 
                @floatFromInt(eng.gfx.swapchain_size.height),
                0.1, 
                100.1
            ),

            .quad_vs_buffer = quad_vs_buffer,
            .quad_ps_buffer = quad_ps_buffer,

            .doe_idx = doe_idx,

            .ui = ui,
        };
    }

    fn update(self: *Self) void {
        if (self.engine.entities.get(self.doe_idx)) |doe| {
            if (doe.app.phys) |*phys| {
                if (self.engine.input.get_key(kc.KeyCode.A)) {
                    phys.velocity[0] -= 1.0;
                    phys.velocity[0] = @max(-30.0, phys.velocity[0]);
                }
                if (self.engine.input.get_key(kc.KeyCode.D)) {
                    phys.velocity[0] += 1.0;
                    phys.velocity[0] = @min(30.0, phys.velocity[0]);
                }
                if (self.engine.input.get_key_down(kc.KeyCode.Space)) {
                    if (phys.is_grounded) {
                        phys.velocity[1] = 60.0;
                    }
                }
            }
        } else |_| {}

        // Update physics. If frame time is greater than 1 second then skip physics for this frame.
        // @TODO: It is most likely we loaded something in and caused a spike... Fix this permanently 
        // by adding async loads and/or loading screens.
        if (self.engine.time.last_frame_time_s > 1.0) {
            std.log.warn("Skipping physics for this frame since the frame time was too large at {}s", .{self.engine.time.last_frame_time_s});
        } else {
            // self.engine.physics.zphy.update(self.engine.time.delta_time_f32(), .{}) 
            //     catch std.log.err("Unable to update physics", .{});

            for (self.engine.entities.data.items) |*enti| {
                if (enti.item_data) |*item| {
                    if (item.app.phys) |*phys| {
                        if (phys.dynamic) {
                            phys.is_grounded = false;
                            phys.velocity[1] += (-9.8 * 20.0 * self.engine.time.delta_time_f32());
                            item.transform.position += (phys.velocity * zm.f32x4s(self.engine.time.delta_time_f32()));

                            if (item.transform.position[1] < 10.0) { 
                                phys.is_grounded = true;
                                item.transform.position[1] = 10.0;
                                phys.velocity[1] = 0.0;
                            }
                        }
                    }
                }
            }

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

        const window_w: f32 = @floatFromInt(self.engine.gfx.swapchain_size.width);
        const window_h: f32 = @floatFromInt(self.engine.gfx.swapchain_size.height);

        const editor_viewport = d3d11.VIEWPORT {
            .Width = window_w,
            .Height = window_h,
            .TopLeftX = 0.0,
            .TopLeftY = 0.0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        self.engine.gfx.context.RSSetViewports(1, @ptrCast(&editor_viewport));

        const game_viewport = d3d11.VIEWPORT {
            .Width = window_w / 2.0,
            .Height = window_h / 2.0,
            .TopLeftX = window_w / 4.0,
            .TopLeftY = window_h * 0.1,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };

        self.camera_proj_matrix = zm.orthographicLh(
            game_viewport.Width, 
            game_viewport.Height,
            0.1, 
            100.1
        );

        self.engine.gfx.context.RSSetViewports(1, @ptrCast(&game_viewport));

        self.engine.gfx.context.PSSetShader(self.pso, null, 0);

        self.engine.gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), self.depth_stencil_view);
        self.engine.gfx.context.OMSetBlendState(null, null, 0xffffffff);

        self.engine.gfx.context.VSSetShader(self.vso, null, 0);
        self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_data_buffer));

        self.engine.gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        self.engine.gfx.context.IASetInputLayout(self.vso_input_layout);

        self.engine.gfx.context.RSSetState(self.rasterizer_states.double_sided);

        const vp_mat = zm.mul(self.camera_proj_matrix, self.camera_view_matrix);

        // Iterate through all entities finding those which contain a mesh to be rendered
        for (self.engine.entities.data.items) |*it| {
            if (it.item_data) |*entity| {
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
                    }

                    self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.quad_vs_buffer));
                    self.engine.gfx.context.PSSetConstantBuffers(1, 1, @ptrCast(&self.quad_ps_buffer));
                    self.engine.gfx.context.Draw(6, 0);
                }
            }
        }

        // Draw Physics Debug Wireframes
        // if (self.engine.input.get_key(kc.KeyCode.C)) {
        //     if (self.engine.entities.get(self.camera_idx)) |camera_entity| {
        //         _ = camera_entity;
        //         self.engine.physics._interfaces.debug_renderer.draw_bodies(
        //             self.engine.physics.zphy, 
        //             rtv, 
        //             self.engine.gfx.swapchain_size.width,
        //             self.engine.gfx.swapchain_size.height,
        //             &self.camera, 
        //             zm.matToArr(self.camera.view_matrix),
        //         );
        //     } else |_| {}
        // }

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
};

