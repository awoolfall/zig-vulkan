const std = @import("std");
const zmesh = @import("zmesh");
const zwin32 = @import("zwin32");
const zm = @import("zmath");
const zphy = @import("zphysics");
const d3d11 = zwin32.d3d11;
const assert = std.debug.assert;
const tm = @import("../engine/transform.zig");
const path = @import("../engine/path.zig");
const an = @import("anim3d.zig");
const assimp = @import("assimp");

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
    positions: [][3]f32,

    // Check whether the mesh primitive has indices
    pub inline fn has_indices(self: *const MeshPrimitive) bool {
        return self.num_indices != 0;
    }
};

pub const BoundingBox = struct {
    min: zm.F32x4,
    max: zm.F32x4,

    pub fn center(self: *const BoundingBox) zm.F32x4 {
        return (self.max + self.min) / zm.f32x4s(2.0);
    }
};

pub const MAX_PRIMITIVES_PER_SET = 8;
pub const MeshSet = struct {
    primitives: [MAX_PRIMITIVES_PER_SET]?usize,
    physics_shape_settings: *zphy.ShapeSettings,

    pub fn deinit(self: *MeshSet) void {
        self.physics_shape_settings.release();
    }

    fn generate_physics_shape(self: *MeshSet, alloc: std.mem.Allocator, prims: []MeshPrimitive) !void {
        var mesh_set_positions = std.ArrayList([3]f32).init(alloc);
        defer mesh_set_positions.deinit();

        for (self.primitives) |maybe_prim| {
            if (maybe_prim) |prim_idx| {
                const prim = &prims[prim_idx];
                try mesh_set_positions.appendSlice(prim.positions);
            }
        }

        // Construct physics shape for the mesh taking into account all its primitives
        self.physics_shape_settings = @ptrCast(try zphy.ConvexHullShapeSettings.create(
                @ptrCast(mesh_set_positions.items.ptr), 
                @intCast(mesh_set_positions.items.len), 
                @sizeOf([3]f32)));
    }
};

pub const BoneData = struct {
    id: usize,
    offset: zm.Mat, // offset matrix transforms from model space to bone space
};

pub const ModelNode = struct {
    name: ?[]u8 = null,
    transform: tm.Transform = tm.Transform.new(),
    mesh: ?MeshSet = null,
    bone_data: ?BoneData = null,
    children: []usize = ([_]usize{})[0..0],
    parent: ?usize = null,

    pub fn deinit(self: *ModelNode) void {
        if (self.mesh) |*mesh| {
            mesh.deinit();
        }
        self.mesh = null;
    }
};

