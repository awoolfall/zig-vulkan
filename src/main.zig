const std = @import("std");
const zwin32 = @import("zwin32");
const zm = @import("zmath");
const w32 = zwin32.w32;
const d3d11 = zwin32.d3d11;

const engine = @import("engine.zig");
const Transform = engine.Transform;
const window = @import("window.zig");
const kc = @import("input/keycode.zig");
const cm = @import("engine/camera.zig");
const ms = @import("engine/mesh.zig");
const ent = @import("engine/entity.zig");

const CameraStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
};

const EntityData = struct {
    transform: Transform = Transform.new(),
    mesh: ?*ms.Mesh = null,
    name: ?[]u8 = null,
    parent: ?ent.GenerationalIndex = null,
    children: ?std.ArrayList(ent.GenerationalIndex) = null,
};

const App = struct {
    const Self = @This();

    const vertices: [3 * 3]zwin32.w32.FLOAT = [_]zwin32.w32.FLOAT{
        0.0, 0.5, 0.0,
        -0.5, -0.5, 0.0,
        0.5, -0.5, 0.0,
    };

    engine: *engine.Engine(Self),

    depth_stencil_view: *d3d11.IDepthStencilView,

    vso: *d3d11.IVertexShader,
    pso: *d3d11.IPixelShader,
    vso_input_layout: *d3d11.IInputLayout,
    vertex_buffer: *d3d11.IBuffer,
    rasterizer_state: *d3d11.IRasterizerState,
    
    camera_data_buffer: *d3d11.IBuffer,
    camera: cm.Camera,
    camera_idx: ent.GenerationalIndex,

    model_buffer: *d3d11.IBuffer,
    model_idx: ent.GenerationalIndex,

    chara_model: ms.Model,
    tree_model: ms.Model,
    // entity_transforms: ent.GenerationalList(Transform),
    entities: ent.GenerationalList(EntityData),
    general_allocator: *std.heap.GeneralPurposeAllocator(.{}),

    pub fn init(eng: *engine.Engine(Self)) !Self {
        std.log.info("App init!", .{});

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

        // Load Shader file
        var shader_file = try std.fs.cwd().openFile("../../src/shader.hlsl", std.fs.File.OpenFlags { .mode = std.fs.File.OpenMode.read_only });
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

        var ps_blob: *zwin32.d3d.IBlob = undefined;
        try zwin32.hrErrorOnFail(zwin32.d3dcompiler.D3DCompile(&shader_buffer[0], shader_file_size, null, null, null, "ps_main", "ps_5_0", 0, 0, @ptrCast(&ps_blob), null));
        defer _ = ps_blob.Release();

        // Create vertex and pixel shaders
        var pso: *d3d11.IPixelShader = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&pso)));

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

        // Define vertex buffer input
        const vertex_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(f32) * 3 * 3,
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        var vertex_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&vertex_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = &vertices, }, @ptrCast(&vertex_buffer)));

        // Define rasterizer state
        const rasterizer_state_desc = d3d11.RASTERIZER_DESC {
            .FillMode = d3d11.FILL_MODE.SOLID,
            .CullMode = d3d11.CULL_MODE.BACK,
        };
        var rasterizer_state: *d3d11.IRasterizerState = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterizer_state)));

        // Create camera constant buffer
        const camera_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(CameraStruct),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var camera_data_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&camera_constant_buffer_desc, null, @ptrCast(&camera_data_buffer)));

        var general_allocator = try std.heap.page_allocator.create(std.heap.GeneralPurposeAllocator(.{}));
        general_allocator.* = std.heap.GeneralPurposeAllocator(.{}){};

        // Create the entities generational list
        var entities = try ent.GenerationalList(EntityData).init(general_allocator.allocator());

        // Create the camera entity
        var camera_transform_idx = try entities.insert(.{});
        (try entities.get(camera_transform_idx)).transform.position = zm.f32x4(0.0, 0.0, -1.0, 0.0);

        // Load model
        const chara_model = try ms.Model.init_from_file(general_allocator.allocator(), "../../res/SK_Character_Dummy_Male_01.glb", eng.gfx.device);
        const tree_model = try ms.Model.init_from_file(general_allocator.allocator(), "../../res/SM_Generic_Tree_04.glb", eng.gfx.device);

        // Use the model as a 'prefab' of sorts and create a number of entities from its nodes
        var model_root_idx: ent.GenerationalIndex = undefined;
        {
            const new_entities = try general_allocator.allocator().alloc(ent.GenerationalIndex, chara_model.nodes_list.len);
            defer general_allocator.allocator().free(new_entities);

            for (chara_model.nodes_list, 0..) |*n, n_idx| {
                const ent_idx = try entities.insert(EntityData {
                    .name = n.name,
                    .transform = n.transform,
                    .mesh = n.mesh,
                });
                new_entities[n_idx] = ent_idx;
            }

            // Once all the entities have been created we can then assign heirarchy
            for (chara_model.nodes_list, 0..) |*n, n_idx| {
                var entity = entities.get(new_entities[n_idx]) catch unreachable;

                if (n.parent) |p_idx| {
                    entity.parent = new_entities[p_idx];
                }

                if (n.children) |children| {
                    entity.children = try std.ArrayList(ent.GenerationalIndex).initCapacity(general_allocator.allocator(), n.children.?.len);
                    for (children) |c_node_idx| {
                        try entity.children.?.append(new_entities[c_node_idx]);
                    }
                }
            }

            // @TODO: figure out a better way to return new entity data to the user
            // This will be necessary when this scope becomes a function.
            model_root_idx = new_entities[chara_model.root_nodes[0]];
        }
        {
            const new_entities = try general_allocator.allocator().alloc(ent.GenerationalIndex, tree_model.nodes_list.len);
            defer general_allocator.allocator().free(new_entities);

            for (tree_model.nodes_list, 0..) |*n, n_idx| {
                const ent_idx = try entities.insert(EntityData {
                    .name = n.name,
                    .transform = n.transform,
                    .mesh = n.mesh,
                });
                new_entities[n_idx] = ent_idx;
            }

            // Once all the entities have been created we can then assign heirarchy
            for (tree_model.nodes_list, 0..) |*n, n_idx| {
                var entity = entities.get(new_entities[n_idx]) catch unreachable;

                if (n.parent) |p_idx| {
                    entity.parent = new_entities[p_idx];
                }

                if (n.children) |children| {
                    entity.children = try std.ArrayList(ent.GenerationalIndex).initCapacity(general_allocator.allocator(), n.children.?.len);
                    for (children) |c_node_idx| {
                        try entity.children.?.append(new_entities[c_node_idx]);
                    }
                }
            }
        }

        const model_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(zm.Mat),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var model_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(eng.gfx.device.CreateBuffer(&model_constant_buffer_desc, null, @ptrCast(&model_buffer)));
        errdefer _ = model_buffer.Release();

        return Self {
            .engine = eng,
            .entities = entities,
            .depth_stencil_view = depth_stencil_view,
            .vso = vso,
            .pso = pso,
            .vso_input_layout = vso_input_layout,
            .vertex_buffer = vertex_buffer,
            .rasterizer_state = rasterizer_state,

            .camera_data_buffer = camera_data_buffer,
            .camera = cm.Camera {
                .field_of_view_y = 20.0,
                .near_field = 0.1,
                .far_field = 100.0,
                .move_speed = 2.0,
                .mouse_sensitivity = 0.001,
            },
            .camera_idx = camera_transform_idx,

            .model_idx = model_root_idx,
            .model_buffer = model_buffer,

            .chara_model = chara_model,
            .tree_model = tree_model,
            .general_allocator = general_allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("App deinit!", .{});
        for (self.entities.data.items) |*maybe_en| {
            if (maybe_en.*) |*en| {
                if (en.children != null) {
                    en.children.?.deinit();
                }
            }
        }
        self.entities.deinit();

        self.chara_model.deinit();
        self.tree_model.deinit();

        self.engine.gfx.context.Flush();
        _ = self.camera_data_buffer.Release();
        _ = self.model_buffer.Release();
        _ = self.rasterizer_state.Release();
        _ = self.vertex_buffer.Release();
        _ = self.vso_input_layout.Release();
        _ = self.vso.Release();
        _ = self.pso.Release();
        _ = self.depth_stencil_view.Release();

        std.debug.assert(self.general_allocator.deinit() == std.heap.Check.ok);
        std.heap.page_allocator.destroy(self.general_allocator);
    }

    fn update(self: *Self) void {
        // std.log.info("frame time is: {d}ms, fps is {d}", .{
        //     self.engine.time.delta_time_f32() * std.time.ms_per_s,
        //     self.engine.time.get_fps()
        // });

        // Input to move the model around
        if (self.entities.get(self.model_idx)) |model_entity| {
            if (self.engine.input.get_key(kc.KeyCode.ArrowRight)) {
                model_entity.transform.position[0] += self.engine.time.delta_time_f32();
            }
            if (self.engine.input.get_key(kc.KeyCode.ArrowLeft)) {
                model_entity.transform.position[0] -= self.engine.time.delta_time_f32();
            }
        } else |_| {}

        // Camera input and buffer data management
        if (self.entities.get(self.camera_idx)) |camera_entity| {
            self.camera.fly_camera_update(&camera_entity.transform, &self.engine.input, &self.engine.time);

            { // Update camera buffer
                var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.camera_data_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                defer self.engine.gfx.context.Unmap(@ptrCast(self.camera_data_buffer), 0);

                var buffer_data: *CameraStruct = @ptrCast(@alignCast(mapped_subresource.pData));
                buffer_data.view = camera_entity.transform.generate_view_matrix();
                buffer_data.projection = self.camera.generate_perspective_matrix(self.engine.gfx.swapchain_aspect());
            }
        } else |_| {}

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
        self.engine.gfx.context.RSSetState(self.rasterizer_state);

        self.engine.gfx.context.PSSetShader(self.pso, null, 0);

        self.engine.gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), self.depth_stencil_view);
        self.engine.gfx.context.OMSetBlendState(null, null, 0xffffffff);

        self.engine.gfx.context.VSSetShader(self.vso, null, 0);
        self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_data_buffer));

        self.engine.gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        self.engine.gfx.context.IASetInputLayout(self.vso_input_layout);
        var arena_allocator = std.heap.ArenaAllocator.init(self.general_allocator.allocator());
        defer arena_allocator.deinit();
        var arena = arena_allocator.allocator();

        var resolved_transforms = arena.alloc(?zm.Mat, self.entities.data.items.len) catch unreachable;
        @memset(resolved_transforms, null);

        // Iterate through all entities finding those which contain a mesh to be rendered
        for (self.entities.data.items, 0..) |maybe_ent, ent_idx| {
            if (maybe_ent) |entity| {
                // Find the transform of the entity to be rendered taking into account it's parent
                var model_matrix = entity.transform.generate_model_matrix();
                if (entity.parent) |parent_idx| {
                    const parent_model_matrix = recursive_get_model_matrix(parent_idx, &self.entities, resolved_transforms);
                    model_matrix = zm.mul(parent_model_matrix, model_matrix);
                }  
                resolved_transforms[ent_idx] = model_matrix;

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

                        var buffer_data: *zm.Mat = @ptrCast(@alignCast(mapped_subresource.pData));
                        buffer_data.* = model_matrix;
                    }
                    
                    // Set model constant buffer
                    self.engine.gfx.context.VSSetConstantBuffers(1, 1, @ptrCast(&self.model_buffer));

                    // Finally, render the mesh
                    for (m.primitives) |p| {
                        if (p.has_indices()) {
                            self.engine.gfx.context.DrawIndexed(@intCast(p.num_indices), @intCast(p.indices_offset), @intCast(p.pos_offset));
                        } else {
                            self.engine.gfx.context.Draw(@intCast(p.num_vertices), @intCast(p.pos_offset));
                        }
                    }
                }
            }
        }

        self.engine.gfx.end_frame(rtv) catch |err| {
            std.log.err("unable to end frame: {}", .{err});
            return;
        };
        return;
    }

    fn recursive_get_model_matrix(idx: ent.GenerationalIndex, entities: *ent.GenerationalList(EntityData), resolved_transforms: []?zm.Mat) zm.Mat {
        // Return cached transform if available
        if (resolved_transforms[idx.index] != null) {
            return resolved_transforms[idx.index].?;
        }

        // Get entity from generational index
        const entity = entities.get(idx) catch unreachable;

        // generate the parent's local model matrix
        var model_matrix = entity.transform.generate_model_matrix();

        // if the parent also has a parent, recursively get their model matrix and combine
        if (entity.parent) |parent_idx| {
            model_matrix = zm.mul(
                recursive_get_model_matrix(parent_idx, entities, resolved_transforms),
                model_matrix,
            );
        }
        
        // cache the model matrix in case it is needed later on
        resolved_transforms[idx.index] = model_matrix;

        return model_matrix;
    }

    pub fn window_event_received(self: *Self, event: *const window.WindowEvent) void {
        switch (event.*) {
            .EVENTS_CLEARED => { self.update(); },
            else => {},
        }
    }
};

pub fn main() !void {
    std.debug.print("Hello from zig!!\n", .{});
    try engine.Engine(App).run();
}

