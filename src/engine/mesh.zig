const std = @import("std");
const zmesh = @import("zmesh");
const zwin32 = @import("zwin32");
const d3d11 = zwin32.d3d11;

pub const RenderMode = enum {
    TRIANGLES,
    POINTS,
    LINES,
};

pub const MeshPrimitive = struct {
    num_indices: usize,
    num_vertices: usize,
    indices_offset: usize,
    pos_offset: usize,
    nor_offset: usize,
    tex_coord_offset: usize,
    tangents_offset: usize,

    pub inline fn has_indices(self: *const MeshPrimitive) bool {
        return self.num_indices != 0;
    }
};

pub const Mesh = struct {
    primitives: std.ArrayList(MeshPrimitive),

    pub fn init(alloc: std.mem.Allocator) Mesh {
        return Mesh {
            .primitives = std.ArrayList(MeshPrimitive).init(alloc),
        };
    }

    pub fn deinit(self: *const Mesh) void {
        self.primitives.deinit();
    }
};

pub const MeshSet = struct {
    const Self = @This();
    indices: *d3d11.IBuffer,
    positions: *d3d11.IBuffer,
    normals: *d3d11.IBuffer,
    tex_coords: *d3d11.IBuffer,
    tangents: *d3d11.IBuffer,
    meshes: std.ArrayList(Mesh),

    pub fn init_from_file(alloc: std.mem.Allocator, file: [:0]const u8, gfx_device: *d3d11.IDevice) !Self {
        const data = try zmesh.io.parseAndLoadFile(file);
        defer zmesh.io.freeData(data);

        var mesh_indices = std.ArrayList(u32).init(alloc);
        defer mesh_indices.deinit();
        var mesh_positions = std.ArrayList([3]f32).init(alloc);
        defer mesh_positions.deinit();
        var mesh_normals = std.ArrayList([3]f32).init(alloc);
        defer mesh_normals.deinit();
        var mesh_tex_coords = std.ArrayList([2]f32).init(alloc);
        defer mesh_tex_coords.deinit();
        var mesh_tangents = std.ArrayList([4]f32).init(alloc);
        defer mesh_tangents.deinit();

        var meshes = std.ArrayList(Mesh).init(alloc);
        // Iterate through meshes and their primitives adding all data to 
        // the above arraylists and appending mesh data to a arraylist
        for (0..data.meshes_count) |mi| {
            var mesh = Mesh.init(alloc);
            const m = data.meshes.?[mi];

            for (0..m.primitives_count) |pi| {
                var prim = MeshPrimitive {
                    .num_indices = undefined,
                    .num_vertices = undefined,
                    .indices_offset = mesh_indices.items.len,
                    .pos_offset = mesh_positions.items.len,
                    .nor_offset = mesh_normals.items.len,
                    .tex_coord_offset = mesh_tex_coords.items.len,
                    .tangents_offset = mesh_tangents.items.len,
                };

                try zmesh.io.appendMeshPrimitive(
                    data,
                    @intCast(mi),
                    @intCast(pi),
                    &mesh_indices,
                    &mesh_positions,
                    &mesh_normals,
                    &mesh_tex_coords,
                    &mesh_tangents
                );

                prim.num_vertices = mesh_positions.items.len - prim.pos_offset;
                prim.num_indices = mesh_indices.items.len - prim.indices_offset;
                try mesh.primitives.append(prim);
            }
            try meshes.append(mesh);
        }

        // Create buffers on GPU
        // Positions
        const vert_pos_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(f32) * 3 * @as(c_uint, @intCast(mesh_positions.items.len)),
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        var vert_pos_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_pos_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_positions.items.ptr), }, @ptrCast(&vert_pos_buffer)));

        // Normals
        const vert_norm_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(f32) * 3 * @as(c_uint, @intCast(mesh_normals.items.len)),
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        var vert_norm_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_norm_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_normals.items.ptr), }, @ptrCast(&vert_norm_buffer)));

        // Tex Coords
        const vert_tex_coord_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(f32) * 2 * @as(c_uint, @intCast(mesh_tex_coords.items.len)),
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        var vert_tex_coord_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_tex_coord_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_tex_coords.items.ptr), }, @ptrCast(&vert_tex_coord_buffer)));

        // Tangents
        const vert_tangents_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(f32) * 4 * @as(c_uint, @intCast(mesh_tangents.items.len)),
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        var vert_tangents_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_tangents_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_tangents.items.ptr), }, @ptrCast(&vert_tangents_buffer)));

        // Indices
        const indices_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(u32) * @as(c_uint, @intCast(mesh_indices.items.len)),
            .BindFlags = d3d11.BIND_FLAG{ .INDEX_BUFFER = true, },
        };
        var indices_buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&indices_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_indices.items.ptr), }, @ptrCast(&indices_buffer)));

        return Self {
            .indices = indices_buffer,
            .positions = vert_pos_buffer,
            .normals = vert_norm_buffer,
            .tex_coords = vert_tex_coord_buffer,
            .tangents = vert_tangents_buffer,
            .meshes = meshes,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.meshes.items) |m| {
            m.deinit();
        }
        self.meshes.deinit();

        _ = self.indices.Release();
        _ = self.positions.Release();
        _ = self.normals.Release();
        _ = self.tex_coords.Release();
        _ = self.tangents.Release();
    }
};