pub const Buffers = struct {
    indices: *d3d11.IBuffer,
    positions: *d3d11.IBuffer,
    normals: ?*d3d11.IBuffer,
    tex_coords: ?*d3d11.IBuffer,
    tangents: ?*d3d11.IBuffer,
    bone_ids: ?*d3d11.IBuffer,
    bone_weights: ?*d3d11.IBuffer,

    pub fn deinit(self: *const Buffers) void {
        _ = self.indices.Release();
        _ = self.positions.Release();
        if (self.normals) |b| { _ = b.Release(); }
        if (self.tex_coords) |b| { _ = b.Release(); }
        if (self.tangents) |b| { _ = b.Release(); }
        if (self.bone_ids) |b| { _ = b.Release(); }
        if (self.bone_weights) |b| { _ = b.Release(); }
    }

    fn create_vertex_buffer(
        comptime T: type,
        data: []const T,
        gfx_device: *d3d11.IDevice
    ) !*d3d11.IBuffer {
        const buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(T) * @as(c_uint, @intCast(data.len)),
            .BindFlags = d3d11.BIND_FLAG{ .VERTEX_BUFFER = true, },
        };
        var buffer: *d3d11.IBuffer = undefined;
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(data.ptr), }, @ptrCast(&buffer)));
        return buffer;
    }

    fn init_with_data(
        mesh_indices: []const u32,
        mesh_positions: []const ([3]f32),
        mesh_normals: []const ([3]f32),
        mesh_tex_coords: []const ([2]f32),
        mesh_tangents: []const ([4]f32),
        mesh_bone_ids: []const ([4]i32),
        mesh_weights: []const ([4]f32),
        gfx_device: *d3d11.IDevice,
    ) !Buffers {
        // Create buffers on GPU
        var buffers = Buffers {
            .indices = undefined,
            .positions = undefined,
            .normals = null,
            .tex_coords = null,
            .tangents = null,
            .bone_ids = null,
            .bone_weights = null,
        };

        // Positions
        buffers.positions = try create_vertex_buffer([3]f32, mesh_positions, gfx_device);
        errdefer _ = buffers.positions.Release();

        // Indices
        const indices_buffer_desc = d3d11.BUFFER_DESC {
            .Usage = d3d11.USAGE.IMMUTABLE,
            .ByteWidth = @sizeOf(u32) * @as(c_uint, @intCast(mesh_indices.len)),
            .BindFlags = d3d11.BIND_FLAG{ .INDEX_BUFFER = true, },
        };
        try zwin32.hrErrorOnFail(gfx_device.CreateBuffer(&indices_buffer_desc, &d3d11.SUBRESOURCE_DATA{ .pSysMem = @ptrCast(mesh_indices.ptr), }, @ptrCast(&buffers.indices)));
        errdefer _ = buffers.indices.Release();

        // Normals
        if (mesh_normals.len != 0) {
            buffers.normals = try create_vertex_buffer([3]f32, mesh_normals, gfx_device);
        }
        errdefer { if (buffers.normals) |n| { _ = n.Release(); } }

        // Tex Coords
        if (mesh_tex_coords.len != 0) {
            buffers.tex_coords = try create_vertex_buffer([2]f32, mesh_tex_coords, gfx_device);
        }
        errdefer { if (buffers.tex_coords) |b| { _ = b.Release(); } }

        // Tangents
        if (mesh_tangents.len != 0) {
            buffers.tangents = try create_vertex_buffer([4]f32, mesh_tangents, gfx_device);
        }
        errdefer { if (buffers.tangents) |b| { _ = b.Release(); } }

        // Bone ids
        buffers.bone_ids = try create_vertex_buffer([4]i32, mesh_bone_ids, gfx_device);
        errdefer { _ = buffers.bone_ids.?.Release(); }

        // Bone weights
        buffers.bone_weights = try create_vertex_buffer([4]f32, mesh_weights, gfx_device);
        errdefer { _ = buffers.bone_weights.?.Release(); }

        // Return constructed buffers
        return buffers;
    }
};

pub const AnimationKey = struct {
    time: f64,
    value: zm.F32x4,
};

pub const BoneAnimationChannel = struct {
    bone_id: usize,
    position_keys: []AnimationKey,
    rotation_keys: []AnimationKey,
    scale_keys: []AnimationKey,
};

pub const BoneAnimation = struct {
    name: []u8,
    duration: f64,
    ticks_per_second: f64,
    channels: []BoneAnimationChannel,
};

