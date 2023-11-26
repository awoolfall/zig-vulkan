const std = @import("std");
const zmesh = @import("zmesh");
const zwin32 = @import("zwin32");
const zm = @import("zmath");
const zphy = @import("zphysics");
const d3d11 = zwin32.d3d11;
const assert = std.debug.assert;
const tm = @import("../engine/transform.zig");

pub const AlphaMode = enum {
    Opaque,
    Mask,
    Transparent,
};

fn alpha_mode_from_zcgltf(alpha_mode: zmesh.io.zcgltf.AlphaMode) AlphaMode {
    return switch (alpha_mode) {
        .@"opaque" => AlphaMode.Opaque,
        .@"mask" => AlphaMode.Mask,
        .@"blend" => AlphaMode.Transparent,
    };
}

pub const PrimitiveTopology = enum {
    Points,
    Lines,
    LineLoop,
    LineStrip,
    Triangles,
    TriangleStrip,
    TriangleFan,
};

fn primitive_topology_from_zcgltf(topology: zmesh.io.zcgltf.PrimitiveType) PrimitiveTopology {
    return switch (topology) {
        .@"points" => PrimitiveTopology.Points,
        .@"lines" => PrimitiveTopology.Lines,
        .@"line_strip" => PrimitiveTopology.LineStrip,
        .@"line_loop" => PrimitiveTopology.LineLoop,
        .@"triangles" => PrimitiveTopology.Triangles,
        .@"triangle_strip" => PrimitiveTopology.TriangleStrip,
        .@"triangle_fan" => PrimitiveTopology.TriangleFan,
    };
}

pub const MaterialDescriptor = struct {
    alpha_mode: AlphaMode = AlphaMode.Opaque,
    alpha_cutoff: f32 = 0.0,
    double_sided: bool = true,
    unlit: bool = false,
};

pub const MeshPrimitive = struct {
    num_indices: usize,
    num_vertices: usize,
    indices_offset: usize,
    pos_offset: usize,
    nor_offset: usize,
    tex_coord_offset: usize,
    tangents_offset: usize,
    topology: PrimitiveTopology,
    material_descriptor: MaterialDescriptor,

    // Check whether the mesh primitive has indices
    pub inline fn has_indices(self: *const MeshPrimitive) bool {
        return self.num_indices != 0;
    }
};

pub const Mesh = struct {
    buffers: Buffers,
    primitives: []MeshPrimitive,
    physics_shape: *zphy.Shape,
};

pub const ModelNode = struct {
    name: ?[]u8 = null,
    transform: tm.Transform = tm.Transform.new(),
    mesh: ?*Mesh = null,
    children: ?[]usize = null,
    parent: ?usize = null,
};

pub const Buffers = struct {
    indices: *d3d11.IBuffer,
    positions: *d3d11.IBuffer,
    normals: ?*d3d11.IBuffer,
    tex_coords: ?*d3d11.IBuffer,
    tangents: ?*d3d11.IBuffer,
};

