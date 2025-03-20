const std = @import("std");
const zmesh = @import("zmesh");
const zm = @import("zmath");
const zphy = @import("zphysics");
const zstbi = @import("zstbi");
const assert = std.debug.assert;
const gf = @import("../gfx/gfx.zig");
const Transform = @import("../engine/transform.zig");
const path = @import("../engine/path.zig");
const an = @import("animation.zig");
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

pub const MaterialTextureMap = struct {
    map: gf.TextureView2D,
    uv_index: u8,
    sampler: ?gf.Sampler = null,

    fn deinit(self: *MaterialTextureMap) void {
        self.map.deinit();
        if (self.sampler) |*s| s.deinit();
    }
};

pub const MaterialTemplate = struct {
    double_sided: bool = true,
    metallic_factor: f32 = 0.0,
    roughness_factor: f32 = 1.0,
    shininess: f32 = 0.0,
    emissiveness: f32 = 0.0,
    opacity: f32 = 1.0,
    unlit: bool = false,
    diffuse_map: ?MaterialTextureMap = null,
    normals_map: ?MaterialTextureMap = null,

    fn deinit(self: *MaterialTemplate) void {
        if (self.diffuse_map) |*m| m.deinit();
        if (self.normals_map) |*m| m.deinit();
    }
};

