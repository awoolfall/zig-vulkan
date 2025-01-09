const std = @import("std");
const zphy = @import("zphysics");
const zwindows = @import("zwindows");
const zm = @import("zmath");
const d3d11 = zwindows.d3d11;
const _gfx = @import("../gfx/gfx.zig");
const cm = @import("../engine/camera.zig");
const tm = @import("../engine/transform.zig");

const CameraStruct = extern struct {
    projection: [16]f32,
    view: [16]f32,
};

const MaterialStruct = extern struct {
    model_matrix: [16]f32,
    material_color: [4]f32,
};

pub const D3D11DebugRenderer = extern struct {
    const MyRenderPrimitive = extern struct {
        buffer: ?*d3d11.IBuffer = null,
        num_vertices: u32 = 0,
        indices_offset: u32 = 0,
        num_indices: u32 = 0,

        pub fn has_indices(self: *const MyRenderPrimitive) bool {
            return self.num_indices != 0;
        }
    };

    usingnamespace zphy.DebugRenderer.Methods(@This());
    __v: *const zphy.DebugRenderer.VTable(@This()) = &vtable,

    primitives: [2048]MyRenderPrimitive = [_]MyRenderPrimitive{.{}} ** 2048,
    prim_head: i32 = -1,
    gfx: *_gfx.GfxState,
    gfx_data: extern struct {
        vso_input_layout: *d3d11.IInputLayout,
        vso: *d3d11.IVertexShader,
        pso: *d3d11.IPixelShader,
        rasterization_state: *d3d11.IRasterizerState,
        model_matrix_buffer: *d3d11.IBuffer,
        camera_buffer: *d3d11.IBuffer,
    },

    const vtable = zphy.DebugRenderer.VTable(@This()){
        .drawLine = drawLine,
        .drawTriangle = drawTriangle,
        .createTriangleBatch = createTriangleBatch,
        .createTriangleBatchIndexed = createTriangleBatchIndexed,
        .drawGeometry = drawGeometry,
        .drawText3D = drawText3D,
    };

    pub fn deinit(self: *D3D11DebugRenderer) void {
        for (self.primitives) |prim| {
            if (prim.buffer != null) {
                _ = prim.buffer.?.Release();
            }
        }
        _ = self.gfx_data.camera_buffer.Release();
        _ = self.gfx_data.model_matrix_buffer.Release();
        _ = self.gfx_data.rasterization_state.Release();
        _ = self.gfx_data.vso_input_layout.Release();
        _ = self.gfx_data.vso.Release();
        _ = self.gfx_data.pso.Release();
    }

    pub fn init(gfx: *_gfx.GfxState) !D3D11DebugRenderer {
        const shader_buffer = \\
\\  cbuffer camera_data : register(b0)
\\  {
\\      row_major float4x4 projection;
\\      row_major float4x4 view;
\\  }
\\ 
\\  cbuffer instance_data : register(b1)
\\  {
\\      row_major float4x4 model_matrix;
\\      float4 material_color;
\\  }
\\ 
\\  struct vs_in
\\  {
\\      float3 pos : POS;
\\      float3 normals : NORMAL;
\\      float2 tex_coord : TEXCOORD;
\\      float3 color: COLOR;
\\  };
\\ 
\\  struct vs_out
\\  {
\\      float4 position : SV_POSITION;
\\      float4 colour : POS;
\\  };
\\ 
\\  vs_out vs_main(vs_in input)
\\  {
\\      vs_out output = (vs_out) 0;
\\      float4x4 vp = mul(view, projection);
\\      float4x4 mvp = mul(model_matrix, vp);
\\      output.position = mul(float4(input.pos, 1.0), mvp);
\\      output.colour = float4(input.color * material_color.xyz, 1.0);
\\      return output;
\\  }
\\ 
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      return input.colour;
\\  }
;

        var vs_blob: *zwindows.d3d.IBlob = undefined;
        try zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(shader_buffer, shader_buffer.len, null, null, null, "vs_main", "vs_5_0", 0, 0, @ptrCast(&vs_blob), null));
        defer _ = vs_blob.Release();

        var vso: *d3d11.IVertexShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, @ptrCast(&vso)));
        errdefer _ = vso.Release();

        var ps_blob: *zwindows.d3d.IBlob = undefined;
        try zwindows.hrErrorOnFail(zwindows.d3dcompiler.D3DCompile(shader_buffer, shader_buffer.len, null, null, null, "ps_main", "ps_5_0", 0, 0, @ptrCast(&ps_blob), null));
        defer _ = ps_blob.Release();

        // Create vertex and pixel shaders
        var pso: *d3d11.IPixelShader = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&pso)));
        errdefer _ = pso.Release();

        const vso_input_layout_desc = [_]d3d11.INPUT_ELEMENT_DESC {
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "POS",
                .SemanticIndex = 0,
                .Format = zwindows.dxgi.FORMAT.R32G32B32_FLOAT,
                .InputSlot = 0,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
                .InstanceDataStepRate = 0,
            },
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "NORMAL",
                .SemanticIndex = 0,
                .Format = zwindows.dxgi.FORMAT.R32G32B32_FLOAT,
                .InputSlot = 1,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
                .InstanceDataStepRate = 0,
            },
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "TEXCOORD",
                .SemanticIndex = 0,
                .Format = zwindows.dxgi.FORMAT.R32G32_FLOAT,
                .InputSlot = 2,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
                .InstanceDataStepRate = 0,
            },
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "COLOR",
                .SemanticIndex = 0,
                .Format = zwindows.dxgi.FORMAT.R8G8B8A8_UNORM,
                .InputSlot = 3,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_VERTEX_DATA,
                .InstanceDataStepRate = 0,
            },
        };
        var vso_input_layout: *d3d11.IInputLayout = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateInputLayout(vso_input_layout_desc[0..], vso_input_layout_desc.len, vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), @ptrCast(&vso_input_layout)));
        errdefer _ = vso_input_layout.Release();

        // Define rasterizer state
        var rasterization_state: *d3d11.IRasterizerState = undefined;
        var rasterizer_state_desc = d3d11.RASTERIZER_DESC {
            .FillMode = d3d11.FILL_MODE.WIREFRAME,
            .CullMode = d3d11.CULL_MODE.BACK,
        };
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&rasterization_state)));
        errdefer _ = rasterization_state.Release();

        // Create model constant buffer
        const model_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @intCast(@sizeOf(MaterialStruct)),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var model_buffer: *d3d11.IBuffer = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateBuffer(&model_constant_buffer_desc, null, @ptrCast(&model_buffer)));
        errdefer _ = model_buffer.Release();

        // Create camera constant buffer
        const camera_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(CameraStruct),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        var camera_data_buffer: *d3d11.IBuffer = undefined;
        try zwindows.hrErrorOnFail(gfx.platform.device.CreateBuffer(&camera_constant_buffer_desc, null, @ptrCast(&camera_data_buffer)));
        errdefer _ = camera_data_buffer.Release();

        return D3D11DebugRenderer{
            .gfx = gfx,
            .gfx_data = .{
                .vso_input_layout = vso_input_layout,
                .vso = vso,
                .pso = pso,
                .rasterization_state = rasterization_state,
                .model_matrix_buffer = model_buffer,
                .camera_buffer = camera_data_buffer,
            },
        };
    }

    pub fn draw_bodies(
        self: *D3D11DebugRenderer, 
        phys: *zphy.PhysicsSystem, 
        rtv: *d3d11.IRenderTargetView, 
        rtv_width: i32,
        rtv_height: i32,
        proj: [16]f32,
        view: [16]f32
    ) void {
        { // Update camera buffer
            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
            zwindows.hrPanicOnFail(self.gfx.platform.context.Map(@ptrCast(self.gfx_data.camera_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
            defer self.gfx.platform.context.Unmap(@ptrCast(self.gfx_data.camera_buffer), 0);

            var buffer_data: *CameraStruct = @ptrCast(@alignCast(mapped_subresource.pData));
            buffer_data.view = view;
            buffer_data.projection = proj;
        }

        const viewport = d3d11.VIEWPORT {
            .Width = @floatFromInt(rtv_width),
            .Height = @floatFromInt(rtv_height),
            .TopLeftX = 0,
            .TopLeftY = 0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        self.gfx.platform.context.RSSetViewports(1, @ptrCast(&viewport));

        self.gfx.platform.context.PSSetShader(self.gfx_data.pso, null, 0);

        self.gfx.platform.context.OMSetRenderTargets(1, @ptrCast(&rtv), null);
        self.gfx.platform.context.OMSetBlendState(null, null, 0xffffffff);

        self.gfx.platform.context.VSSetShader(self.gfx_data.vso, null, 0);
        self.gfx.platform.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.gfx_data.camera_buffer));

        self.gfx.platform.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        self.gfx.platform.context.IASetInputLayout(self.gfx_data.vso_input_layout);

        self.gfx.platform.context.RSSetState(self.gfx_data.rasterization_state);

        // Issue debug draw command to physics system
        phys.drawBodies(&.{}, null);
    }

    pub fn shouldBodyDraw(_: *const zphy.Body) align(zphy.DebugRenderer.BodyDrawFilterFuncAlignment) callconv(.C) bool {
        return true;
    }

    fn drawLine(
        self: *D3D11DebugRenderer,
        from: *const [3]zphy.Real,
        to: *const [3]zphy.Real,
        color: zphy.DebugRenderer.Color,
    ) callconv(.C) void {
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
    ) callconv(.C) void {
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
    ) callconv(.C) *anyopaque {
        self.prim_head += 1;
        const prim = &self.primitives[@as(usize, @intCast(self.prim_head))];

        const buffer_length: c_uint = @sizeOf(zphy.DebugRenderer.Triangle) * triangle_count;

        var buffer_data = std.heap.page_allocator.alloc(u8, buffer_length) catch unreachable;
        defer std.heap.page_allocator.free(buffer_data);
        @memcpy(buffer_data[0..], @as([*]u8, @ptrCast(triangles)));

        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = buffer_length,
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, .INDEX_BUFFER = true },
        };
        var buffer: *d3d11.IBuffer = undefined;
        zwindows.hrErrorOnFail(self.gfx.platform.device.CreateBuffer(&buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(buffer_data), }, @ptrCast(&buffer)))
            catch |err| {
                std.log.warn("Unable to create buffer in physics debug renderer: {}", .{err});
                return zphy.DebugRenderer.createTriangleBatch(prim);
            };
        errdefer _ = buffer.Release();

        prim.* = MyRenderPrimitive {
            .buffer = buffer,
            .num_vertices = triangle_count * 3,
            .indices_offset = 0,
            .num_indices = 0,
        };
        return zphy.DebugRenderer.createTriangleBatch(prim);
    }

    fn createTriangleBatchIndexed(
        self: *D3D11DebugRenderer,
        vertices: [*]zphy.DebugRenderer.Vertex,
        vertex_count: u32,
        indices: [*]u32,
        index_count: u32,
    ) callconv(.C) *anyopaque {
        self.prim_head += 1;
        const prim = &self.primitives[@as(usize, @intCast(self.prim_head))];

        const vert_byte_length = @sizeOf(zphy.DebugRenderer.Vertex) * vertex_count;
        const buffer_length: c_uint = 
            vert_byte_length + 
            @sizeOf(u32) * index_count;

        var buffer_data = std.heap.page_allocator.alloc(u8, buffer_length) catch unreachable;
        defer std.heap.page_allocator.free(buffer_data);
        @memcpy(buffer_data[0..vert_byte_length], @as([*]u8, @ptrCast(vertices)));
        @memcpy(buffer_data[vert_byte_length..], @as([*]u8, @ptrCast(indices)));

        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = buffer_length,
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, .INDEX_BUFFER = true },
        };
        var buffer: *d3d11.IBuffer = undefined;
        zwindows.hrErrorOnFail(self.gfx.platform.device.CreateBuffer(&buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(buffer_data), }, @ptrCast(&buffer)))
            catch |err| {
                std.log.warn("Unable to create indexed buffer in physics debug renderer: {}", .{err});
                return zphy.DebugRenderer.createTriangleBatch(prim);
            };
        errdefer _ = buffer.Release();

        prim.* = MyRenderPrimitive {
            .buffer = buffer,
            .num_vertices = vertex_count,
            .indices_offset = vert_byte_length,
            .num_indices = index_count,
        };
        return zphy.DebugRenderer.createTriangleBatch(prim);
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
    ) callconv(.C) void {
        _ = world_space_bound;
        _ = lod_scale_sq;
        _ = cull_mode;
        _ = cast_shadow;
        _ = draw_mode;

        if (geometry.num_LODs < 1) { 
            std.log.warn("Unable to draw physics debug geometry, num LODs is less than 1", .{});
            return; 
        }

        { // Setup model buffer from transform
            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
            zwindows.hrPanicOnFail(self.gfx.platform.context.Map(@ptrCast(self.gfx_data.model_matrix_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
            defer self.gfx.platform.context.Unmap(@ptrCast(self.gfx_data.model_matrix_buffer), 0);

            var buffer_data: *MaterialStruct = @ptrCast(@alignCast(mapped_subresource.pData));

            for (model_matrix.column_0, 0..) |v, idx| {
                (buffer_data.model_matrix)[idx] = @floatCast(v);
            }
            for (model_matrix.column_1, 0..) |v, idx| {
                (buffer_data.model_matrix)[idx + 4] = @floatCast(v);
            }
            for (model_matrix.column_2, 0..) |v, idx| {
                (buffer_data.model_matrix)[idx + 8] = @floatCast(v);
            }
            for (model_matrix.column_3, 0..) |v, idx| {
                (buffer_data.model_matrix)[idx + 12] = @floatCast(v);
            }

            buffer_data.material_color[0] = (@as(f32, @floatFromInt(color.comp.r)) / 255.0);
            buffer_data.material_color[1] = (@as(f32, @floatFromInt(color.comp.g)) / 255.0);
            buffer_data.material_color[2] = (@as(f32, @floatFromInt(color.comp.b)) / 255.0);
            buffer_data.material_color[3] = (@as(f32, @floatFromInt(color.comp.a)) / 255.0);
        }
        self.gfx.platform.context.VSSetConstantBuffers(1, 1, @ptrCast(&self.gfx_data.model_matrix_buffer));

        const render_data: *const MyRenderPrimitive = @ptrCast(@alignCast(zphy.DebugRenderer.getPrimitiveFromBatch(geometry.LODs[0].batch)));
        std.debug.assert(render_data.buffer != null);

        const stride: c_uint = @sizeOf(zphy.DebugRenderer.Vertex);
        const pos_offset: c_uint = 0;
        self.gfx.platform.context.IASetVertexBuffers(0, 1, @ptrCast(&render_data.buffer.?), @ptrCast(&stride), @ptrCast(&pos_offset));
        const norm_offset: c_uint = @sizeOf(f32) * 3;
        self.gfx.platform.context.IASetVertexBuffers(1, 1, @ptrCast(&render_data.buffer.?), @ptrCast(&stride), @ptrCast(&norm_offset));
        const uv_offset: c_uint = @sizeOf(f32) * 3 + @sizeOf(f32) * 3;
        self.gfx.platform.context.IASetVertexBuffers(2, 1, @ptrCast(&render_data.buffer.?), @ptrCast(&stride), @ptrCast(&uv_offset));
        const col_offset: c_uint = @sizeOf(f32) * 3 + @sizeOf(f32) * 3 + @sizeOf(f32) * 2;
        self.gfx.platform.context.IASetVertexBuffers(3, 1, @ptrCast(&render_data.buffer.?), @ptrCast(&stride), @ptrCast(&col_offset));

        if (render_data.has_indices()) {
            self.gfx.platform.context.IASetIndexBuffer(render_data.buffer, zwindows.dxgi.FORMAT.R32_UINT, render_data.indices_offset);
            self.gfx.platform.context.DrawIndexed(@intCast(render_data.num_indices), @intCast(0), @intCast(0));
        } else {
            self.gfx.platform.context.Draw(@intCast(render_data.num_vertices), @intCast(0));
        }
    }

    fn drawText3D(
        self: *D3D11DebugRenderer,
        positions: *const [3]zphy.Real,
        string: [*:0]const u8,
        color: zphy.DebugRenderer.Color,
        height: f32,
    ) callconv(.C) void {
        _ = self;
        _ = positions;
        _ = string;
        _ = color;
        _ = height;
        std.log.info("PhysicsSystem should draw text 3d", .{});
    }
};