pub const Model = struct {
    const Self = @This();
    buffers: Buffers,
    mesh_list: []Mesh,
    nodes_list: []ModelNode,
    root_nodes: []usize,
    arena_allocator: *std.heap.ArenaAllocator,

    pub fn init_from_file(alloc: std.mem.Allocator, file: [:0]const u8, gfx_device: *d3d11.IDevice) !Self {
        const data = try zmesh.io.parseAndLoadFile(file);
        defer zmesh.io.freeData(data);

        var model_arena_allocator = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(model_arena_allocator);

        model_arena_allocator.* = std.heap.ArenaAllocator.init(alloc);
        errdefer model_arena_allocator.deinit();
        var model_arena = model_arena_allocator.allocator();

        var local_arena = std.heap.ArenaAllocator.init(alloc);
        defer local_arena.deinit();

        // Create a number of array lists to store attribute data of various types.
        // This will later be used to construct model-wide gfx buffers.
        var mesh_indices = std.ArrayList(u32).init(local_arena.allocator());
        var mesh_positions = std.ArrayList([3]f32).init(local_arena.allocator());
        var mesh_normals = std.ArrayList([3]f32).init(local_arena.allocator());
        var mesh_tex_coords = std.ArrayList([2]f32).init(local_arena.allocator());
        var mesh_tangents = std.ArrayList([4]f32).init(local_arena.allocator());

        // Create an arraylist ready to store upcoming meshes
        var meshes = try model_arena.alloc(Mesh, data.meshes_count);

        // Iterate through meshes and their primitives adding all data to 
        // the above arraylists and appending mesh data to a arraylist
        for (0..data.meshes_count) |mi| {
            const m = &data.meshes.?[mi];
            var mesh = Mesh{
                .primitives = try model_arena.alloc(MeshPrimitive, m.primitives_count),
                // will set this later after the gpu buffers are created
                .buffers = undefined,
                .physics_shape = undefined,
            };

            for (0..m.primitives_count) |pi| {
                var prim_mat = MaterialDescriptor {};
                if (m.primitives[pi].material) |material| {
                    prim_mat.double_sided = material.double_sided > 0;
                    prim_mat.alpha_mode = alpha_mode_from_zcgltf(material.alpha_mode);
                    prim_mat.alpha_cutoff = material.alpha_cutoff;
                    prim_mat.unlit = material.unlit > 0;
                }

                var prim = MeshPrimitive {
                    .num_indices = undefined,
                    .num_vertices = undefined,
                    .indices_offset = mesh_indices.items.len,
                    .pos_offset = mesh_positions.items.len,
                    .nor_offset = mesh_normals.items.len,
                    .tex_coord_offset = mesh_tex_coords.items.len,
                    .tangents_offset = mesh_tangents.items.len,
                    .material_descriptor = prim_mat,
                    .topology = primitive_topology_from_zcgltf(m.primitives[pi].type),
                };

                try appendMeshPrimitive(
                    data,
                    @intCast(mi),
                    @intCast(pi),
                    &mesh_indices,
                    &mesh_positions,
                    &mesh_normals,
                    [_]?*std.ArrayList([2]f32){&mesh_tex_coords, null, null, null},
                    &mesh_tangents
                );

                prim.num_vertices = mesh_positions.items.len - prim.pos_offset;
                prim.num_indices = mesh_indices.items.len - prim.indices_offset;
                mesh.primitives[pi] = prim;
            }

            // Construct physics shape for the mesh taking into account all its primitives
            {
                const primf = &mesh.primitives[0];
                const total_num_verticies_in_all_primitives = mesh_positions.items.len - primf.pos_offset;

                const settings = try zphy.ConvexHullShapeSettings.create(
                    &(mesh_positions.items[primf.pos_offset]), 
                    @intCast(total_num_verticies_in_all_primitives), 
                    @sizeOf([3]f32));
                defer settings.release();

                //settings.setMaxConvexRadius(0.1);

                mesh.physics_shape = try settings.createShape();
            }

            // Finally append mesh to mesh list
            meshes[mi] = mesh;
        }

        // Create buffers on GPU
        var buffers = Buffers {
            .indices = undefined,
            .positions = undefined,
            .normals = null,
            .tex_coords = null,
            .tangents = null,
        };

        // Positions
        const vert_pos_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(f32) * 3 * @as(c_uint, @intCast(mesh_positions.items.len)),
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_pos_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_positions.items.ptr), }, @ptrCast(&buffers.positions)));
        errdefer _ = buffers.positions.Release();

        // Normals
        if (mesh_normals.items.len != 0) {
            const vert_norm_buffer_desc = d3d11.BUFFER_DESC {
                .Usage = d3d11.USAGE.IMMUTABLE,
                .ByteWidth = @sizeOf(f32) * 3 * @as(c_uint, @intCast(mesh_normals.items.len)),
                .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
            };
            try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_norm_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_normals.items.ptr), }, @ptrCast(&buffers.normals)));
        }
        errdefer { if (buffers.normals) |n| { _ = n.Release(); } }

        // Tex Coords
        if (mesh_tex_coords.items.len != 0) {
            const vert_tex_coord_buffer_desc = d3d11.BUFFER_DESC {
                .Usage = d3d11.USAGE.IMMUTABLE,
                .ByteWidth = @sizeOf(f32) * 2 * @as(c_uint, @intCast(mesh_tex_coords.items.len)),
                .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
            };
            try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_tex_coord_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_tex_coords.items.ptr), }, @ptrCast(&buffers.tex_coords)));
        }
        errdefer { if (buffers.tex_coords) |b| { _ = b.Release(); } }

        // Tangents
        if (mesh_tangents.items.len != 0) {
            const vert_tangents_buffer_desc = d3d11.BUFFER_DESC {
                .Usage = d3d11.USAGE.IMMUTABLE,
                .ByteWidth = @sizeOf(f32) * 4 * @as(c_uint, @intCast(mesh_tangents.items.len)),
                .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
            };
            try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&vert_tangents_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_tangents.items.ptr), }, @ptrCast(&buffers.tangents)));
        }
        errdefer { if (buffers.tangents) |b| { _ = b.Release(); } }

        // Indices
        const indices_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(u32) * @as(c_uint, @intCast(mesh_indices.items.len)),
            .BindFlags = d3d11.BIND_FLAG{ .INDEX_BUFFER = true, },
        };
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&indices_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_indices.items.ptr), }, @ptrCast(&buffers.indices)));
        errdefer _ = buffers.indices.Release();

        // Link buffers in all meshes
        for (meshes) |*m| {
            m.buffers = buffers;
        }

        // Nodes
        var nodes_list = try model_arena.alloc(ModelNode, data.nodes_count);
        @memset(nodes_list, ModelNode{});

        for (0..data.nodes_count) |gltf_node_idx| {
            const gltf_node = &data.nodes.?[gltf_node_idx];   

            var name: ?[]u8 = null;
            if (gltf_node.name != null) {
                name = try std.fmt.allocPrint(model_arena, "{s}", .{gltf_node.name.?});
            }

            var transform = tm.Transform.new();
            transform.position = zm.f32x4(gltf_node.translation[0], gltf_node.translation[1], gltf_node.translation[2], 0.0);
            transform.rotation = zm.f32x4(gltf_node.rotation[0], gltf_node.rotation[1], gltf_node.rotation[2], gltf_node.rotation[3]);
            transform.scale = zm.f32x4(gltf_node.scale[0], gltf_node.scale[1], gltf_node.scale[2], 1.0);

            var mesh: ?*Mesh = null;
            if (gltf_node.mesh) |m| {
                // pointer math to convert zmesh mesh pointer to its index in the meshes array in data
                const mesh_index = (@intFromPtr(m) - @intFromPtr(data.meshes)) / @sizeOf(zmesh.io.zcgltf.Mesh);
                std.debug.assert(mesh_index >= 0 and mesh_index < meshes.len);

                mesh = &meshes[mesh_index];
            }

            // link all children
            var children = try model_arena.alloc(usize, gltf_node.children_count);
            if (gltf_node.children) |_| {
                for (0..gltf_node.children_count) |child_idx| {
                    const node_index_in_model_nodes_list = (@intFromPtr(gltf_node.children.?[child_idx]) - @intFromPtr(data.nodes.?)) / @sizeOf(zmesh.io.zcgltf.Node);
                    // Assert child node index is within bounds
                    std.debug.assert(node_index_in_model_nodes_list >= 0 and node_index_in_model_nodes_list < data.nodes_count);

                    // Assert child does not already have a parent set
                    std.debug.assert(nodes_list[node_index_in_model_nodes_list].parent == null);
                    // Set parent on the child node
                    nodes_list[node_index_in_model_nodes_list].parent = gltf_node_idx;

                    // Add child to current node
                    children[child_idx] = node_index_in_model_nodes_list;
                }
            }

            nodes_list[gltf_node_idx] = ModelNode {
                .name = name,
                .transform = transform,
                .mesh = mesh,
                .children = children,

                // the parent field is set out of order, hence we need to copy it from the already 
                // existing data when creating the new ModelNode
                .parent = nodes_list[gltf_node_idx].parent,
            };
        }

        std.debug.assert(data.scene != null);
        var root_nodes_list = try model_arena.alloc(usize, data.scene.?.nodes_count);
        for (0..data.scene.?.nodes_count) |n_idx| {
            const node_index_in_model_nodes_list = (@intFromPtr(data.scene.?.nodes.?[n_idx]) - @intFromPtr(data.nodes.?)) / @sizeOf(zmesh.io.zcgltf.Node);
            std.debug.assert(node_index_in_model_nodes_list >= 0 and node_index_in_model_nodes_list < data.nodes_count);
            root_nodes_list[n_idx] = node_index_in_model_nodes_list;
        }

        return Self {
            .buffers = buffers,
            .mesh_list = meshes,
            .nodes_list = nodes_list,
            .root_nodes = root_nodes_list,
            .arena_allocator = model_arena_allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.mesh_list) |*m| {
            m.physics_shape.release();
        }

        self.arena_allocator.deinit();
        self.arena_allocator.child_allocator.destroy(self.arena_allocator);

        _ = self.buffers.indices.Release();
        _ = self.buffers.positions.Release();
        if (self.buffers.normals) |b| { _ = b.Release(); }
        if (self.buffers.tex_coords) |b| { _ = b.Release(); }
        if (self.buffers.tangents) |b| { _ = b.Release(); }
    }
};

