const std = @import("std");
const zm = @import("zmath");
const gfx = @import("../gfx/gfx.zig");

pub const Debug = struct {
    const Self = @This();
    const MAX_LINES = 1024;

    const LineDetails = extern struct {
        start_point: zm.F32x4,
        end_point: zm.F32x4,
        colour: zm.F32x4,
    };

    lines: std.BoundedArray(DebugLine, MAX_LINES),
    lines_vertex_shader: gfx.VertexShader,
    lines_pixel_shader: gfx.PixelShader,
    lines_instance_buffer: gfx.Buffer,

    pub fn deinit(self: *Self) void {
        self.lines_vertex_shader.deinit();
        self.lines_pixel_shader.deinit();
        self.lines_instance_buffer.deinit();
    }

    pub fn init(allocator: std.mem.Allocator, gfx_state: *gfx.GfxState) !Self {
        _ = allocator;

        const lines_vertex_shader = try gfx.VertexShader.init_buffer(
            LINES_HLSL,
            "vs_main",
            ([_]gfx.VertexInputLayoutEntry {
                .{ .name = "TEXCOORD", .index = 0, .slot = 0, .format = .F32x4, .per = .Instance, },
                .{ .name = "TEXCOORD", .index = 1, .slot = 1, .format = .F32x4, .per = .Instance, },
                .{ .name = "COLOR", .index = 0, .slot = 2, .format = .F32x4, .per = .Instance, },
            })[0..],
            .{},
            gfx_state
        );
        errdefer lines_vertex_shader.deinit();

        const lines_pixel_shader = try gfx.PixelShader.init_buffer(
            LINES_HLSL,
            "ps_main",
            .{},
            gfx_state
        );
        errdefer lines_pixel_shader.deinit();

        const lines_instance_buffer = try gfx.Buffer.init(
            @sizeOf(LineDetails) * MAX_LINES,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
            gfx_state
        );
        errdefer lines_instance_buffer.deinit();

        return Self{
            .lines = try std.BoundedArray(DebugLine, MAX_LINES).init(0),
            .lines_vertex_shader = lines_vertex_shader,
            .lines_pixel_shader = lines_pixel_shader,
            .lines_instance_buffer = lines_instance_buffer,
        };
    }

    pub fn draw_line(self: *Self, debug_line: DebugLine) void {
        self.lines.append(debug_line) catch |err| {
            std.log.warn("Failed to append debug line: {s}", .{@errorName(err)});
        };
    }

    pub fn draw_point(self: *Self, debug_point: DebugPoint) void {
        const size = debug_point.size;
        self.draw_line(DebugLine{
            .p0 = debug_point.point - zm.f32x4(size, 0.0, 0.0, 0.0),
            .p1 = debug_point.point + zm.f32x4(size, 0.0, 0.0, 0.0),
            .colour = debug_point.colour,
        });
        self.draw_line(DebugLine{
            .p0 = debug_point.point - zm.f32x4(0.0, size, 0.0, 0.0),
            .p1 = debug_point.point + zm.f32x4(0.0, size, 0.0, 0.0),
            .colour = debug_point.colour,
        });
        self.draw_line(DebugLine{
            .p0 = debug_point.point - zm.f32x4(0.0, 0.0, size, 0.0),
            .p1 = debug_point.point + zm.f32x4(0.0, 0.0, size, 0.0),
            .colour = debug_point.colour,
        });
    }

    pub fn render(self: *Self, camera_buffer: *const gfx.Buffer, rtv: *const gfx.RenderTargetView, gfx_state: *gfx.GfxState) void {
        const lines_slice = self.lines.constSlice();

        {
            var mapped_buffer = self.lines_instance_buffer.map(LineDetails, gfx_state) catch unreachable;
            defer mapped_buffer.unmap();

            for (lines_slice, 0..) |line, i| {
                mapped_buffer.data_array(MAX_LINES)[i] = LineDetails {
                    .start_point = zm.f32x4(line.p0[0], line.p0[1], line.p0[2], 1.0),
                    .end_point = zm.f32x4(line.p1[0], line.p1[1], line.p1[2], 1.0),
                    .colour = line.colour,
                };
            }
        }

        gfx_state.cmd_set_render_target(&.{rtv}, null);
        gfx_state.cmd_set_blend_state(null);
        gfx_state.cmd_set_topology(.TriangleList);
        gfx_state.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });
        gfx_state.cmd_set_constant_buffers(.Vertex, 0, &[_]*const gfx.Buffer{camera_buffer});
        gfx_state.cmd_set_vertex_buffers(0, &[_]gfx.VertexBufferInput{
            .{ .buffer = &self.lines_instance_buffer, .stride = @sizeOf(LineDetails), .offset = @sizeOf(zm.F32x4) * 0, },
            .{ .buffer = &self.lines_instance_buffer, .stride = @sizeOf(LineDetails), .offset = @sizeOf(zm.F32x4) * 1, },
            .{ .buffer = &self.lines_instance_buffer, .stride = @sizeOf(LineDetails), .offset = @sizeOf(zm.F32x4) * 2, },
        });
        gfx_state.cmd_set_vertex_shader(&self.lines_vertex_shader);
        gfx_state.cmd_set_pixel_shader(&self.lines_pixel_shader);
        gfx_state.cmd_draw_instanced(6, @intCast(lines_slice.len), 0, 0);

        // Clear lines buffer
        self.lines.resize(0) catch unreachable;
    }
};

pub const DebugLine = struct {
    p0: zm.F32x4,
    p1: zm.F32x4,
    colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
};

pub const DebugPoint = struct {
    point: zm.F32x4,
    colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
    size: f32 = 1.0,
};

const LINES_HLSL = @embedFile("lines.hlsl");
