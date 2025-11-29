const std = @import("std");
const zphy = @import("zphysics");
const zwindows = @import("zwindows");
const zm = @import("zmath");
const eng = @import("self");
const gfx = eng.gfx;
const cm = eng.camera;
const Transform = eng.Transform;

const PushConstantCamera = extern struct {
    vp: zm.Mat,
};
const PushConstantsBody = extern struct {
    model: zm.Mat,
    colour: zm.F32x4,
};

const SHADER_SLANG = @embedFile("physics_debug_renderer.slang");

pub const D3D11DebugRenderer = extern struct {
    const MyRenderPrimitive = struct {
        linked_list_node: std.DoublyLinkedList.Node,

        buffer: gfx.Buffer.Ref,
        num_vertices: u32 = 0,
        indices_offset: u32 = 0,
        num_indices: u32 = 0,

        pub fn deinit(self: *const MyRenderPrimitive) void {
            self.buffer.deinit();
        }

        pub fn has_indices(self: *const MyRenderPrimitive) bool {
            return self.num_indices != 0;
        }
    };

    const Data = struct {
        alloc: std.mem.Allocator,

        primitives: std.DoublyLinkedList,

        render_pass: gfx.RenderPass.Ref,
        pipeline: gfx.GraphicsPipeline.Ref,
        framebuffer: gfx.FrameBuffer.Ref,

        pub fn deinit(self: *Data) void {
            while (self.primitives.pop()) |node| {
                const prim: *MyRenderPrimitive = @fieldParentPtr("linked_list_node", node);
                prim.deinit();
                self.alloc.destroy(prim);
            }
            
            self.framebuffer.deinit();
            self.pipeline.deinit();
            self.render_pass.deinit();
        }
    };

    pub const Vertex = extern struct {
        position: [3]f32,
        normal: [3]f32,
        uv: [2]f32,
        color: [4]f32,

        pub fn from_zphy(vertex: *const zphy.DebugRenderer.Vertex) Vertex {
            return Vertex {
                .position = vertex.position,
                .normal = vertex.normal,
                .uv = vertex.uv,
                .color = [4]f32{
                    @as(f32, @floatFromInt(vertex.color.comp.r)) / 255.0,
                    @as(f32, @floatFromInt(vertex.color.comp.g)) / 255.0,
                    @as(f32, @floatFromInt(vertex.color.comp.b)) / 255.0,
                    @as(f32, @floatFromInt(vertex.color.comp.a)) / 255.0,
                },
            };
        }
    };

    __v: *const zphy.DebugRenderer.VTable(@This()) = &vtable,

    data: *Data,

    // this will be set immediately before zphy render callbacks
    cmd: ?*gfx.CommandBuffer = null,

    const vtable = zphy.DebugRenderer.VTable(@This()){
        .drawLine = drawLine,
        .drawTriangle = drawTriangle,
        .createTriangleBatch = createTriangleBatch,
        .createTriangleBatchIndexed = createTriangleBatchIndexed,
        .destroyTriangleBatch = destroyTriangleBatch,
        .drawGeometry = drawGeometry,
        .drawText3D = drawText3D,
    };

    pub fn deinit(self: *D3D11DebugRenderer) void {
        const alloc = self.data.alloc;
        self.data.deinit();
        alloc.destroy(self.data);
    }

    pub fn init() !D3D11DebugRenderer {
        const alloc = eng.get().general_allocator;

        const spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
            .shader_data = SHADER_SLANG,
            .shader_entry_points = &.{
                "vs_main",
                "ps_main",
            }
        });
        defer alloc.free(spirv);

        const shader_module = try gfx.ShaderModule.init(.{
            .spirv_data = spirv,
        });
        defer shader_module.deinit();

        const vertex_input = try gfx.VertexInput.init(.{
            .bindings = &.{
                gfx.VertexInputBinding {
                    .binding = 0, .input_rate = .Vertex, .stride = 12 + 12 + 8 + 16,
                },
            },
            .attributes = &.{
                .{ .location = 0, .binding = 0, .name = "POS", .format = .F32x3, .offset = 0 },
                .{ .location = 1, .binding = 0, .name = "NORMAL", .format = .F32x3, .offset = 12 },
                .{ .location = 2, .binding = 0, .name = "TEXCOORD0", .format = .F32x2, .offset = 24 },
                .{ .location = 3, .binding = 0, .name = "COLOR", .format = .F32x4, .offset = 32 },
            },
        });
        defer vertex_input.deinit();

        const attachments = &[_]gfx.AttachmentInfo {
            gfx.AttachmentInfo {
                .name = "colour",
                .format = gfx.GfxState.ldr_format,
                .initial_layout = .ColorAttachmentOptimal,
                .final_layout = .ColorAttachmentOptimal,
                .blend_type = .Simple,
            },
            gfx.AttachmentInfo {
                .name = "depth",
                .format = gfx.GfxState.depth_format,
                .initial_layout = .DepthStencilAttachmentOptimal,
                .final_layout = .DepthStencilAttachmentOptimal,
            },
        };

        const render_pass = try gfx.RenderPass.init(.{
            .attachments = attachments,
            .subpasses = &.{
                gfx.SubpassInfo {
                    .attachments = &.{ "colour" },
                    .depth_attachment = "depth",
                },
            },
            .dependencies = &.{
                gfx.SubpassDependencyInfo {
                    .src_subpass = null,
                    .dst_subpass = 0,
                    .src_stage_mask = .{ .color_attachment_output = true, },
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .color_attachment_output = true, },
                    .dst_access_mask = .{ .color_attachment_write = true, },
                },
            },
        });
        errdefer render_pass.deinit();

        const pipeline = try gfx.GraphicsPipeline.init(.{
            .render_pass = render_pass,
            .subpass_index = 0,
            .vertex_shader = .{
                .module = &shader_module,
                .entry_point = "vs_main",
            },
            .vertex_input = &vertex_input,
            .pixel_shader = .{
                .module = &shader_module,
                .entry_point = "ps_main",
            },
            .rasterization_fill_mode = .Line,
            .cull_mode = .CullNone,
            .push_constants = &.{
                gfx.PushConstantLayoutInfo {
                    .shader_stages = .{ .Vertex = true, },
                    .offset = 0,
                    .size = @sizeOf(PushConstantCamera) + @sizeOf(PushConstantsBody),
                },
            },
            //.depth_test = .{ .write = false, },
        });
        errdefer pipeline.deinit();

        const framebuffer = try gfx.FrameBuffer.init(.{
            .render_pass = render_pass,
            .attachments = &[_]gfx.FrameBufferAttachmentInfo {
                .SwapchainLDR,
                .SwapchainDepth,
            },
        });
        errdefer framebuffer.deinit();

        const data = try eng.get().general_allocator.create(Data);
        errdefer eng.get().general_allocator.destroy(data);

        data.* = .{
            .alloc = eng.get().general_allocator,
            .primitives = .{},
            .render_pass = render_pass,
            .pipeline = pipeline,
            .framebuffer = framebuffer,
        };

        return D3D11DebugRenderer {
            .data = data,
        };
    }

    pub fn draw_bodies(
        self: *D3D11DebugRenderer, 
        cmd: *gfx.CommandBuffer,
        projection: zm.Mat,
        view: zm.Mat,
    ) void {
        cmd.cmd_begin_render_pass(.{
            .render_pass = self.data.render_pass,
            .framebuffer = self.data.framebuffer,
            .render_area = .full_screen_pixels(),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.data.pipeline);

        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport() } });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels() } });

        const camera_push_constants = PushConstantCamera {
            .vp = zm.mul(view, projection),
        };

        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true, },
            .offset = 0,
            .data = std.mem.asBytes(&camera_push_constants),
        });

        self.cmd = cmd;
        defer self.cmd = null;

        eng.get().physics.zphy.drawBodies(&.{}, null);
    }

    pub fn shouldBodyDraw(_: *const zphy.Body) align(zphy.DebugRenderer.BodyDrawFilterFuncAlignment) callconv(.C) bool {
        return true;
    }

    fn drawLine(
        self: *D3D11DebugRenderer,
        from: *const [3]zphy.Real,
        to: *const [3]zphy.Real,
        color: zphy.DebugRenderer.Color,
    ) callconv(.c) void {
        _ = self;
        _ = from;
        _ = to;
        _ = color;
        std.log.info("PhysicsSystem should draw line", .{});
    }

    fn drawTriangle(
        self: *D3D11DebugRenderer,
        v1: *const [3]zphy.Real,
        v2: *const [3]zphy.Real,
        v3: *const [3]zphy.Real,
        color: zphy.DebugRenderer.Color,
    ) callconv(.c) void {
        _ = self;
        _ = v1;
        _ = v2;
        _ = v3;
        _ = color;
        std.log.info("PhysicsSystem should draw triangle", .{});
    }

    fn createTriangleBatch(
        self: *D3D11DebugRenderer,
        triangles: [*]zphy.DebugRenderer.Triangle,
        triangle_count: u32,
    ) callconv(.c) *zphy.DebugRenderer.TriangleBatch {
        const alloc = self.data.alloc;

        const prim = alloc.create(MyRenderPrimitive) catch |err| {
            std.log.err("Unable to add physics debug primitive: {}", .{err});
            unreachable;
        };
        errdefer alloc.destroy(prim);

        var buffer_data = alloc.alloc(Vertex, triangle_count * 3) catch unreachable;
        defer alloc.free(buffer_data);
        for (triangles[0..triangle_count], 0..) |tri, t_idx| {
            buffer_data[(t_idx * 3) + 0] = Vertex.from_zphy(&tri.v[0]);
            buffer_data[(t_idx * 3) + 1] = Vertex.from_zphy(&tri.v[1]);
            buffer_data[(t_idx * 3) + 2] = Vertex.from_zphy(&tri.v[2]);
        }

        const buffer = gfx.Buffer.init_with_data(
            std.mem.sliceAsBytes(buffer_data),
            .{ .VertexBuffer = true, },
            .{}
        ) catch |err| {
            std.log.err("Unable to create buffer for physics debug renderer: {}", .{err});
            unreachable;
        };
        errdefer buffer.deinit();

        prim.* = MyRenderPrimitive {
            .linked_list_node = undefined,
            .buffer = buffer,
            .num_vertices = triangle_count * 3,
            .indices_offset = 0,
            .num_indices = 0,
        };

        self.data.primitives.append(&prim.linked_list_node);
        errdefer self.data.primitives.remove(&prim.linked_list_node);

        return zphy.DebugRenderer.createTriangleBatch(prim);
    }

    fn createTriangleBatchIndexed(
        self: *D3D11DebugRenderer,
        vertices: [*]zphy.DebugRenderer.Vertex,
        vertex_count: u32,
        indices: [*]u32,
        index_count: u32,
    ) callconv(.c) *zphy.DebugRenderer.TriangleBatch {
        const alloc = self.data.alloc;

        const prim = alloc.create(MyRenderPrimitive) catch |err| {
            std.log.err("Unable to add physics debug primitive: {}", .{err});
            unreachable;
        };
        errdefer alloc.destroy(prim);

        const vertices_byte_length = @sizeOf(Vertex) * vertex_count;
        const indices_byte_length = @sizeOf(u32) * index_count;

        var buffer_data = alloc.alloc(u8, vertices_byte_length + indices_byte_length) catch unreachable;
        defer alloc.free(buffer_data);

        const vertex_buffer_data = std.mem.bytesAsSlice(Vertex, buffer_data[0..vertices_byte_length]);
        for (vertices[0..vertex_count], 0..) |vert, idx| {
            vertex_buffer_data[idx] = Vertex.from_zphy(&vert);
        }
        const indices_buffer_data = std.mem.bytesAsSlice(u32, buffer_data[vertices_byte_length..]);
        @memcpy(indices_buffer_data[0..], indices[0..]);

        const buffer = gfx.Buffer.init_with_data(
            buffer_data,
            .{ .VertexBuffer = true, .IndexBuffer = true, },
            .{}
        ) catch |err| {
            std.log.err("Unable to create buffer for physics debug renderer: {}", .{err});
            unreachable;
        };
        errdefer buffer.deinit();

        prim.* = MyRenderPrimitive {
            .linked_list_node = undefined,
            .buffer = buffer,
            .num_vertices = vertex_count,
            .indices_offset = vertices_byte_length,
            .num_indices = index_count,
        };

        self.data.primitives.append(&prim.linked_list_node);
        errdefer self.data.primitives.remove(&prim.linked_list_node);

        return zphy.DebugRenderer.createTriangleBatch(prim);
    }

    fn destroyTriangleBatch(
        self: *D3D11DebugRenderer,
        batch: *anyopaque,
    ) callconv(.c) void {
        _ = self;
        _ = batch;
    }

    fn drawGeometry(
        self: *D3D11DebugRenderer,
        model_matrix: *const zphy.RMatrix,
        world_space_bound: *const zphy.AABox,
        lod_scale_sq: f32,
        color: zphy.DebugRenderer.Color,
        geometry: *const zphy.DebugRenderer.Geometry,
        cull_mode: zphy.DebugRenderer.CullMode,
        cast_shadow: zphy.DebugRenderer.CastShadow,
        draw_mode: zphy.DebugRenderer.DrawMode,
    ) callconv(.c) void {
        _ = world_space_bound;
        _ = lod_scale_sq;
        _ = cull_mode;
        _ = cast_shadow;
        _ = draw_mode;

        const cmd = self.cmd orelse {
            std.log.err("Command buffer was not set in physics debug renderer", .{});
            return;
        };

        if (geometry.num_LODs < 1) { 
            std.log.warn("Unable to draw physics debug geometry, num LODs is less than 1", .{});
            return; 
        }

        const object_push_constants = PushConstantsBody {
            .model = zm.Mat {
                zm.loadArr4(model_matrix.column_0),
                zm.loadArr4(model_matrix.column_1),
                zm.loadArr4(model_matrix.column_2),
                zm.loadArr4(model_matrix.column_3),
            },
            .colour = zm.f32x4(
                @as(f32, @floatFromInt(color.comp.r)) / 255.0,
                @as(f32, @floatFromInt(color.comp.g)) / 255.0,
                @as(f32, @floatFromInt(color.comp.b)) / 255.0,
                @as(f32, @floatFromInt(color.comp.a)) / 255.0
            ),
        };

        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true },
            .offset = @sizeOf(PushConstantCamera),
            .data = std.mem.asBytes(&object_push_constants),
        });

        const render_data: *const MyRenderPrimitive = @ptrCast(@alignCast(zphy.DebugRenderer.getPrimitiveFromBatch(geometry.LODs[0].batch)));

        cmd.cmd_bind_vertex_buffers(.{
            .buffers = &.{ .{ .buffer = render_data.buffer } },
        });

        if (render_data.has_indices()) {
            cmd.cmd_bind_index_buffer(.{
                .buffer = render_data.buffer,
                .index_format = .U32,
                .offset = render_data.indices_offset,
            });
            cmd.cmd_draw_indexed(.{ .index_count = render_data.num_indices });
        } else {
            cmd.cmd_draw(.{ .vertex_count = render_data.num_vertices });
        }
    }

    fn drawText3D(
        self: *D3D11DebugRenderer,
        positions: *const [3]zphy.Real,
        string: [*:0]const u8,
        color: zphy.DebugRenderer.Color,
        height: f32,
    ) callconv(.c) void {
        _ = self;
        _ = positions;
        _ = string;
        _ = color;
        _ = height;
        std.log.info("PhysicsSystem should draw text 3d", .{});
    }
};