pub fn appendMeshPrimitive(
    data: *zmesh.io.zcgltf.Data,
    mesh_index: u32,
    prim_index: u32,
    indices: *std.ArrayList(u32),
    positions: *std.ArrayList([3]f32),
    normals: ?*std.ArrayList([3]f32),
    texcoords: [4]?*std.ArrayList([2]f32),
    tangents: ?*std.ArrayList([4]f32),
) !void {
    assert(mesh_index < data.meshes_count);
    assert(prim_index < data.meshes.?[mesh_index].primitives_count);

    const mesh = &data.meshes.?[mesh_index];
    const prim = &mesh.primitives[prim_index];

    const num_vertices: u32 = @as(u32, @intCast(prim.attributes[0].data.count));
    const num_indices: u32 = @as(u32, @intCast(prim.indices.?.count));

    // Indices.
    {
        try indices.ensureTotalCapacity(indices.items.len + num_indices);

        const accessor = prim.indices.?;
        const buffer_view = accessor.buffer_view.?;

        assert(accessor.stride == buffer_view.stride or buffer_view.stride == 0);
        assert(accessor.stride * accessor.count == buffer_view.size);
        assert(buffer_view.buffer.data != null);

        const data_addr = @as([*]const u8, @ptrCast(buffer_view.buffer.data)) +
            accessor.offset + buffer_view.offset;

        if (accessor.stride == 1) {
            assert(accessor.component_type == .r_8u);
            const src = @as([*]const u8, @ptrCast(data_addr));
            var i: u32 = 0;
            while (i < num_indices) : (i += 1) {
                indices.appendAssumeCapacity(src[i]);
            }
        } else if (accessor.stride == 2) {
            assert(accessor.component_type == .r_16u);
            const src = @as([*]const u16, @ptrCast(@alignCast(data_addr)));
            var i: u32 = 0;
            while (i < num_indices) : (i += 1) {
                indices.appendAssumeCapacity(src[i]);
            }
        } else if (accessor.stride == 4) {
            assert(accessor.component_type == .r_32u);
            const src = @as([*]const u32, @ptrCast(@alignCast(data_addr)));
            var i: u32 = 0;
            while (i < num_indices) : (i += 1) {
                indices.appendAssumeCapacity(src[i]);
            }
        } else {
            unreachable;
        }
    }

    // Attributes.
    {
        const attributes = prim.attributes[0..prim.attributes_count];
        for (attributes) |attrib| {
            const accessor = attrib.data;

            const buffer_view = accessor.buffer_view.?;
            assert(buffer_view.buffer.data != null);

            assert(accessor.stride == buffer_view.stride or buffer_view.stride == 0);
            assert(accessor.stride * accessor.count == buffer_view.size);

            const data_addr = @as([*]const u8, @ptrCast(buffer_view.buffer.data)) +
                accessor.offset + buffer_view.offset;

            switch (attrib.type) {
                .position => {
                    assert(accessor.type == .vec3);
                    const slice = @as([*]const [3]f32, @ptrCast(@alignCast(data_addr)))[0..num_vertices];
                    try positions.appendSlice(slice);
                },
                .normal => {
                    if (normals) |n| {
                        assert(accessor.type == .vec3);
                        const slice = @as([*]const [3]f32, @ptrCast(@alignCast(data_addr)))[0..num_vertices];
                        try n.appendSlice(slice);
                    }
                },
                .texcoord => {
                    if (attrib.index < 4) {
                        if (texcoords[@intCast(attrib.index)]) |tc| {
                            assert(accessor.type == .vec2);
                            const slice = @as([*]const [2]f32, @ptrCast(@alignCast(data_addr)))[0..num_vertices];
                            try tc.appendSlice(slice);
                        }
                    } else {
                        std.log.warn("Model has tex coord index larger than max. Idx: {}", .{attrib.index});
                    }
                },
                .tangent => {
                    if (tangents) |tan| {
                        assert(accessor.type == .vec4);
                        const slice = @as([*]const [4]f32, @ptrCast(@alignCast(data_addr)))[0..num_vertices];
                        try tan.appendSlice(slice);
                    }
                },
                .color => {

                },
                .joints => {

                },
                .weights => {

                },
                else => {},
            }
        }
    }
}