pub const MeshPrimitive = struct {
    num_indices: usize,
    num_vertices: usize,
    indices_offset: usize,
    pos_offset: usize,
    nor_offset: usize,
    tex_coord_offset: usize,
    tangents_offset: usize,
    bitangents_offset: usize,
    topology: PrimitiveTopology,
    material_template: ?usize,
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

    pub fn deinit(self: *const MeshSet) void {
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

pub const ModelNode = struct {
    name: ?[]u8 = null,
    transform: Transform = Transform {},
    mesh: ?MeshSet = null,
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
    indices: gf.Buffer,
    vertices: gf.Buffer,

    offsets: struct {
        positions: usize,
        normals: usize,
        bitangents: usize,
        texcoords: usize,
        tangents: usize,
        bone_ids: usize,
        bone_weights: usize,
    },
    strides: struct {
        positions: usize,
        normals: usize,
        bitangents: usize,
        texcoords: usize,
        tangents: usize,
        bone_ids: usize,
        bone_weights: usize,
    }, 

    pub fn deinit(self: *const Buffers) void {
        self.vertices.deinit();
        self.indices.deinit();
    }

    inline fn copy_data_to_buffer(
        comptime Datatype: type, 
        buffer: []u8, 
        offset: usize, 
        num_positions: usize, 
        data: ?[]const Datatype, 
        default_elem: Datatype
    ) void {
        const casted_buffer: *const align(1) [](Datatype) = @ptrCast(&buffer[offset..]);
        @memset(casted_buffer.*[0..num_positions], default_elem);
        if (data) |d| {
            assert(d.len == num_positions);
            @memcpy(casted_buffer.*[0..num_positions], d[0..]);
        }
    }

    fn init_with_data(
        alloc: std.mem.Allocator,
        mesh_indices: []const u32,
        mesh_positions: []const ([3]f32),
        mesh_normals: ?[]const ([3]f32),
        mesh_tex_coords: ?[]const ([2]f32),
        mesh_tangents: ?[]const ([3]f32),
        mesh_bitangents: ?[]const ([3]f32),
        mesh_bone_ids: ?[]const ([4]i32),
        mesh_weights: ?[]const ([4]f32),
        gfx: *gf.GfxState,
    ) !Buffers {
        const num_positions = mesh_positions.len;

        // Vertex buffer
        // Find offsets
        var vertices_buffer_length = mesh_positions.len * @sizeOf([3]f32);

        const normals_offset = vertices_buffer_length;
        vertices_buffer_length += mesh_positions.len * @sizeOf([3]f32);

        const tex_coords_offset = vertices_buffer_length;
        vertices_buffer_length += mesh_positions.len * @sizeOf([2]f32);

        const tangents_offset = vertices_buffer_length;
        vertices_buffer_length += mesh_positions.len * @sizeOf([4]f32);

        const bitangents_offset = vertices_buffer_length;
        vertices_buffer_length += mesh_positions.len * @sizeOf([4]f32);

        const bone_ids_offset = vertices_buffer_length;
        vertices_buffer_length += mesh_positions.len * @sizeOf([4]i32);

        const bone_weights_offset = vertices_buffer_length;
        vertices_buffer_length += mesh_positions.len * @sizeOf([4]f32);

        // create data buffer
        const vertices_data = try alloc.alloc(u8, vertices_buffer_length);
        defer alloc.free(vertices_data);

        // copy positions
        const positions_data: *const align(1) []([3]f32) = @ptrCast(&vertices_data[0..]);
        @memcpy(positions_data.*[0..num_positions], mesh_positions[0..]);

        // copy vertex attributes
        copy_data_to_buffer([3]f32, vertices_data, normals_offset, num_positions, mesh_normals, [3]f32{0.0, 0.0, 0.0});
        copy_data_to_buffer([2]f32, vertices_data, tex_coords_offset, num_positions, mesh_tex_coords, [2]f32{0.0, 0.0});
        copy_data_to_buffer([3]f32, vertices_data, tangents_offset, num_positions, mesh_tangents, [3]f32{0.0, 0.0, 0.0});
        copy_data_to_buffer([3]f32, vertices_data, bitangents_offset, num_positions, mesh_bitangents, [3]f32{0.0, 0.0, 0.0});
        copy_data_to_buffer([4]i32, vertices_data, bone_ids_offset, num_positions, mesh_bone_ids, [4]i32{0, 0, 0, 0});
        copy_data_to_buffer([4]f32, vertices_data, bone_weights_offset, num_positions, mesh_weights, [4]f32{0.0, 0.0, 0.0, 0.0});

        // create gfx buffer
        const vertices_buffer = try gf.Buffer.init_with_data(
            vertices_data,
            .{ .VertexBuffer = true, },
            .{},
            gfx
        );
        errdefer vertices_buffer.deinit();

        // Indicex buffer
        const indices_buffer = try gf.Buffer.init_with_data(
            std.mem.sliceAsBytes(mesh_indices[0..]),
            .{ .IndexBuffer = true, },
            .{},
            gfx
        );
        errdefer indices_buffer.deinit();

        return Buffers {
            .vertices = vertices_buffer,
            .indices = indices_buffer,
            .offsets = .{
                .positions = 0,
                .normals = normals_offset,
                .bitangents = bitangents_offset,
                .texcoords = tex_coords_offset,
                .tangents = tangents_offset,
                .bone_ids = bone_ids_offset,
                .bone_weights = bone_weights_offset,
            },
            .strides = .{
                .positions = @sizeOf([3]f32),
                .normals = @sizeOf([3]f32),
                .bitangents = @sizeOf([3]f32),
                .texcoords = @sizeOf([2]f32),
                .tangents = @sizeOf([3]f32),
                .bone_ids = @sizeOf([4]i32),
                .bone_weights = @sizeOf([4]f32),
            },
        };
    }
};

pub const MAX_BONES: usize = 256;
pub const Model = struct {
    const Self = @This();
    buffers: Buffers,
    mesh_list: []MeshPrimitive,
    nodes_list: []ModelNode,
    root_nodes: []usize,
    animations: []an.BoneAnimation,
    materials: []MaterialTemplate,
    textures: []gf.Texture2D,
    arena_allocator: *std.heap.ArenaAllocator,

    global_inverse_transform: zm.Mat,
    bone_mapping: std.StringHashMap(i32),
    bone_info: std.ArrayList(BoneInfo),

    bounding_box: BoundingBox,

    pub fn deinit(self: *Self) void {
        for (self.materials) |*mat| {
            mat.deinit();
        }
        for (self.textures) |tex| {
            tex.deinit();
        }
        for (self.nodes_list) |*node| {
            node.deinit();
        }

        self.bone_mapping.deinit();
        self.bone_info.deinit();

        self.arena_allocator.deinit();
        self.arena_allocator.child_allocator.destroy(self.arena_allocator);

        self.buffers.deinit();
    }

    fn create_gfx_texture_from_assimp_texture(tex: assimp.Texture.Ptr, format: gf.TextureFormat, gfx: *gf.GfxState) !gf.Texture2D {
        var data: []const u8 = undefined;
        if (tex.compressed_data()) |compressed_data| {
            data = compressed_data;
        } else {
            data = tex.data_u8_bgra().?;
        }

        var image = try zstbi.Image.loadFromMemory(data, 4);
        defer image.deinit();

        return try gf.Texture2D.init(
            .{
                .width = image.width,
                .height = image.height,
                .format = format,
                .mip_levels = 1,
                .array_length = 1,
            },
            .{ .ShaderResource = true, },
            .{},
            image.data,
            gfx
        );
    }

    pub fn init_from_file_assimp(alloc: std.mem.Allocator, file: path.Path, gfx: *gf.GfxState) !Self {
        const file_path = try file.resolve_path_c_str(alloc);
        defer alloc.free(file_path);

        var model_arena_allocator = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(model_arena_allocator);

        model_arena_allocator.* = std.heap.ArenaAllocator.init(alloc);
        errdefer model_arena_allocator.deinit();
        var model_arena = model_arena_allocator.allocator();

        var local_arena = std.heap.ArenaAllocator.init(alloc);
        defer local_arena.deinit();

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

        // textures
        const textures = try model_arena.alloc(gf.Texture2D, scene.textures().len);
        errdefer model_arena.free(textures);

        const texture_created = try local_arena.allocator().alloc(bool, scene.textures().len);
        @memset(texture_created[0..], false);
        defer local_arena.allocator().free(texture_created);

        var texture_names_map = std.StringHashMap(usize).init(local_arena.allocator());
        defer texture_names_map.deinit();

        for (scene.textures(), 0..) |tex, tex_idx| {
            try texture_names_map.put(tex.filename(), tex_idx);
        }

        // materials
        const materials = try model_arena.alloc(MaterialTemplate, scene.materials().len);
        errdefer model_arena.free(materials);
        
        {
            var material_property_map = std.StringHashMap(assimp.MaterialProperty.Ptr).init(local_arena.allocator());
            defer material_property_map.deinit();

            for (scene.materials(), 0..) |mat, mat_idx| {
                // fill property map
                material_property_map.clearRetainingCapacity();
                for (mat.properties()) |prop| {
                    material_property_map.put(prop.key(), prop) catch unreachable;
                }

                if (false) {
                    print_material_properties(mat, mat_idx, scene);
                }

                var material = MaterialTemplate {};

                if (material_property_map.get("$mat.twosided")) |prop| {
                    material.double_sided = prop.data_bytes()[0] != 0;
                }
                if (material_property_map.get("$mat.metallicFactor")) |prop| {
                    material.metallic_factor = prop.data_f32();
                }
                if (material_property_map.get("$mat.roughnessFactor")) |prop| {
                    material.roughness_factor = prop.data_f32();
                }
                if (material_property_map.get("$mat.shininess")) |prop| {
                    material.shininess = prop.data_f32();
                }
                if (material_property_map.get("$mat.emissive")) |prop| {
                    material.emissiveness = prop.data_f32();
                }
                if (material_property_map.get("$mat.opacity")) |prop| {
                    material.opacity = prop.data_f32();
                }
                if (material_property_map.get("$mat.gltf.unlit")) |prop| {
                    material.unlit = prop.data_bytes()[0] != 0;
                }

                if (mat.get_texture_properties(assimp.TextureType.Diffuse, 0)) |p| {
                    var tex_idx: ?usize = null;
                    if (assimp.index_from_embedded_texture_path(p.path())) |idx| {
                        tex_idx = idx;
                    } else {
                        tex_idx = texture_names_map.get(p.path()) orelse unreachable;
                    }
                    if (tex_idx) |idx| {
                        if (texture_created[idx] == false) {
                            textures[idx] = try create_gfx_texture_from_assimp_texture(scene.textures()[idx], .Rgba8_Unorm_Srgb, gfx);
                            texture_created[idx] = true;
                        }

                        material.diffuse_map = MaterialTextureMap {
                            .map = try gf.TextureView2D.init_from_texture2d(&textures[idx], gfx),
                            .uv_index = @truncate(p.uvindex),
                            .sampler = try gf.Sampler.init(
                                .{
                                    .filter_min_mag = .Linear,
                                },
                                gfx
                            ),
                        };
                    }
                }

                if (mat.get_texture_properties(assimp.TextureType.Normals, 0)) |p| {
                    var tex_idx: ?usize = null;
                    if (assimp.index_from_embedded_texture_path(p.path())) |idx| {
                        tex_idx = idx;
                    } else {
                        tex_idx = texture_names_map.get(p.path()) orelse unreachable;
                    }
                    if (tex_idx) |idx| {
                        if (texture_created[idx] == false) {
                            textures[idx] = try create_gfx_texture_from_assimp_texture(scene.textures()[idx], .Rgba8_Unorm, gfx);
                            texture_created[idx] = true;
                        }

                        material.normals_map = MaterialTextureMap {
                            .map = try gf.TextureView2D.init_from_texture2d(&textures[idx], gfx),
                            .uv_index = @truncate(p.uvindex),
                            .sampler = try gf.Sampler.init(
                                .{
                                    .filter_min_mag = .Linear,
                                },
                                gfx
                            ),
                        };
                    }
                }

                materials[mat_idx] = material;
            }
        }

        // Create a number of array lists to store attribute data of various types.
        // This will later be used to construct model-wide gfx buffers.
        var mesh_indices = std.ArrayList(u32).init(local_arena.allocator());
        var mesh_positions = std.ArrayList([3]f32).init(local_arena.allocator());
        var mesh_normals = std.ArrayList([3]f32).init(local_arena.allocator());
        var mesh_tex_coords = std.ArrayList([2]f32).init(local_arena.allocator());
        var mesh_tangents = std.ArrayList([3]f32).init(local_arena.allocator());
        var mesh_bitangents = std.ArrayList([3]f32).init(local_arena.allocator());

        // Create an array ready to store upcoming mesh primitives
        const mesh_primatives = try model_arena.alloc(MeshPrimitive, scene.meshes().len);
        errdefer model_arena.free(mesh_primatives);

        var mesh_bone_ids = std.ArrayList([4]i32).init(local_arena.allocator());
        var mesh_weights = std.ArrayList([4]f32).init(local_arena.allocator());

        var bone_mapping = std.StringHashMap(i32).init(model_arena);
        errdefer bone_mapping.deinit();

        var bone_info = std.ArrayList(BoneInfo).init(model_arena);
        errdefer bone_info.deinit();

        var num_bones: i32 = 0;

        // Assimp meshes are equivilent to MeshPrimitive,
        // Assimp nodes contain a list of meshes. These are equivilent to MeshSet.
        // Iterate through all assimp meshes and create MeshPrimitive for each, store These
        // in an array for use later.
        {
            for (scene.meshes(), 0..) |mesh, idx| {
                var prim = MeshPrimitive {
                    .num_indices = undefined,
                    .num_vertices = undefined,
                    .positions = undefined,
                    .indices_offset = mesh_indices.items.len,
                    .pos_offset = mesh_positions.items.len,
                    .nor_offset = mesh_normals.items.len,
                    .tex_coord_offset = mesh_tex_coords.items.len,
                    .tangents_offset = mesh_tangents.items.len,
                    .bitangents_offset = mesh_bitangents.items.len,
                    .material_template = @intCast(mesh.material_index()),
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
                // copy tangents
                if (mesh.tangents()) |tangents| {
                    try mesh_tangents.appendSlice(@as(*const [][3]f32, @ptrCast(&tangents)).*);
                }
                // copy bitangents
                if (mesh.bitangents()) |bitangents| {
                    try mesh_bitangents.appendSlice(@as(*const [][3]f32, @ptrCast(&bitangents)).*);
                }

                prim.num_vertices = mesh_positions.items.len - prim.pos_offset;
                prim.num_indices = mesh_indices.items.len - prim.indices_offset;

                prim.positions = try model_arena.alloc([3]f32, prim.num_vertices);
                @memcpy(prim.positions, mesh_positions.items[prim.pos_offset..]);

                mesh_primatives[idx] = prim;

                // Fill bones data
                try mesh_bone_ids.appendNTimes([_]i32{MAX_BONES - 1} ** 4, prim.num_vertices);
                try mesh_weights.appendNTimes([4]f32{0.0, 0.0, 0.0, 0.0}, prim.num_vertices);

                for (mesh.bones()) |bn| {
                    const bone_name = bn.name();

                    // Find bone id
                    var bone_id: i32 = undefined;
                    if (bone_mapping.get(bone_name)) |id| {
                        bone_id = id;
                    } else {
                        bone_id = num_bones;
                        num_bones += 1;

                        const bi = BoneInfo {
                            .bone_name = try model_arena.dupe(u8, bone_name),
                        };

                        try bone_mapping.put(bi.bone_name, bone_id);
                        try bone_info.append(bi);
                    }

                    bone_info.items[@intCast(bone_id)].bone_offset = bn.offset_matrix();

                    for (bn.weights()) |*wg| {
                        const vertId = prim.pos_offset + wg.mVertexId;
                        const weight = wg.mWeight;
                        std.debug.assert(weight >= 0.0);

                        var was_able_to_find_a_free_vertex_place = false;
                        for (mesh_bone_ids.items[vertId], 0..) |mesh_bone_id, i| {
                            std.debug.assert(mesh_bone_id != bone_id);

                            if (weight > mesh_weights.items[vertId][i]) {
                                for (i..(mesh_bone_ids.items[vertId].len-1)) |j| {
                                    mesh_bone_ids.items[vertId][j+1] = mesh_bone_ids.items[vertId][j];
                                    mesh_weights.items[vertId][j+1] = mesh_weights.items[vertId][j];
                                }
                                mesh_bone_ids.items[vertId][i] = bone_id;
                                mesh_weights.items[vertId][i] = weight;
                                was_able_to_find_a_free_vertex_place = true;
                                break;
                            }
                        }
                        if (!was_able_to_find_a_free_vertex_place) {
                            std.debug.print("wasn't able to find a free vertex place: {}\n", .{vertId});
                        }
                    }
                }
            }
        }

        // Normalise bone weights
        for (mesh_weights.items) |*w| {
            const sum = w[0] + w[1] + w[2] + w[3];
            if (sum != 0.0) {
                w[0] /= sum;
                w[1] /= sum;
                w[2] /= sum;
                w[3] /= sum;
            } else {
                w[0] = 1.0;
                w[1] = 0.0;
                w[2] = 0.0;
                w[3] = 0.0;
            }
        }

        // create gfx buffers from vertex data
        const buffers = try Buffers.init_with_data(
            alloc,
            mesh_indices.items,
            mesh_positions.items,
            mesh_normals.items,
            mesh_tex_coords.items,
            mesh_tangents.items,
            mesh_bitangents.items,
            mesh_bone_ids.items,
            mesh_weights.items,
            gfx
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
            }
        }

        // Load animations
        const animations = try model_arena.alloc(an.BoneAnimation, scene.animations().len);
        errdefer model_arena.free(animations);

        for (scene.animations(), 0..) |anim, anim_id| {
            animations[anim_id] = an.BoneAnimation {
                .name = try std.fmt.allocPrint(model_arena, "{s}", .{anim.name()}),
                .duration_ticks = anim.duration(),
                .ticks_per_second = anim.ticks_per_second(),
                .channels = try model_arena.alloc(an.BoneAnimationChannel, anim.channels().len),
                .current_tick = 0.0,
            };
            for (anim.channels(), 0..) |ch, ch_id| {
                const node_id = nodes_name_map.get(ch.node_name()).?;

                animations[anim_id].channels[ch_id] = an.BoneAnimationChannel {
                    .node_name = model_nodes[node_id].name.?,
                    .position_keys = try model_arena.alloc(an.AnimationKey, ch.position_keys().len),
                    .rotation_keys = try model_arena.alloc(an.AnimationKey, ch.rotation_keys().len),
                    .scale_keys = try model_arena.alloc(an.AnimationKey, ch.scale_keys().len),
                };

                for (ch.position_keys(), 0..) |pk, pk_id| {
                    animations[anim_id].channels[ch_id].position_keys[pk_id] = an.AnimationKey {
                        .time = pk.time(),
                        .value = pk.value(),
                    };
                }

                for (ch.rotation_keys(), 0..) |rk, rk_id| {
                    animations[anim_id].channels[ch_id].rotation_keys[rk_id] = an.AnimationKey {
                        .time = rk.time(),
                        .value = rk.value(),
                    };
                }

                for (ch.scale_keys(), 0..) |sk, sk_id| {
                    animations[anim_id].channels[ch_id].scale_keys[sk_id] = an.AnimationKey {
                        .time = sk.time(),
                        .value = sk.value(),
                    };
                }
            }
        }

        var bounding_box = BoundingBox{
            .min = zm.f32x4s(0.0),
            .max = zm.f32x4s(0.0),
        };
        for (scene.meshes(), 0..) |mesh, idx| {
            const bb = mesh.bounding_box();
            const zmbbmin = zm.f32x4(bb.mMin.x, bb.mMin.y, bb.mMin.z, 0.0);
            const zmbbmax = zm.f32x4(bb.mMax.x, bb.mMax.y, bb.mMax.z, 0.0);
            if (idx == 0) {
                bounding_box.min = zmbbmin;
                bounding_box.max = zmbbmax;
            } else {
                bounding_box.min = zm.min(bounding_box.min, zmbbmin);
                bounding_box.max = zm.max(bounding_box.max, zmbbmax);
            }
        }

        return Self {
            .buffers = buffers,
            .mesh_list = mesh_primatives,
            .nodes_list = model_nodes,
            .root_nodes = root_node,
            .animations = animations,
            .textures = textures,
            .materials = materials,
            .arena_allocator = model_arena_allocator,

            .global_inverse_transform = zm.inverse(scene.root_node().?.transformation()),
            .bone_mapping = bone_mapping,
            .bone_info = bone_info,

            .bounding_box = bounding_box,
        };
    }

    fn print_material_properties(mat: assimp.Material.Ptr, mat_idx: usize, scene: assimp.Scene.Ptr) void {
        for (mat.properties()) |prop| {
            std.log.info("mat {d} - prop [{s}] is {}", .{mat_idx, prop.key(), prop.property_type()});
            switch (prop.property_type()) {
                .Float => std.log.info("\t= {d}", .{prop.data_f32()}),
                .Double => std.log.info("\t= {d}", .{prop.data_f64()}),
                .String => std.log.info("\t= \"{s}\"", .{prop.data_bytes()}),
                .Integer => std.log.info("\t= {}", .{prop.data_i32()}),
                .Buffer => std.log.info("\t= [data, len={}, {any}]", .{prop.data_bytes().len, prop.data_bytes()}),
            }
        }
        std.log.info("material diffuse count is {d}", .{
            mat.get_texture_count(assimp.TextureType.Diffuse)
        });
        const props = mat.get_texture_properties(assimp.TextureType.Diffuse, 0);
        if (props) |p| {
            std.log.info("material diffuse path is {s}", .{p.path()});
            std.log.info("material diffuse props are {}", .{props.?});
            if (assimp.index_from_embedded_texture_path(p.path())) |tex_index| {
                const texture = scene.textures()[tex_index];
                std.log.info("is texture compressed: {}", .{texture.is_compressed_data()});
                std.log.info("texture width and height: {}, {}", .{texture.width(), texture.height()});

                var image = zstbi.Image.loadFromMemory(texture.compressed_data().?, 4) catch unreachable;
                defer image.deinit();

                std.log.info("texture width and height: {}, {}", .{image.width, image.height});
            } else {
                std.log.info("texture is not embedded...", .{});
            }
        }
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
            model_nodes_list.items[this_idx].name = try alloc.alloc(u8, node.name().len);
            @memcpy(model_nodes_list.items[this_idx].name.?[0..], node.name()[0..]);
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
        model_nodes_list.items[this_idx].transform = Transform {
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

    // generated by claude so if there are issues thats probably why
    fn generate_tangents_and_binormals(
        positions: []const [3]f32,
        uvs: []const [2]f32,
        normals: []const [3]f32,
        indices: []const u32,
        tangents: [][3]f32,
        binormals: [][3]f32,
    ) !void {
        // Ensure we have the same number of vertices, UVs, and normals
        if (positions.len != uvs.len or positions.len != normals.len) {
            return error.InvalidInputSize;
        }

        // Ensure we have enough space in output arrays
        if (tangents.len < positions.len or binormals.len < positions.len) {
            return error.OutputBufferTooSmall;
        }

        // Ensure the index buffer has a valid length (must be a multiple of 3 for triangles)
        if (indices.len % 3 != 0) {
            return error.InvalidIndexCount;
        }

        // Initialize all tangents and binormals to zero
        for (tangents) |*tangent| {
            tangent.* = .{ 0, 0, 0 };
        }

        for (binormals) |*binormal| {
            binormal.* = .{ 0, 0, 0 };
        }

        // Process each triangle (3 indices at a time)
        var i: usize = 0;
        while (i + 2 < indices.len) : (i += 3) {
            // Get the indices for this triangle
            const idx0 = indices[i];
            const idx1 = indices[i + 1];
            const idx2 = indices[i + 2];

            // Validate indices are within bounds
            if (idx0 >= positions.len or idx1 >= positions.len or idx2 >= positions.len) {
                return error.IndexOutOfBounds;
            }

            // Get the vertices of the triangle
            const p0 = positions[idx0];
            const p1 = positions[idx1];
            const p2 = positions[idx2];

            // Get the UVs of the triangle
            const uv0 = uvs[idx0];
            const uv1 = uvs[idx1];
            const uv2 = uvs[idx2];

            // Calculate edges of the triangle
            const edge1 = [3]f32{
                p1[0] - p0[0],
                p1[1] - p0[1],
                p1[2] - p0[2],
            };

            const edge2 = [3]f32{
                p2[0] - p0[0],
                p2[1] - p0[1],
                p2[2] - p0[2],
            };

            // Calculate UV differences
            const deltaUV1 = [2]f32{
                uv1[0] - uv0[0],
                uv1[1] - uv0[1],
            };

            const deltaUV2 = [2]f32{
                uv2[0] - uv0[0],
                uv2[1] - uv0[1],
            };

            // Calculate the denominator of the tangent/binormal calculation
            const r = 1.0 / (deltaUV1[0] * deltaUV2[1] - deltaUV1[1] * deltaUV2[0]);

            // Check for degenerate UV coordinates
            if (!std.math.isFinite(r)) {
                // Skip this triangle if UV coordinates are degenerate
                continue;
            }

            // Calculate tangent
            const tangent = [3]f32{
                (edge1[0] * deltaUV2[1] - edge2[0] * deltaUV1[1]) * r,
                (edge1[1] * deltaUV2[1] - edge2[1] * deltaUV1[1]) * r,
                (edge1[2] * deltaUV2[1] - edge2[2] * deltaUV1[1]) * r,
            };

            // Calculate binormal
            const binormal = [3]f32{
                (edge2[0] * deltaUV1[0] - edge1[0] * deltaUV2[0]) * r,
                (edge2[1] * deltaUV1[0] - edge1[1] * deltaUV2[0]) * r,
                (edge2[2] * deltaUV1[0] - edge1[2] * deltaUV2[0]) * r,
            };

            // Add the tangent and binormal to all vertices of this triangle
            for (&[_]u32{ idx0, idx1, idx2 }) |vertex_index| {
                // Add to tangent
                tangents[vertex_index][0] += tangent[0];
                tangents[vertex_index][1] += tangent[1];
                tangents[vertex_index][2] += tangent[2];

                // Add to binormal
                binormals[vertex_index][0] += binormal[0];
                binormals[vertex_index][1] += binormal[1];
                binormals[vertex_index][2] += binormal[2];
            }
        }

        // Normalize and orthogonalize tangents and binormals
        for (0..positions.len) |j| {
            const normal = normals[j];
            var tangent = tangents[j];
            var binormal = binormals[j];

            // Normalize tangent
            const tangent_length = std.math.sqrt(
                tangent[0] * tangent[0] + 
                tangent[1] * tangent[1] + 
                tangent[2] * tangent[2]
            );

            if (tangent_length > 0.0001) {
                tangent[0] /= tangent_length;
                tangent[1] /= tangent_length;
                tangent[2] /= tangent_length;
            } else {
                // Set to arbitrary tangent if unable to compute
                tangent = if (@abs(normal[0]) < 0.9) 
                    [3]f32{ 1, 0, 0 } 
                else 
                    [3]f32{ 0, 1, 0 };
            }

            // Make tangent orthogonal to normal
            // Gram-Schmidt process
            const dot = (
                tangent[0] * normal[0] + 
                tangent[1] * normal[1] + 
                tangent[2] * normal[2]
            );

            tangent[0] -= normal[0] * dot;
            tangent[1] -= normal[1] * dot;
            tangent[2] -= normal[2] * dot;

            // Normalize orthogonalized tangent
            const ortho_length = std.math.sqrt(
                tangent[0] * tangent[0] + 
                tangent[1] * tangent[1] + 
                tangent[2] * tangent[2]
            );

            if (ortho_length > 0.0001) {
                tangent[0] /= ortho_length;
                tangent[1] /= ortho_length;
                tangent[2] /= ortho_length;
            }

            // Compute binormal as cross product of normal and tangent
            binormal[0] = normal[1] * tangent[2] - normal[2] * tangent[1];
            binormal[1] = normal[2] * tangent[0] - normal[0] * tangent[2];
            binormal[2] = normal[0] * tangent[1] - normal[1] * tangent[0];

            // Store results
            tangents[j] = tangent;
            binormals[j] = binormal;
        }
    }

    pub fn init_from_shape(alloc: std.mem.Allocator, shape: *zmesh.Shape, gfx: *gf.GfxState) !Model {
        var model_arena_allocator = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(model_arena_allocator);

        model_arena_allocator.* = std.heap.ArenaAllocator.init(alloc);
        errdefer model_arena_allocator.deinit();
        var model_arena = model_arena_allocator.allocator();

        shape.computeNormals();

        const bitangents = try alloc.alloc([3]f32, shape.positions.len);
        defer alloc.free(bitangents);
        @memset(bitangents, [3]f32{0.0, 0.0, 0.0});

        const tangents = try alloc.alloc([3]f32, shape.positions.len);
        defer alloc.free(tangents);
        @memset(tangents, [3]f32{0.0, 0.0, 0.0});

        // Compute tangents and bitangents
        if (shape.normals) |normals| {
            if (shape.texcoords) |texcoords| {
                generate_tangents_and_binormals(
                    shape.positions,
                    texcoords,
                    normals,
                    shape.indices,
                    tangents,
                    bitangents,
                ) catch |err| {
                    std.log.err("Failed to generate tangents and binormals for shape: {}", .{err});
                };
            }
            // @TODO: make this more robust, currently only works for planes
            // var zmn = zm.f32x4s(0.0);
            // var zmt = zm.f32x4s(0.0);
            // var zmb = zm.f32x4s(0.0);
            // for (normals, 0..) |*n, i| {
            //     zmn = zm.loadArr3(n.*);
            //     if (zm.dot3(zmn, zm.f32x4(0.0, 0.0, 1.0, 0.0))[0] < 0.9999) {
            //         zmb = zm.cross3(zmn, zm.f32x4(0.0, 0.0, 1.0, 0.0));
            //     } else {
            //         zmb = zm.cross3(zmn, zm.f32x4(0.0, 1.0, 0.0, 0.0));
            //     }
            //     zmt = zm.cross3(zmb, zmn);
            //     zmb = zm.cross3(zmt, zmn);
            //
            //     zm.storeArr3(&tangents[i], zmb);
            //     zm.storeArr3(&bitangents[i], zmt);
            // }
        }

        const bone_ids = try alloc.alloc([4]i32, shape.positions.len);
        defer alloc.free(bone_ids);
        // set all bone ids to default to pointing at the last valid bone
        @memset(bone_ids, [_]i32{MAX_BONES - 1} ** 4);

        const bone_weights = try alloc.alloc([4]f32, shape.positions.len);
        defer alloc.free(bone_weights);
        @memset(bone_weights, [4]f32{1.0, 0.0, 0.0, 0.0});

        // Construct gfx buffers
        const buffers = try Buffers.init_with_data(
            alloc,
            shape.indices,
            shape.positions,
            shape.normals,
            shape.texcoords,
            tangents,
            bitangents,
            bone_ids,
            bone_weights,
            gfx
        );
        errdefer buffers.deinit();

        // Generate a Model with 1 node and 1 mesh
        const mp = try model_arena.alloc(MeshPrimitive, 1);
        errdefer model_arena.free(mp);

        mp[0] = MeshPrimitive {
            .positions = shape.positions,
            .topology = .Triangles,
            .indices_offset = 0,
            .pos_offset = 0,
            .nor_offset = 0,
            .num_indices = shape.indices.len,
            .num_vertices = shape.positions.len,
            .tangents_offset = 0,
            .bitangents_offset = 0,
            .tex_coord_offset = 0,
            .material_template = null,
        };

        const mn = try model_arena.alloc(ModelNode, 1);
        errdefer model_arena.free(mn);

        mn[0] = ModelNode {
            .mesh = MeshSet {
                .primitives = .{null} ** MAX_PRIMITIVES_PER_SET,
                .physics_shape_settings = @ptrCast(try zphy.ConvexHullShapeSettings.create(@ptrCast(shape.positions.ptr), @intCast(shape.positions.len), @sizeOf([3]f32))),
            },
        };
        mn[0].mesh.?.primitives[0] = 0;

        const rn = try model_arena.alloc(usize, 1);
        errdefer model_arena.free(rn);

        rn[0] = 0;

        var bounding_box = BoundingBox{
            .min = zm.loadArr3(shape.positions[0]),
            .max = zm.loadArr3(shape.positions[0]),
        };
        for (shape.positions) |pos| {
            const zmpos = zm.loadArr3(pos);
            bounding_box.min = zm.min(bounding_box.min, zmpos);
            bounding_box.max = zm.max(bounding_box.max, zmpos);
        }

        return Model {
            .buffers = buffers,
            .mesh_list = mp,
            .nodes_list = mn,
            .root_nodes = rn,
            .animations = &.{},
            .textures = &.{},
            .materials = &.{},
            .arena_allocator = model_arena_allocator,

            .global_inverse_transform = zm.identity(),
            .bone_mapping = std.StringHashMap(i32).init(model_arena),
            .bone_info = std.ArrayList(BoneInfo).init(model_arena),

            .bounding_box = bounding_box,
        };
    }

    pub fn cone(alloc: std.mem.Allocator, slices: i32, gfx: *gf.GfxState) !Model {
        // Generate cone shape
        var cone_shape = zmesh.Shape.initCone(slices, 6);
        defer cone_shape.deinit();

        // rotate to point upwards
        cone_shape.rotate(std.math.degreesToRadians(-90.0), 1.0, 0.0, 0.0);

        // flat shaded
        cone_shape.unweld();

        return try init_from_shape(alloc, &cone_shape, gfx);
    }

    pub fn plane(alloc: std.mem.Allocator, slices: i32, stacks: i32, gfx: *gf.GfxState) !Model {
        // Generate cone shape
        var shape = zmesh.Shape.initPlane(slices, stacks);
        defer shape.deinit();

        // rotate to point upwards
        shape.translate(-0.5, -0.5, 0.0);
        shape.rotate(std.math.degreesToRadians(-90.0), 1.0, 0.0, 0.0);

        return try init_from_shape(alloc, &shape, gfx);
    }

    pub fn plane_on_sphere(alloc: std.mem.Allocator, slices: i32, stacks: i32, plane_extent_radians: f32, gfx: *gf.GfxState) !Model {
        // Generate plane shape
        var shape = zmesh.Shape.initPlane(slices, stacks);
        defer shape.deinit();

        shape.translate(-0.5, -0.5, 0.0);

        for (shape.positions) |*pos| {
            const dx = -(std.math.pi / 2.0) - ((plane_extent_radians * pos[0]) / 2.0);
            const dy = -(std.math.pi / 2.0) - ((plane_extent_radians * pos[1]) / 2.0);
            var r = zm.rotationX(dy);
            r = zm.mul(r, zm.rotationZ(dx));
            const rpos = zm.rotate(zm.quatFromMat(r), zm.loadArr3(pos.*));
            zm.storeArr3(pos, rpos);
        }

        // rotate to point upwards
        shape.rotate(std.math.degreesToRadians(-90.0), 0.0, 1.0, 0.0);
        shape.rotate(std.math.degreesToRadians(-90.0), 1.0, 0.0, 0.0);

        return try init_from_shape(alloc, &shape, gfx);
    }

    pub const Heightmap = struct {
        data: []f32,
        width: usize,
        height: usize,

        pub fn get_heightmap_pixel(height_map: *const Heightmap, x: f32, y: f32) f32 {
            var w = @as(usize, @intFromFloat(std.math.floor(x)));
            var h = @as(usize, @intFromFloat(std.math.floor(y)));

            // sample mirror w and h if they are out of bounds
            w = @mod(w, height_map.width); 
            if (w >= height_map.width) { 
                w = height_map.width - (w - height_map.width);
            }
            h = @mod(h, height_map.height); 
            if (h >= height_map.height) { 
                h = height_map.height - (h - height_map.height);
            }

            return height_map.data[w + h * height_map.width];
        }


        pub fn sample_heightmap(height_map: *const Heightmap, x: f32, y: f32) f32 {
            const px = x * @as(f32, @floatFromInt(height_map.width));
            const py = y * @as(f32, @floatFromInt(height_map.height));

            // -------
            // |h0|h1|
            // -------
            // |h2|h3|
            // -------
            const h0 = get_heightmap_pixel(height_map, std.math.floor(px), std.math.floor(py));
            const h1 = get_heightmap_pixel(height_map, std.math.ceil(px), std.math.floor(py));
            const h2 = get_heightmap_pixel(height_map, std.math.floor(px), std.math.ceil(py));
            const h3 = get_heightmap_pixel(height_map, std.math.ceil(px), std.math.ceil(py));

            const x_frac = @mod(x, 1.0);
            const y_frac = @mod(y, 1.0);
            return 
                (h0 * (1.0 - x_frac) * (1.0 - y_frac)) +
                (h1 * x_frac * (1.0 - y_frac)) +
                (h2 * (1.0 - x_frac) * y_frac) +
                (h3 * x_frac * y_frac);
        }
    };

    pub fn heightmap_plane_on_sphere(
        alloc: std.mem.Allocator, 
        height_map: *const Heightmap, 
        options: struct {
            slices: i32 = 32,
            stacks: i32 = 32,
            plane_extent_radians: f32 = 0.0,
            heightmap_scale: f32 = 1.0,
        },
        gfx: *gf.GfxState
    ) !Model {
        // generate plane shape
        var shape = zmesh.Shape.initPlane(options.slices, options.stacks);
        defer shape.deinit();

        shape.translate(-0.5, -0.5, 0.0);

        for (shape.positions) |*pos| {
            const h = height_map.sample_heightmap(pos[0] + 0.5, 1.0 - (pos[1] + 0.5));
            pos[2] = h * options.heightmap_scale;

            const dx = -(std.math.pi / 2.0) - ((options.plane_extent_radians * pos[0]) / 2.0);
            const dy = -(std.math.pi / 2.0) - ((options.plane_extent_radians * pos[1]) / 2.0);
            var r = zm.rotationX(dy);
            r = zm.mul(r, zm.rotationZ(dx));
            const rpos = zm.rotate(zm.quatFromMat(r), zm.loadArr3(pos.*));
            zm.storeArr3(pos, rpos);
        }

        // rotate to point upwards
        shape.rotate(std.math.degreesToRadians(-90.0), 0.0, 1.0, 0.0);
        shape.rotate(std.math.degreesToRadians(-90.0), 1.0, 0.0, 0.0);

        return try init_from_shape(alloc, &shape, gfx);
    }

    pub fn sphere(alloc: std.mem.Allocator, slices: i32, stacks: i32, gfx: *gf.GfxState) !Model {
        // Generate sphere shape
        var shape = zmesh.Shape.initParametricSphere(slices, stacks);
        defer shape.deinit();

        // flat shaded
        //shape.unweld();

        return try init_from_shape(alloc, &shape, gfx);
    }

    pub const AnimationEntry = struct {
        animation: *an.BoneAnimation,
        strength: f32,
    };

    pub fn blend_animation_bone_transforms(self: *const Self, animation: *const an.BoneAnimation, strength: f32, io_bone_transforms: []Transform) void {
        for (self.bone_info.items) |*bone_info| {
            if (animation.find_node_anim(bone_info.bone_name)) |anim_channel| {
                if (self.bone_mapping.get(bone_info.bone_name)) |bone_id| {
                    io_bone_transforms[@intCast(bone_id)] = io_bone_transforms[@intCast(bone_id)].lerp(&anim_channel.selected_transform, strength);
                }
            }
        }
    }

    pub fn generate_bone_transforms_for_pose(self: *const Self, in_bone_pose_transforms: []const Transform, out_bone_matrix_transforms: []zm.Mat) void {
        std.debug.assert(in_bone_pose_transforms.len >= MAX_BONES);
        std.debug.assert(out_bone_matrix_transforms.len >= MAX_BONES);

        self.recurse_generate_bone_transforms_for_pose(
            in_bone_pose_transforms,
            out_bone_matrix_transforms,
            &self.nodes_list[self.root_nodes[0]],
            zm.identity()
        );
    }

    fn recurse_generate_bone_transforms_for_pose(
        self: *const Self, 
        in_bone_pose_transforms: []const Transform, 
        out_bone_matrix_transforms: []zm.Mat, 
        node: *const ModelNode, 
        parent_mat: zm.Mat
    ) void {
        if (node.name == null) { std.log.warn("node name was null in animation", .{}); return; }

        const node_name = node.name.?;
        const maybe_bone_id = self.bone_mapping.get(node_name);

        var anims_transform = node.transform;
        if (maybe_bone_id) |bone_id| {
            anims_transform = in_bone_pose_transforms[@intCast(bone_id)];
        }

        const node_transform = anims_transform.generate_model_matrix();
        const global_transform = zm.mul(node_transform, parent_mat);

        if (maybe_bone_id) |bone_id| {
            const bone_info = &self.bone_info.items[@intCast(bone_id)];
            const final_transform = zm.mul(bone_info.bone_offset, zm.mul(global_transform, self.global_inverse_transform));
            out_bone_matrix_transforms[@intCast(bone_id)] = final_transform;
        }

        for (node.children) |child_idx| {
            self.recurse_generate_bone_transforms_for_pose(
                in_bone_pose_transforms,
                out_bone_matrix_transforms,
                &self.nodes_list[child_idx],
                global_transform
            );
        }
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
                    zm.vecToArr3(node.transform.position),
                    zm.vecToArr4(node.transform.rotation),
                    scaled_shape_settings.asShapeSettings(),
                    0
                );
            }
        }
        return shape_settings;
    }

    fn recurse_resolve_bones_with_offsets(self: *const Model, node: *const ModelNode, parent_mat_pose: zm.Mat, bone_map: *std.AutoHashMap(i32, zm.Mat), bone_offsets: *[MAX_BONES]zm.Mat) void {
        var pose_global_mat = zm.mul(node.transform.generate_model_matrix(), parent_mat_pose);

        if (node.bone_data) |bone_data| {
            if (bone_map.get(@intCast(bone_data.id))) |mat| {
                pose_global_mat = zm.mul(mat, parent_mat_pose);
            }
            bone_offsets[bone_data.id] = zm.mul(pose_global_mat, zm.mul(bone_data.bone_offset, self.global_inverse_transform));
        }

        for (node.children) |child_idx| {
            self.recurse_resolve_bones_with_offsets(&(self.nodes_list[child_idx]), pose_global_mat, bone_map, bone_offsets);
        }
    }

    fn resolve_bones_with_offsets(self: *const Model, bone_map: *std.AutoHashMap(i32, zm.Mat), bone_offsets: *[MAX_BONES]zm.Mat) void {
        self.recurse_resolve_bones_with_offsets(&(self.nodes_list[self.root_nodes[0]]), zm.identity(), bone_map, bone_offsets);
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

const BoneInfo = struct {
    bone_name: []u8,
    bone_offset: zm.Mat = zm.identity(),
};