pub const Model = struct {
    const Self = @This();
    buffers: Buffers,
    mesh_list: []MeshPrimitive,
    nodes_list: []ModelNode,
    root_nodes: []usize,
    animations: []BoneAnimation,
    arena_allocator: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Self) void {
        for (self.nodes_list) |*node| {
            node.deinit();
        }

        self.arena_allocator.deinit();
        self.arena_allocator.child_allocator.destroy(self.arena_allocator);

        self.buffers.deinit();
    }

    pub fn init_from_file_cgltf(alloc: std.mem.Allocator, file: path.Path, gfx_device: *d3d11.IDevice) !Self {
        const file_path = try file.resolve_path_c_str(alloc);
        defer alloc.free(file_path);

        const data = try zmesh.io.parseAndLoadFile(file_path);
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

        // Create an arraylist ready to store upcoming mesh primitives
        var mesh_primatives_list = std.ArrayList(MeshPrimitive).init(local_arena.allocator());
        defer mesh_primatives_list.deinit();

        // Create a mesh sets array
        const mesh_sets = try local_arena.allocator().alloc(MeshSet, data.meshes_count);
        defer {
            for (mesh_sets) |*mesh| {
                mesh.physics_shape_settings.release();
            }
            local_arena.allocator().free(mesh_sets);
        }

        // Iterate through meshes and their primitives adding all data to 
        // the above arraylists and appending mesh data to a arraylist
        for (0..data.meshes_count) |mi| {
            mesh_sets[mi] = MeshSet {
                .primitives = [_]?usize{null} ** MAX_PRIMITIVES_PER_SET,
                .physics_shape_settings = undefined,
            };

            const m = &data.meshes.?[mi];

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
                    .positions = undefined,
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

                prim.positions = try model_arena.alloc([3]f32, prim.num_vertices);
                @memcpy(prim.positions, mesh_positions.items[prim.pos_offset..]);

                try mesh_primatives_list.append(prim);
                mesh_sets[mi].primitives[pi] = mesh_primatives_list.items.len - 1;
            }

            try mesh_sets[mi].generate_physics_shape(alloc, mesh_primatives_list.items);
        }

        const buffers = try Buffers.init_with_data(
            mesh_indices.items,
            mesh_positions.items,
            mesh_normals.items,
            mesh_tex_coords.items,
            mesh_tangents.items,
            null,
            null,
            gfx_device
        );
        errdefer buffers.deinit();

        // Solidify mesh primitives list into a constant size array, this will be used in the model
        const mesh_primitives = try model_arena.alloc(MeshPrimitive, mesh_primatives_list.items.len);
        errdefer model_arena.free(mesh_primitives);
        @memcpy(mesh_primitives, mesh_primatives_list.items);

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

            var mesh: ?MeshSet = null;
            if (gltf_node.mesh) |m| {
                // pointer math to convert zmesh mesh pointer to its index in the meshes array in data
                const mesh_index = (@intFromPtr(m) - @intFromPtr(data.meshes)) / @sizeOf(zmesh.io.zcgltf.Mesh);
                std.debug.assert(mesh_index >= 0 and mesh_index < mesh_sets.len);

                mesh = mesh_sets[mesh_index];
                mesh.?.physics_shape_settings.addRef();
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
            .mesh_list = mesh_primitives,
            .nodes_list = nodes_list,
            .root_nodes = root_nodes_list,
            .animations = ([0]BoneAnimation{})[0..0],
            .arena_allocator = model_arena_allocator,
        };
    }

    pub fn init_from_file_assimp(alloc: std.mem.Allocator, file: path.Path, gfx_device: *d3d11.IDevice) !Self {
        const file_path = try file.resolve_path_c_str(alloc);
        defer alloc.free(file_path);

        const calc_tangents_flag: u32 = 0x1;
        const triangulate_flag: u32 = 0x8;
        const global_scale_flag: u32 = 0x8000000;
        const optimize_mesh_flag: u32 = 0x200000;
        //const optimize_graph_flag: u32 = 0x400000;
        const armature_data_flag: u32 = 0x4000;

        var prop_store = assimp.ImportPropertyStore.init();
        defer prop_store.deinit();

        prop_store.set_fbx_preserve_pivots(false);

        const scene = try assimp.aiImportFileWithProps(file_path, 
            calc_tangents_flag | triangulate_flag | global_scale_flag | optimize_mesh_flag | armature_data_flag,
            &prop_store);
        defer assimp.aiReleaseImport(scene);

        // for (scene.materials(), 0..) |mat, i| {
        //     for (mat.properties()) |prop| {
        //         std.log.info("material {d} property [{s}] is {}", .{i, prop.key(), prop.property_type()});
        //     }
        //     std.log.info("material diffuse count is {d}", .{
        //         mat.get_texture_count(assimp.TextureType.Diffuse)
        //     });
        //     const props = mat.get_texture_properties(assimp.TextureType.Diffuse, 0);
        //     if (props != null) {
        //         std.log.info("material diffuse props are {}", .{props.?});
        //     }
        // }
        //
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

        // Create an array ready to store upcoming mesh primitives
        const mesh_primatives = try model_arena.alloc(MeshPrimitive, scene.meshes().len);
        errdefer model_arena.free(mesh_primatives);

        var mesh_bone_ids = std.ArrayList([4]i32).init(local_arena.allocator());
        var mesh_weights = std.ArrayList([4]f32).init(local_arena.allocator());

        var node_bone_id_map = std.StringHashMap(BoneIdMapElem).init(local_arena.allocator());
        defer node_bone_id_map.deinit();

        // Assimp meshes are equivilent to MeshPrimitive,
        // Assimp nodes contain a list of meshes. These are equivilent to MeshSet.
        // Iterate through all assimp meshes and create MeshPrimitive for each, store These
        // in an array for use later.
        var bid: usize = 0;
        {
            for (scene.meshes(), 0..) |mesh, idx| {
                var prim_mat = MaterialDescriptor {}; // @TODO
                prim_mat.double_sided = true;
                // if (m.primitives[pi].material) |material| {
                //     prim_mat.double_sided = material.double_sided > 0;
                //     prim_mat.alpha_mode = alpha_mode_from_zcgltf(material.alpha_mode);
                //     prim_mat.alpha_cutoff = material.alpha_cutoff;
                //     prim_mat.unlit = material.unlit > 0;
                // }
                //

                var prim = MeshPrimitive {
                    .num_indices = undefined,
                    .num_vertices = undefined,
                    .positions = undefined,
                    .indices_offset = mesh_indices.items.len,
                    .pos_offset = mesh_positions.items.len,
                    .nor_offset = mesh_normals.items.len,
                    .tex_coord_offset = mesh_tex_coords.items.len,
                    .tangents_offset = mesh_tangents.items.len,
                    .material_descriptor = prim_mat,
                    .topology = .Triangles, // @TODO
                };

                // assert assimp sizes match what we expect
                std.debug.assert(@sizeOf(assimp.Vector3D) == @sizeOf([3]f32));
                std.debug.assert(@sizeOf(assimp.Vector4D) == @sizeOf([4]f32));
                std.debug.assert(@sizeOf(c_uint) == @sizeOf(u32));

                // copy positions
                try mesh_positions.appendSlice(@as(*const [][3]f32, @ptrCast(&(mesh.vertices().?))).*);
                if (mesh.faces()) |faces| {
                    for (faces) |*face| {
                        try mesh_indices.appendSlice(@as(*const []u32, @ptrCast(&(face.indices().?))).*);
                    }
                }
                // copy normals
                if (mesh.normals()) |normals| {
                    try mesh_normals.appendSlice(@as(*const [][3]f32, @ptrCast(&normals)).*);
                }
                // copy texcoords, converting to vec2
                if (mesh.texcoords(0)) |texcoords| {
                    const texcoords_v2 = try alloc.alloc([2]f32, texcoords.len);
                    defer alloc.free(texcoords_v2);

                    for (texcoords, 0..) |t, i| {
                        texcoords_v2[i] = [2]f32{t.x, t.y};
                    }

                    try mesh_tex_coords.appendSlice(texcoords_v2);
                }
                // copy tangents, converting to vec4
                if (mesh.tangents()) |tangents| {
                    const tangents_v4 = try alloc.alloc([4]f32, tangents.len);
                    defer alloc.free(tangents_v4);

                    for (tangents, 0..) |t, i| {
                        tangents_v4[i] = [4]f32{t.x, t.y, t.z, 0.0};
                    }

                    try mesh_tangents.appendSlice(tangents_v4);
                }

                prim.num_vertices = mesh_positions.items.len - prim.pos_offset;
                prim.num_indices = mesh_indices.items.len - prim.indices_offset;

                prim.positions = try model_arena.alloc([3]f32, prim.num_vertices);
                @memcpy(prim.positions, mesh_positions.items[prim.pos_offset..]);

                mesh_primatives[idx] = prim;

                // Fill bones data
                try mesh_bone_ids.appendNTimes([_]i32{an.AnimController3d.MAX_BONES - 1} ** 4, prim.num_vertices);
                try mesh_weights.appendNTimes([4]f32{1.0, 0.0, 0.0, 0.0}, prim.num_vertices);

                for (mesh.bones()) |bn| {
                    var bone_id: usize = undefined;
                    if (node_bone_id_map.get(bn.node().?.name())) |elem| {
                        bone_id = elem.id;
                    } else {
                        bone_id = bid;
                        try node_bone_id_map.put(bn.node().?.name(), BoneIdMapElem { .id = bone_id, .bone = bn, });
                        bid += 1;
                    }

                    for (bn.weights()) |*wg| {
                        // insert bone id and weights into relevant vertex
                        // sorting values from highest to lowest weight.
                        // That way if we go over 4 bones per vertex it is the
                        // least affecting values which are dropped.
                        const vertId = prim.pos_offset + wg.mVertexId;
                        // for (mesh_weights.items[vertId], 0..) |w, wi| {
                        //     if (wg.mWeight > w) {
                        //         for (0..4) |wj| {
                        //             if (wj == wi) {break;}
                        //             mesh_weights.items[vertId][3-wj] = mesh_weights.items[vertId][3-wj - 1];
                        //             mesh_bone_ids.items[vertId][3-wj] = mesh_bone_ids.items[vertId][3-wj - 1];
                        //         }
                        //         mesh_weights.items[vertId][wi] = wg.mWeight;
                        //         mesh_bone_ids.items[vertId][wi] = @intCast(bone_id);
                        //         break;
                        //     }
                        // }
                        for (mesh_bone_ids.items[vertId], 0..) |mesh_bone_id, i| {
                            if (mesh_bone_id == (an.AnimController3d.MAX_BONES - 1)) { 
                                mesh_bone_ids.items[vertId][i] = @intCast(bone_id);
                                mesh_weights.items[vertId][i] = wg.mWeight;
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Normalise bone weights
        for (mesh_weights.items) |*w| {
            const sum = w[0] + w[1] + w[2] + w[3];
            w[0] /= sum;
            w[1] /= sum;
            w[2] /= sum;
            w[3] /= sum;
        }

        // create gfx buffers from vertex data
        const buffers = try Buffers.init_with_data(
            mesh_indices.items,
            mesh_positions.items,
            mesh_normals.items,
            mesh_tex_coords.items,
            mesh_tangents.items,
            mesh_bone_ids.items,
            mesh_weights.items,
            gfx_device
        );
        errdefer buffers.deinit();

        // create a flat list to store upcoming nodes in
        var model_nodes_list = std.ArrayList(ModelNode).init(local_arena.allocator());
        defer model_nodes_list.deinit();

        // allocate space to store the root node, assimp only has 1
        const root_node = try model_arena.alloc(usize, 1);
        errdefer model_arena.free(root_node);

        // create a map to cache physics shape data. For performance reasons we want
        // to generate these as few times as possible.
        var physics_shape_map = std.AutoHashMap([MAX_PRIMITIVES_PER_SET]?usize, *zphy.ShapeSettings).init(local_arena.allocator());
        defer physics_shape_map.deinit();

        // Recursively load assimp nodes into ModelNodes.
        root_node[0] = try assimp_recursively_load_node(
            model_arena,
            scene.root_node().?,
            null,
            mesh_primatives,
            &model_nodes_list,
            &physics_shape_map
        );

        // Solidify arraylist into a dynamically allocated array using model arena.
        const model_nodes = try model_arena.alloc(ModelNode, model_nodes_list.items.len);
        @memcpy(model_nodes, model_nodes_list.items);

        // Nodes name map
        var nodes_name_map = std.StringHashMap(usize).init(local_arena.allocator());
        defer nodes_name_map.deinit();

        for (model_nodes, 0..) |*nd, id| {
            if (nd.name) |nm| {
                try nodes_name_map.put(nm, id);
                // if (nd.parent) |p| {
                //     std.log.info("node {} name {s} - {s}", .{id, nm, model_nodes[p].name.?});
                // } else {
                //     std.log.info("node {} name {s}", .{id, nm});
                // }
            }
        }

        for (model_nodes) |*node| {
            if (node.name) |name| {
                if (node_bone_id_map.get(name)) |elem| {
                    node.bone_data = BoneData {
                        .id = elem.id,
                        .offset = elem.bone.offset_matrix(),
                    };
                }
            }
        }

        // Load animations
        const animations = try model_arena.alloc(BoneAnimation, scene.animations().len);
        errdefer model_arena.free(animations);

        for (scene.animations(), 0..) |anim, anim_id| {
            animations[anim_id] = BoneAnimation {
                .name = try std.fmt.allocPrint(model_arena, "{s}", .{anim.name()}),
                .duration = anim.duration(),
                .ticks_per_second = anim.ticks_per_second(),
                .channels = try model_arena.alloc(BoneAnimationChannel, anim.channels().len),
            };
            for (anim.channels(), 0..) |ch, ch_id| {
                const node_id = nodes_name_map.get(ch.node_name()).?;

                // Add missing bones
                if (model_nodes[node_id].bone_data == null) {
                    model_nodes[node_id].bone_data = BoneData {
                        .id = bid,
                        .offset = zm.identity(),
                    };
                    bid += 1;
                }

                animations[anim_id].channels[ch_id] = BoneAnimationChannel {
                    .bone_id = model_nodes[node_id].bone_data.?.id,
                    .position_keys = try model_arena.alloc(AnimationKey, ch.position_keys().len),
                    .rotation_keys = try model_arena.alloc(AnimationKey, ch.rotation_keys().len),
                    .scale_keys = try model_arena.alloc(AnimationKey, ch.scale_keys().len),
                };
                // std.log.info("anim node {} name is {s}", .{node_id, ch.node_name()});

                for (ch.position_keys(), 0..) |pk, pk_id| {
                    animations[anim_id].channels[ch_id].position_keys[pk_id] = AnimationKey {
                        .time = pk.time(),
                        .value = pk.value(),
                    };
                }

                for (ch.rotation_keys(), 0..) |rk, rk_id| {
                    animations[anim_id].channels[ch_id].rotation_keys[rk_id] = AnimationKey {
                        .time = rk.time(),
                        .value = rk.value(),
                    };
                }

                for (ch.scale_keys(), 0..) |sk, sk_id| {
                    animations[anim_id].channels[ch_id].scale_keys[sk_id] = AnimationKey {
                        .time = sk.time(),
                        .value = sk.value(),
                    };
                }
            }
        }

        std.log.info("animations are:", .{});
        for (animations) |*anim| {
            std.log.info("\t- {s}", .{anim.name});
        }

        return Self {
            .buffers = buffers,
            .mesh_list = mesh_primatives,
            .nodes_list = model_nodes,
            .root_nodes = root_node,
            .animations = animations,
            .arena_allocator = model_arena_allocator,
        };
    }

    // Recusively loads an assimp node and all it's children into model_nodes_list,
    // returns the node's index in the model_nodes_list arraylist.
    fn assimp_recursively_load_node(
        alloc: std.mem.Allocator, 
        node: assimp.Node.Ptr, 
        parent: ?usize, 
        prims: []MeshPrimitive, 
        model_nodes_list: *std.ArrayList(ModelNode),
        physics_shape_map: *std.AutoHashMap([MAX_PRIMITIVES_PER_SET]?usize, *zphy.ShapeSettings),
    ) !usize {
        // Append new ModelNode to list and acquire its index
        try model_nodes_list.append(ModelNode{});
        const this_idx = model_nodes_list.items.len - 1;
        
        // allocate space for nodes name if it exists
        if (node.name().len > 0) {
            model_nodes_list.items[this_idx].name = try std.fmt.allocPrint(alloc, "{s}", .{node.name()});
        }
        // link node meshes
        if (node.meshes().len > 0) {
            // for now we only support MAX_PRIMITIVES_PER_SET meshes. extend if necessary
            std.debug.assert(node.meshes().len < MAX_PRIMITIVES_PER_SET);

            model_nodes_list.items[this_idx].mesh = MeshSet{
                .primitives = [_]?usize{null} ** MAX_PRIMITIVES_PER_SET,
                .physics_shape_settings = undefined,
            };

            // link mesh ids into meshset
            for (node.meshes(), 0..) |mesh_idx, idx| {
                model_nodes_list.items[this_idx].mesh.?.primitives[idx] = mesh_idx;
            }
            // check if we have seen this series of primitives before
            if (physics_shape_map.contains(model_nodes_list.items[this_idx].mesh.?.primitives)) {
                // if so, grab already generated physics shape
                const shape_settings = physics_shape_map.get(model_nodes_list.items[this_idx].mesh.?.primitives).?;
                shape_settings.addRef();
                model_nodes_list.items[this_idx].mesh.?.physics_shape_settings = shape_settings;
            } else {
                // otherwise we need to generate a new shape to use
                try model_nodes_list.items[this_idx].mesh.?.generate_physics_shape(alloc, prims);
                // and store this shape in the hashmap
                try physics_shape_map.put(
                    model_nodes_list.items[this_idx].mesh.?.primitives, 
                    model_nodes_list.items[this_idx].mesh.?.physics_shape_settings
                );
            }
        }

        // create transform struct for this node
        const dec = node.transformation_decompose();
        model_nodes_list.items[this_idx].transform = tm.Transform {
            .position = dec.pos,
            .rotation = dec.rot,
            .scale = dec.sca,
        };

        // link node to its parent
        model_nodes_list.items[this_idx].parent = parent;

        // recursively generate and link the node's children
        if (node.children() != null) {
            const children_array = try alloc.alloc(usize, node.children().?.len);
            for (node.children().?, 0..) |child, idx| {
                children_array[idx] = try assimp_recursively_load_node(alloc, child, this_idx, prims, model_nodes_list, physics_shape_map);
            }
            model_nodes_list.items[this_idx].children = children_array;
        }

        return this_idx;
    }

    pub fn recursive_get_node_model_matrix(self: *const Self, node_idx: usize, resolved_transforms: []?zm.Mat) zm.Mat {
        if (resolved_transforms[node_idx] == null) {
            var parent_matrix = zm.identity();
            if (self.nodes_list[node_idx].parent) |parent_idx| {
                parent_matrix = self.recursive_get_node_model_matrix(parent_idx, resolved_transforms);
            }

            resolved_transforms[node_idx] = zm.mul(self.nodes_list[node_idx].transform.generate_model_matrix(), parent_matrix);
        }
        return resolved_transforms[node_idx].?;
    }

    pub fn cone(alloc: std.mem.Allocator, slices: i32, gfx: *d3d11.IDevice) !Model {
        var model_arena_allocator = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(model_arena_allocator);

        model_arena_allocator.* = std.heap.ArenaAllocator.init(alloc);
        errdefer model_arena_allocator.deinit();
        var model_arena = model_arena_allocator.allocator();

        // Generate cone shape
        var cone_shape = zmesh.Shape.initCone(slices, 6);
        defer cone_shape.deinit();

        // rotate to point upwards
        cone_shape.rotate(std.math.degreesToRadians(f32, -90.0), 1.0, 0.0, 0.0);

        // flat shaded
        cone_shape.unweld();
        
        cone_shape.computeNormals();

        const bone_ids = try alloc.alloc([4]i32, cone_shape.positions.len);
        defer alloc.free(bone_ids);
        @memset(bone_ids, [_]i32{an.AnimController3d.MAX_BONES - 1} ** 4);

        const bone_weights = try alloc.alloc([4]f32, cone_shape.positions.len);
        defer alloc.free(bone_weights);
        @memset(bone_weights, [4]f32{1.0, 0.0, 0.0, 0.0});

        // Construct gfx buffers
        const buffers = try Buffers.init_with_data(
            cone_shape.indices,
            cone_shape.positions,
            cone_shape.normals.?,
            ([_]([2]f32){})[0..0],
            ([_]([4]f32){})[0..0],
            bone_ids,
            bone_weights,
            gfx
        );
        errdefer buffers.deinit();

        // Generate a Model with 1 node and 1 mesh
        const mp = try model_arena.alloc(MeshPrimitive, 1);
        errdefer model_arena.free(mp);

        mp[0] = MeshPrimitive {
            .positions = cone_shape.positions,
            .topology = .Triangles,
            .indices_offset = 0,
            .pos_offset = 0,
            .nor_offset = 0,
            .num_indices = cone_shape.indices.len,
            .num_vertices = cone_shape.positions.len,
            .tangents_offset = 0,
            .tex_coord_offset = 0,
            .material_descriptor = MaterialDescriptor{},
        };

        const mn = try model_arena.alloc(ModelNode, 1);
        errdefer model_arena.free(mn);

        mn[0] = ModelNode {
            .mesh = MeshSet {
                .primitives = .{null} ** MAX_PRIMITIVES_PER_SET,
                .physics_shape_settings = @ptrCast(try zphy.CylinderShapeSettings.create(0.5, 0.5)),
            },
        };
        mn[0].mesh.?.primitives[0] = 0;

        const rn = try model_arena.alloc(usize, 1);
        errdefer model_arena.free(rn);

        rn[0] = 0;

        return Model {
            .buffers = buffers,
            .mesh_list = mp,
            .nodes_list = mn,
            .root_nodes = rn,
            .animations = ([_]BoneAnimation{})[0..0],
            .arena_allocator = model_arena_allocator,
        };
    }

    pub fn gen_static_compound_physics_shape(self: *const Model) !*zphy.CompoundShapeSettings {
        var shape_settings = try zphy.CompoundShapeSettings.createStatic();
        for (self.nodes_list) |*node| {
            if (node.mesh) |mid| {
                var scaled_shape_settings = try zphy.DecoratedShapeSettings.createScaled(
                    mid.physics_shape_settings,
                    .{node.transform.scale[0], node.transform.scale[1], node.transform.scale[2]}
                );
                defer scaled_shape_settings.release();

                shape_settings.addShape(
                    .{node.transform.position[0], node.transform.position[1], node.transform.position[2]},
                    .{node.transform.rotation[0], node.transform.rotation[1], node.transform.rotation[2], node.transform.rotation[3]},
                    scaled_shape_settings.asShapeSettings(),
                    0
                );
            }
        }
        return shape_settings;
    }

    fn recurse_resolve_bones_with_offsets(self: *const Model, node: *const ModelNode, parent_mat: zm.Mat, global_inverse: *const zm.Mat, bone_map: *std.AutoHashMap(i32, zm.Mat), bone_offsets: *[an.AnimController3d.MAX_BONES]zm.Mat) void {
        var global_mat = zm.mul(node.transform.generate_model_matrix(), parent_mat);

        if (node.bone_data) |bone_data| {
            if (bone_map.get(@intCast(bone_data.id))) |mat| {
                _ = mat;
                global_mat = zm.mul(zm.rotationX(0.3), global_mat);
            }
        }

        if (node.bone_data) |bone_data| {
            //const bone_transform_from_base = zm.mul(bone_data.offset, node_mat);
            bone_offsets[bone_data.id] = zm.mul(global_mat, bone_data.offset);// zm.mul(node.bone_offset.?, node.transform.generate_model_matrix());
        }

        for (node.children) |child_idx| {
            self.recurse_resolve_bones_with_offsets(&(self.nodes_list[child_idx]), global_mat, global_inverse, bone_map, bone_offsets);
        }
    }

    pub fn resolve_bones_with_offsets(self: *const Model, bone_map: *std.AutoHashMap(i32, zm.Mat), bone_offsets: *[an.AnimController3d.MAX_BONES]zm.Mat) void {
        const global_inverse_transform = zm.inverse(self.nodes_list[self.root_nodes[0]].transform.generate_model_matrix());
        self.recurse_resolve_bones_with_offsets(&(self.nodes_list[self.root_nodes[0]]), zm.identity(), &global_inverse_transform, bone_map, bone_offsets);
    }
};

fn appendMeshPrimitive(
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

const BoneIdMapElem = struct {
    id: usize,
    bone: assimp.Bone.Ptr,
};

