const std = @import("std");
const zwin32 = @import("zwin32");
const zm = @import("zmath");
const w32 = zwin32.w32;
const d3d11 = zwin32.d3d11;

const engine = @import("engine.zig");
const window = @import("window.zig");
const kc = @import("input/keycode.zig");

const CameraStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
};

const App = struct {
    const Self = @This();

    const vertices: [3 * 3]zwin32.w32.FLOAT = [_]zwin32.w32.FLOAT{
        0.0, 0.5, 0.0,
        -0.5, -0.5, 0.0,
        0.5, -0.5, 0.0,
    };

    engine: *engine.Engine(Self),

    vso: *d3d11.IVertexShader,
    pso: *d3d11.IPixelShader,
    vso_input_layout: *d3d11.IInputLayout,
    vertex_buffer: *d3d11.IBuffer,
    rasterizer_state: *d3d11.IRasterizerState,
    
    camera_data_buffer: *d3d11.IBuffer,
    camera_position: zm.F32x4,
    camera_rotation: zm.F32x4,

    pub fn init(eng: *engine.Engine(Self)) !Self {
        std.log.info("App init!", .{});

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
            .CullMode = d3d11.CULL_MODE.NONE,
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

        return Self {
            .engine = eng,
            .vso = vso,
            .pso = pso,
            .vso_input_layout = vso_input_layout,
            .vertex_buffer = vertex_buffer,
            .rasterizer_state = rasterizer_state,

            .camera_data_buffer = camera_data_buffer,
            .camera_position = zm.f32x4(0.0, 0.0, -1.0, 1.0),
            .camera_rotation = zm.quatFromRollPitchYaw(0.0, 0.0, 0.0),
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.info("App deinit!", .{});
        _ = self.camera_data_buffer.Release();
        _ = self.rasterizer_state.Release();
        _ = self.vertex_buffer.Release();
        _ = self.vso_input_layout.Release();
        _ = self.vso.Release();
        _ = self.pso.Release();
    }

    inline fn float_from_bool(in: bool) f32 {
        return @floatFromInt(@intFromBool(in));
    }

    fn update(self: *Self) void {
        std.log.info("frame time is: {d}ms, fps is {d}", .{
            self.engine.time.delta_time_f32() * std.time.ms_per_s,
            self.engine.time.get_fps()
        });

        const move_speed: f32 = 1.0 * self.engine.time.delta_time_f32();
        self.camera_position[0] += 
            float_from_bool(self.engine.input.get_key_down(kc.KeyCode.A)) * -move_speed + 
            float_from_bool(self.engine.input.get_key_down(kc.KeyCode.D)) * move_speed; 
        self.camera_position[2] += 
            float_from_bool(self.engine.input.get_key_down(kc.KeyCode.S)) * -move_speed + 
            float_from_bool(self.engine.input.get_key_down(kc.KeyCode.W)) * move_speed;

        {
            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
            zwin32.hrPanicOnFail(self.engine.gfx.context.Map(@ptrCast(self.camera_data_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
            defer self.engine.gfx.context.Unmap(@ptrCast(self.camera_data_buffer), 0);

            var buffer_data: *CameraStruct = @ptrCast(@alignCast(mapped_subresource.pData));
            const model_matrix: zm.Mat = zm.mul(zm.matFromQuat(self.camera_rotation), zm.translationV(self.camera_position));
            buffer_data.view = zm.inverse(model_matrix);
            buffer_data.projection = zm.perspectiveFovLh(40.0, self.engine.gfx.swapchain_aspect(), 0.1, 100.0);
        }

        var rtv = self.engine.gfx.begin_frame() catch |err| {
            std.log.err("unable to begin frame: {}", .{err});
            return;
        };
        self.engine.gfx.context.ClearRenderTargetView(rtv, &[4]zwin32.w32.FLOAT{30.0/255.0, 30.0/255.0, 46.0/255.0, 1.0});

        self.engine.gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        self.engine.gfx.context.IASetInputLayout(self.vso_input_layout);
        const stride: c_uint = @sizeOf(f32) * 3;
        const offset: c_uint = 0;
        self.engine.gfx.context.IASetVertexBuffers(0, 1, @ptrCast(&self.vertex_buffer), @ptrCast(&stride), @ptrCast(&offset));
        self.engine.gfx.context.VSSetShader(self.vso, null, 0);
        self.engine.gfx.context.VSSetConstantBuffers(0, 1, @ptrCast(&self.camera_data_buffer));

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

        self.engine.gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), null);
        self.engine.gfx.context.OMSetBlendState(null, null, 0xffffffff);

        self.engine.gfx.context.Draw(3, 0);

        self.engine.gfx.end_frame(rtv) catch |err| {
            std.log.err("unable to end frame: {}", .{err});
            return;
        };
        return;
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

