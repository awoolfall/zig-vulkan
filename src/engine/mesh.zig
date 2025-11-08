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

pub const PrimitiveTopology = enum {
    Points,
    Lines,
    LineLoop,
    LineStrip,
    Triangles,
    TriangleStrip,
    TriangleFan,
};

pub const MaterialTextureMap = struct {
    map: gf.ImageView.Ref,
    uv_index: u8,
    sampler: ?gf.Sampler.Ref = null,

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
    pub const STRIDE =  @sizeOf([3]f32)     // positions
                    +   @sizeOf([3]f32)     // normals
                    +   @sizeOf([3]f32)     // tangents
                    +   @sizeOf([3]f32)     // bitangents
                    +   @sizeOf([2]f32)     // tex_coords
                    +   @sizeOf([4]i32)     // bone_ids
                    +   @sizeOf([4]f32);    // bone_weights

    index_count: usize,
    vertex_count: usize,

    indices_offset: usize,
    vertices_offset: usize,

    topology: PrimitiveTopology,
    material_template: ?usize,

    bounding_box: BoundingBox,

    // Check whether the mesh primitive has indices
    pub inline fn has_indices(self: *const MeshPrimitive) bool {
        return self.index_count != 0;
    }
};

pub const BoundingBox = struct {
    min: zm.F32x4,
    max: zm.F32x4,

    pub fn center(self: *const BoundingBox) zm.F32x4 {
        return (self.max + self.min) / zm.f32x4s(2.0);
    }
};

pub const MeshSet = struct {
    pub const MAX_PRIMITIVES_PER_SET = 4;

    primitives: [MAX_PRIMITIVES_PER_SET]usize,
    num_primitives: usize,

    physics_shape_settings: ?*zphy.ShapeSettings = null,

    pub fn deinit(self: *const MeshSet) void {
        if (self.physics_shape_settings) |shape_settings| {
            shape_settings.release();
        }
    }

    pub inline fn primitives_slice(self: *const MeshSet) []const usize {
        return self.primitives[0..self.num_primitives];
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
    mesh_set: ?MeshSet = null,
    parent: ?usize = null,

    pub fn deinit(self: *ModelNode) void {
        if (self.mesh_set) |*mesh| {
            mesh.deinit();
        }
        self.mesh_set = null;
    }
};

const VertexData = extern struct {
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    normal: [3]f32 = .{ 0.0, 0.0, 1.0 },
    tangent: [3]f32 = .{ 1.0, 0.0, 0.0 },
    bitangent: [3]f32 = .{ 0.0, 1.0, 0.0 },
    tex_coord: [2]f32 = .{ 0.0, 0.0 },
    bone_ids: [4]i32 = .{ 0, 0, 0, 0 },
    bone_weights: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
};

const BoneInsertionNode = struct {
    idx: i32 = 0,
    weight: f32 = 0.0,
};

fn bone_insertion_sort(buffer: []BoneInsertionNode, new_node: BoneInsertionNode) void {
    for (buffer[0..], 0..) |node, idx| {
        if (node.weight < new_node.weight) {
            if (idx < (buffer.len - 1)) {
                @memmove(buffer[(idx + 1)..], buffer[idx..(buffer.len - 1)]);
            }
            buffer[idx] = new_node;
            break;
        }
    }
}

fn vertex_has_a_bone(bone_buffer: []BoneInsertionNode) bool {
    for (bone_buffer) |b| {
        if (b.weight != 0.0) {
            return true;
        }
    }
    return false;
}

pub const MAX_BONES = 256;

const BoneInfo = struct {
    bone_name: []u8,
    bone_offset_matrix: zm.Mat = zm.identity(),
};

pub const Model = struct {
    const Self = @This();

    arena_allocator: std.heap.ArenaAllocator,

    vertices_buffer: gf.Buffer.Ref,
    indices_buffer: gf.Buffer.Ref,

    nodes: []ModelNode,

    meshes: []MeshPrimitive,
    animations: []an.BoneAnimation,
    materials: []MaterialTemplate,
    textures: []gf.Image.Ref,

    global_inverse_transform: zm.Mat,
    bones_names_map: std.StringHashMap(i32),
    bones_info: []BoneInfo,

    bounding_box: BoundingBox,

    pub fn deinit(self: *Self) void {
        for (self.materials) |*mat| {
            mat.deinit();
        }
        for (self.textures) |tex| {
            tex.deinit();
        }
        for (self.nodes) |*node| {
            node.deinit();
        }

        self.bones_names_map.deinit();
        self.arena_allocator.allocator().free(self.bones_info);

        self.vertices_buffer.deinit();
        self.indices_buffer.deinit();

        self.arena_allocator.deinit();
    }

    fn create_gfx_texture_from_assimp_texture(tex: assimp.Texture.Ptr, format: gf.ImageFormat) !gf.Image.Ref {
        const data = if (tex.compressed_data()) |compressed_data| compressed_data
                     else tex.data_u8_bgra().?;

        var image = try zstbi.Image.loadFromMemory(data, 4);
        defer image.deinit();

        return try gf.Image.init(
            .{
                .width = image.width,
                .height = image.height,
                .format = format,
                .mip_levels = 1,
                .array_length = 1,

                .usage_flags = .{ .ShaderResource = true, },
                .access_flags = .{},
                .dst_layout = .ShaderReadOnlyOptimal,
            },
            image.data,
        );
    }

    fn assimp_write_mesh_vertex_data(
        model_alloc: std.mem.Allocator,
        writer: *std.io.Writer, 
        assimp_mesh: assimp.Mesh.Ptr,
        bones_data: struct {
            alloc: std.mem.Allocator,
            names_map: *std.StringHashMap(i32),
            infos: *std.ArrayList(BoneInfo),
        },
    ) !void {
        if (assimp_mesh.vertices() == null) {
            return error.MeshHasNoVertices;
        }

        var highest_number_of_bones_used_for_vertex: usize = 0;

        for (assimp_mesh.vertices().?, 0..) |av, idx| {
            var bones_found_for_vertex: usize = 0;
            var affecting_bones_buffer: [4]BoneInsertionNode = [_]BoneInsertionNode{ .{ .idx = 0, .weight = 0.0, } } ** 4;

            for (assimp_mesh.bones()) |b| {
                const bone_idx = bones_data.names_map.get(b.name()) orelse blk: {
                    const bone_idx: i32 = @intCast(bones_data.infos.items.len);
                    const bone_info = BoneInfo {
                        .bone_name = model_alloc.dupe(u8, b.name()) catch unreachable,
                        .bone_offset_matrix = b.offset_matrix(),
                    };

                    bones_data.names_map.put(bone_info.bone_name, bone_idx) catch |err| {
                        std.log.err("Unable to insert bone name in names map: {}", .{err});
                        unreachable;
                    };
                    bones_data.infos.append(bones_data.alloc, bone_info) catch |err| {
                        std.log.err("Unable to append bone info: {}", .{err});
                        unreachable;
                    };
                    break :blk bone_idx;
                };

                for (b.weights()) |bw| {
                    if (bw.mVertexId == idx and bw.mWeight != 0.0) {
                        bone_insertion_sort(affecting_bones_buffer[0..], BoneInsertionNode {
                            .idx = bone_idx,
                            .weight = bw.mWeight,
                        });
                        bones_found_for_vertex += 1;
                    }
                }
            }

            const afb = if (vertex_has_a_bone(&affecting_bones_buffer)) affecting_bones_buffer else null;

            const vertex_data = .{
                .position = [3]f32 { av.x, av.y, av.z },
                .normal =   if (assimp_mesh.normals()) |n| [3]f32 { n[idx].x, n[idx].y, n[idx].z }
                            else [3]f32 { 0.0, 0.0, 1.0 },
                .tangent =  if (assimp_mesh.tangents()) |t| [3]f32 { t[idx].x, t[idx].y, t[idx].z }
                            else [3]f32 { 0.0, 1.0, 0.0 },
                .bitangent =    if (assimp_mesh.bitangents()) |b| [3]f32 { b[idx].x, b[idx].y, b[idx].z }
                                else [3]f32 { 1.0, 0.0, 0.0 },
                .tex_coord =    if (assimp_mesh.texcoords(0)) |t| [2]f32 { t[idx].x, t[idx].y }
                                else [2]f32 { 0.0, 0.0 },
                .bone_ids =     if (afb) |b| [4]i32 { @intCast(b[0].idx), @intCast(b[1].idx), @intCast(b[2].idx), @intCast(b[3].idx) }
                                else [4]i32{ 0, 0, 0, 0 },
                .bone_weights = if (afb) |b| [4]f32 { b[0].weight, b[1].weight, b[2].weight, b[3].weight, }
                                else [4]f32 { 1.0, 0.0, 0.0, 0.0 },
            };

            try writer.writeAll(std.mem.asBytes(&vertex_data));

            highest_number_of_bones_used_for_vertex = @max(highest_number_of_bones_used_for_vertex, bones_found_for_vertex);
        }

        if (highest_number_of_bones_used_for_vertex > 4) {
            std.log.warn("Bone influences have been truncated in mesh '{s}' from {} to 4", .{
                assimp_mesh.name(),
                highest_number_of_bones_used_for_vertex
            });
        }
    }

    fn assimp_write_mesh_index_data(writer: *std.io.Writer, assimp_mesh: assimp.Mesh.Ptr) !void {
        if (assimp_mesh.faces()) |assimp_mesh_faces| {
            for (assimp_mesh_faces) |face| {
                if (face.indices()) |fi| {
                    const indices = [3]u32 { fi[0], fi[1], fi[2] };
                    try writer.writeAll(std.mem.sliceAsBytes(&indices));
                }
            }
        }
    }

    fn create_material_texture_map_from_assimp(
        textures_names_map: *const std.StringHashMap(usize),
        textures: []gf.Image.Ref,
        assimp_material: assimp.Material.Ptr,
        texture_type: assimp.TextureType,
    ) !?MaterialTextureMap {
        const texture_props = assimp_material.get_texture_properties(texture_type, 0)
            orelse return null;

        const texture_index =   if (assimp.index_from_embedded_texture_path(texture_props.path())) |idx| idx
                                else textures_names_map.get(texture_props.path()) orelse return null;

        return MaterialTextureMap {
            .map = try gf.ImageView.init(.{
                .image = textures[texture_index],
                .view_type = .ImageView2D,
            }),
            .uv_index = @truncate(texture_props.uvindex),
            .sampler = try gf.Sampler.init(.{
                .filter_min_mag = .Linear,
            }),
        };
    }

    fn create_material_template_from_assimp(
        alloc: std.mem.Allocator,
        textures_names_map: *const std.StringHashMap(usize),
        textures: []gf.Image.Ref,
        assimp_material: assimp.Material.Ptr
    ) !MaterialTemplate {
        var material = MaterialTemplate {};

        var material_property_map = std.StringHashMap(assimp.MaterialProperty.Ptr).init(alloc);
        defer material_property_map.deinit();

        // fill property map
        material_property_map.clearRetainingCapacity();
        for (assimp_material.properties()) |prop| {
            try material_property_map.put(prop.key(), prop);
        }

        // collect material properties
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

        // collect material texture properties
        material.diffuse_map = try create_material_texture_map_from_assimp(textures_names_map, textures, assimp_material, assimp.TextureType.Diffuse);
        material.normals_map = try create_material_texture_map_from_assimp(textures_names_map, textures, assimp_material, assimp.TextureType.Normals);
    
        return material;
    }

    pub fn init_from_file_assimp(alloc: std.mem.Allocator, file: path.Path) !Self {
        const file_path = try file.resolve_path_c_str(alloc);
        defer alloc.free(file_path);

        var model_arena = std.heap.ArenaAllocator.init(alloc);
        errdefer model_arena.deinit();

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

        // Bones //
        var bones_info_list = try std.ArrayList(BoneInfo).initCapacity(alloc, MAX_BONES);
        defer bones_info_list.deinit(alloc);

        var bones_names_map = std.StringHashMap(i32).init(alloc);
        errdefer bones_names_map.deinit();

        // Meshes //
        const meshes = try model_arena.allocator().alloc(MeshPrimitive, scene.meshes().len);
        errdefer model_arena.allocator().free(meshes);

        var mesh_vertex_data_writer = std.io.Writer.Allocating.init(alloc);
        defer mesh_vertex_data_writer.deinit();

        var mesh_index_data_writer = std.io.Writer.Allocating.init(alloc);
        defer mesh_index_data_writer.deinit();

        var mesh_local_arena = std.heap.ArenaAllocator.init(alloc);
        defer mesh_local_arena.deinit();

        for (scene.meshes(), 0..) |assimp_mesh, mesh_idx| {
            const start_vertices_offset = mesh_vertex_data_writer.written().len;
            const mesh_vertex_count = (assimp_mesh.vertices() orelse return error.MeshHasNoVertices).len;

            const start_indices_offset = mesh_index_data_writer.written().len;
            const mesh_index_count = if (assimp_mesh.faces()) |faces| (faces.len * 3) else 0;

            try assimp_write_mesh_vertex_data(
                model_arena.allocator(), 
                &mesh_vertex_data_writer.writer, 
                assimp_mesh, 
                .{
                    .alloc = alloc,
                    .names_map = &bones_names_map,
                    .infos = &bones_info_list,
                }
            );
            try assimp_write_mesh_index_data(&mesh_index_data_writer.writer, assimp_mesh);

            std.debug.assert(@divExact(mesh_vertex_data_writer.written().len - start_vertices_offset, mesh_vertex_count) == MeshPrimitive.STRIDE);

            const positions = try mesh_local_arena.allocator().alloc([3]f32, assimp_mesh.vertices().?.len);
            defer mesh_local_arena.allocator().free(positions);

            var min_bounds = zm.f32x4s(std.math.floatMax(f32));
            var max_bounds = zm.f32x4s(std.math.floatMin(f32));

            for (assimp_mesh.vertices().?, 0..) |vertex, vertex_index| {
                positions[vertex_index] = [3]f32 { vertex.x, vertex.y, vertex.z };

                const position = zm.loadArr3(positions[vertex_index]);
                min_bounds = zm.min(min_bounds, position);
                max_bounds = zm.max(max_bounds, position);
            }

            // TODO create physics shapes for meshes using positions array

            meshes[mesh_idx] = MeshPrimitive {
                .vertex_count = mesh_vertex_count,
                .index_count = mesh_index_count,

                .vertices_offset = start_vertices_offset,
                .indices_offset = start_indices_offset,

                .topology = .Triangles, // TODO set this based on assimp mesh
                .material_template = @intCast(assimp_mesh.material_index()),

                .bounding_box = .{
                    .min = min_bounds,
                    .max = max_bounds,
                },
            };

            if (!mesh_local_arena.reset(.retain_capacity)) {
                std.log.warn("Mesh loading local arena failed to reset retaining capacity", .{});
                _ = mesh_local_arena.reset(.free_all);
            }
        }

        const vertices_buffer = try gf.Buffer.init_with_data(
            mesh_vertex_data_writer.written(),
            .{ .VertexBuffer = true, },
            .{},
        );
        errdefer vertices_buffer.deinit();

        const indices_buffer = try gf.Buffer.init_with_data(
            mesh_index_data_writer.written(),
            .{ .IndexBuffer = true, },
            .{},
        );
        errdefer indices_buffer.deinit();
        
        // solidify bones info array
        const bones_info = try model_arena.allocator().dupe(BoneInfo, bones_info_list.items);
        errdefer model_arena.allocator().free(bones_info);

        // Textures //
        const textures = try model_arena.allocator().alloc(gf.Image.Ref, scene.textures().len);
        errdefer model_arena.allocator().free(textures);

        var textures_list = std.ArrayList(gf.Image.Ref).initBuffer(textures);
        errdefer for (textures_list.items) |t| { t.deinit(); };

        for (scene.textures()) |assimp_texture| {
            const texture = try create_gfx_texture_from_assimp_texture(assimp_texture, .Rgba8_Unorm_Srgb);
            errdefer texture.deinit();

            try textures_list.appendBounded(texture);
        }

        var texture_names_map = std.StringHashMap(usize).init(local_arena.allocator());
        defer texture_names_map.deinit();

        for (scene.textures(), 0..) |tex, tex_idx| {
            try texture_names_map.put(tex.filename(), tex_idx);
        }

        // Materials //
        const materials = try model_arena.allocator().alloc(MaterialTemplate, scene.materials().len);
        errdefer model_arena.allocator().free(materials);

        var materials_list = std.ArrayList(MaterialTemplate).initBuffer(materials);
        errdefer for (materials_list.items) |*m| { m.deinit(); };

        {
            var material_property_map_arena = std.heap.ArenaAllocator.init(local_arena.allocator());
            defer material_property_map_arena.deinit();

            for (scene.materials()) |assimp_material| {
                if (!material_property_map_arena.reset(.retain_capacity)) {
                    std.log.warn("Materials loading arena failed to reset retaining capacity", .{});
                    _ = material_property_map_arena.reset(.free_all);
                }

                var material_template = try create_material_template_from_assimp(
                    material_property_map_arena.allocator(),
                    &texture_names_map,
                    textures,
                    assimp_material
                );
                errdefer material_template.deinit();

                try materials_list.appendBounded(material_template);
            }
        }

        // Nodes //
        var nodes_list = try std.ArrayList(ModelNode).initCapacity(alloc, 128);
        defer nodes_list.deinit(alloc);

        var nodes_index_map = std.AutoHashMap(*const assimp.Node, usize).init(alloc);
        defer nodes_index_map.deinit();

        var nodes_names_map = std.StringHashMap(usize).init(alloc);
        defer nodes_names_map.deinit();

        {
            var nodes_queue = try std.ArrayList(assimp.Node.Ptr).initCapacity(alloc, 128);
            defer nodes_queue.deinit(alloc);

            try nodes_queue.append(alloc, scene.root_node().?);
            while (nodes_queue.pop()) |assimp_node| {
                const node_name = try model_arena.allocator().dupe(u8, assimp_node.name());
                errdefer model_arena.allocator().free(node_name);

                const parent_index = if (assimp_node.parent()) |parent_node| blk: {
                    break :blk nodes_index_map.get(parent_node) orelse return error.ParentNodeHasNotBeenIndexed;
                } else null;

                const mesh_set = if (assimp_node.meshes().len > 0) blk: {
                    var mesh_set = MeshSet {
                        .num_primitives = 0,
                        .primitives = [1]usize{0} ** MeshSet.MAX_PRIMITIVES_PER_SET,
                        .physics_shape_settings = null, // TODO
                    };

                    for (assimp_node.meshes(), 0..) |assimp_mesh_index, primitive_index| {
                        if (primitive_index >= MeshSet.MAX_PRIMITIVES_PER_SET) {
                            std.log.warn("Model node '{s}' has more than max allowable mesh primitives {} > {}", .{
                                node_name,
                                assimp_node.meshes().len,
                                MeshSet.MAX_PRIMITIVES_PER_SET,
                            });
                            break;
                        }
                        if (assimp_mesh_index >= meshes.len) {
                            std.log.warn("Model node '{s}' refers to mesh primitive index that does not exist {}", .{
                                node_name,
                                assimp_mesh_index,
                            });
                            continue;
                        }

                        mesh_set.primitives[primitive_index] = @intCast(assimp_mesh_index);
                        mesh_set.num_primitives += 1;
                    }

                    break :blk mesh_set;
                } else null;

                // push node index to maps
                try nodes_names_map.putNoClobber(node_name, nodes_list.items.len);
                try nodes_index_map.putNoClobber(assimp_node, nodes_list.items.len);

                const transform = assimp_node.transformation_decompose();

                // append node to flat nodes list
                try nodes_list.append(alloc, ModelNode {
                    .name = node_name,
                    .parent = parent_index,
                    .transform = .{
                        .position = transform.pos,
                        .rotation = transform.rot,
                        .scale = transform.sca,
                    },
                    .mesh_set = mesh_set,
                });

                // append node children to processing queue
                if (assimp_node.children()) |assimp_node_children| {
                    for (assimp_node_children) |assimp_child_node| {
                        try nodes_queue.append(alloc, assimp_child_node);
                    }
                }
            }
        }

        // solidify model nodes array
        const model_nodes = try model_arena.allocator().dupe(ModelNode, nodes_list.items);
        errdefer model_arena.allocator().free(model_nodes);

        // Animations //
        const animations = try model_arena.allocator().alloc(an.BoneAnimation, scene.animations().len);
        errdefer model_arena.allocator().free(animations);

        for (scene.animations(), 0..) |anim, anim_id| {
            animations[anim_id] = an.BoneAnimation {
                .name = try model_arena.allocator().dupe(u8, anim.name()),
                .duration_ticks = anim.duration(),
                .ticks_per_second = anim.ticks_per_second(),
                .channels = try model_arena.allocator().alloc(an.BoneAnimationChannel, anim.channels().len),
                .current_tick = 0.0,
            };
            for (anim.channels(), 0..) |ch, ch_id| {
                const node_id = nodes_names_map.get(ch.node_name()).?;

                animations[anim_id].channels[ch_id] = an.BoneAnimationChannel {
                    .node_name = model_nodes[node_id].name.?,
                    .position_keys = try model_arena.allocator().alloc(an.AnimationKey, ch.position_keys().len),
                    .rotation_keys = try model_arena.allocator().alloc(an.AnimationKey, ch.rotation_keys().len),
                    .scale_keys = try model_arena.allocator().alloc(an.AnimationKey, ch.scale_keys().len),
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

        // Bounding Box //
        var bounding_box = BoundingBox{
            .min = zm.f32x4s(std.math.floatMax(f32)),
            .max = zm.f32x4s(std.math.floatMin(f32)),
        };
        for (meshes) |mesh| {
            bounding_box.min = zm.min(bounding_box.min, mesh.bounding_box.min);
            bounding_box.max = zm.max(bounding_box.max, mesh.bounding_box.max);
        }

        // Create Model //
        return Self {
            .arena_allocator = model_arena,

            .vertices_buffer = vertices_buffer,
            .indices_buffer = indices_buffer,

            .nodes = model_nodes,

            .meshes = meshes,
            .animations = animations,
            .textures = textures,
            .materials = materials,

            .global_inverse_transform = zm.inverse(scene.root_node().?.transformation()),
            .bones_names_map = bones_names_map,
            .bones_info = bones_info,

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

    pub fn init_from_shape(alloc: std.mem.Allocator, shape: *zmesh.Shape) !Model {
        var model_arena_allocator = std.heap.ArenaAllocator.init(alloc);
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
            } else {
                // @TODO: make this more robust, currently only works for planes
                var zmn = zm.f32x4s(0.0);
                var zmt = zm.f32x4s(0.0);
                var zmb = zm.f32x4s(0.0);
                for (normals, 0..) |*n, i| {
                    zmn = zm.loadArr3(n.*);
                    if (zm.dot3(zmn, zm.f32x4(0.0, 0.0, 1.0, 0.0))[0] < 0.9999) {
                        zmb = zm.cross3(zmn, zm.f32x4(0.0, 0.0, 1.0, 0.0));
                    } else {
                        zmb = zm.cross3(zmn, zm.f32x4(0.0, 1.0, 0.0, 0.0));
                    }
                    zmt = zm.cross3(zmb, zmn);
                    zmb = zm.cross3(zmt, zmn);

                    zm.storeArr3(&tangents[i], zmb);
                    zm.storeArr3(&bitangents[i], zmt);
                }
            }
        }

        var bounding_box = BoundingBox {
            .min = zm.f32x4s(std.math.floatMax(f32)),
            .max = zm.f32x4s(std.math.floatMin(f32)),
        };

        var mesh_vertex_data_writer = std.io.Writer.Allocating.init(alloc);
        defer mesh_vertex_data_writer.deinit();

        for (shape.positions, 0..) |position, idx| {
            const vertex_data = VertexData {
                .position = position,
                .normal = if (shape.normals) |normals| normals[idx] else [3]f32 { 0.0, 0.0, 1.0 },
                .tangent = tangents[idx],
                .bitangent = bitangents[idx],
                .tex_coord = if (shape.texcoords) |texcoords| texcoords[idx] else [2]f32 { 0.0, 0.0 },
                .bone_ids = [4]i32 { 0, 0, 0, 0 },
                .bone_weights = [4]f32 { 0.0, 0.0, 0.0, 0.0 },
            };

            try mesh_vertex_data_writer.writer.writeAll(std.mem.asBytes(&vertex_data));

            bounding_box.min = zm.min(bounding_box.min, zm.loadArr3(position));
            bounding_box.max = zm.max(bounding_box.max, zm.loadArr3(position));
        }
        
        const vertices_buffer = try gf.Buffer.init_with_data(
            mesh_vertex_data_writer.written(),
            .{ .VertexBuffer = true, },
            .{},
        );
        errdefer vertices_buffer.deinit();

        const indices_buffer = try gf.Buffer.init_with_data(
            std.mem.sliceAsBytes(shape.indices),
            .{ .IndexBuffer = true, },
            .{},
        );
        errdefer indices_buffer.deinit();

        // Generate a Model with 1 node and 1 mesh
        const mp = try model_arena.alloc(MeshPrimitive, 1);
        errdefer model_arena.free(mp);

        mp[0] = MeshPrimitive {
            .topology = .Triangles,
            .indices_offset = 0,
            .vertices_offset = 0,
            .vertex_count = shape.positions.len,
            .index_count = shape.indices.len,
            .material_template = null,
            .bounding_box = bounding_box,
        };

        const mn = try model_arena.alloc(ModelNode, 1);
        errdefer model_arena.free(mn);

        mn[0] = ModelNode {
            .mesh_set = MeshSet {
                .primitives = .{0} ** MeshSet.MAX_PRIMITIVES_PER_SET,
                .num_primitives = 1,
                .physics_shape_settings = @ptrCast(try zphy.ConvexHullShapeSettings.create(@ptrCast(shape.positions.ptr), @intCast(shape.positions.len), @sizeOf([3]f32))),
            },
        };

        const rn = try model_arena.alloc(usize, 1);
        errdefer model_arena.free(rn);

        rn[0] = 0;

        return Model {
            .arena_allocator = model_arena_allocator,

            .vertices_buffer = vertices_buffer,
            .indices_buffer = indices_buffer,

            .nodes = mn,

            .meshes = mp,
            .animations = &.{},
            .textures = &.{},
            .materials = &.{},

            .global_inverse_transform = zm.identity(),
            .bones_names_map = std.StringHashMap(i32).init(model_arena),
            .bones_info = &.{},

            .bounding_box = bounding_box,
        };
    }

    pub fn cone(alloc: std.mem.Allocator, slices: i32) !Model {
        // Generate cone shape
        var cone_shape = zmesh.Shape.initCone(slices, 6);
        defer cone_shape.deinit();

        // rotate to point upwards
        cone_shape.rotate(std.math.degreesToRadians(-90.0), 1.0, 0.0, 0.0);

        // flat shaded
        cone_shape.unweld();

        return try init_from_shape(alloc, &cone_shape);
    }

    pub fn plane(alloc: std.mem.Allocator, slices: i32, stacks: i32) !Model {
        // Generate cone shape
        var shape = zmesh.Shape.initPlane(slices, stacks);
        defer shape.deinit();

        // rotate to point upwards
        shape.translate(-0.5, -0.5, 0.0);
        shape.rotate(std.math.degreesToRadians(-90.0), 1.0, 0.0, 0.0);

        return try init_from_shape(alloc, &shape);
    }

    pub fn plane_on_sphere(alloc: std.mem.Allocator, slices: i32, stacks: i32, plane_extent_radians: f32) !Model {
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

        return try init_from_shape(alloc, &shape);
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

        return try init_from_shape(alloc, &shape);
    }

    pub fn sphere(alloc: std.mem.Allocator, subdivisions: i32) !Model {
        if (subdivisions > 5) {
            std.log.warn("zmesh sphere subdivisions greater than 5 is not recommended due to triangle count", .{});
        }

        // Generate sphere shape
        //var shape = zmesh.Shape.initParametricSphere(slices, stacks);
        var shape = zmesh.Shape.initSubdividedSphere(subdivisions);
        defer shape.deinit();

        // flat shaded
        //shape.unweld();

        return try init_from_shape(alloc, &shape);
    }

    pub fn cube(alloc: std.mem.Allocator) !Self {
        // Generate cube shape
        var shape = zmesh.Shape.initCube();
        defer shape.deinit();

        shape.translate(-0.5, -0.5, -0.5);

        // flat shaded
        shape.unweld();

        return try init_from_shape(alloc, &shape);
    }

    pub const AnimationEntry = struct {
        animation: *an.BoneAnimation,
        strength: f32,
    };

    pub fn blend_animation_bone_transforms(self: *const Self, animation: *const an.BoneAnimation, strength: f32, io_bone_transforms: []Transform) void {
        for (self.bones_info, 0..) |*bone_info, bone_id| {
            if (animation.find_node_anim(bone_info.bone_name)) |anim_channel| {
                io_bone_transforms[@intCast(bone_id)] = io_bone_transforms[@intCast(bone_id)].lerp(&anim_channel.selected_transform, strength);
            }
        }
    }

    pub fn generate_bone_transforms_for_pose(self: *const Self, alloc: std.mem.Allocator, in_bone_pose_transforms: []const Transform, out_bone_matrix_transforms: []zm.Mat) void {
        std.debug.assert(in_bone_pose_transforms.len >= MAX_BONES);
        std.debug.assert(out_bone_matrix_transforms.len >= MAX_BONES);

        const node_matrix_list = alloc.alloc(zm.Mat, self.nodes.len) catch |err| {
            std.log.warn("Unable to allocate memory as part of pose generation: {}", .{err});
            return;
        };
        defer alloc.free(node_matrix_list);

        for (self.nodes, 0..) |*node, node_index| {
            const parent_mat = if (node.parent) |parent_node_index| blk: {
                std.debug.assert(parent_node_index < node_index);
                break :blk node_matrix_list[parent_node_index];
             } else zm.identity();

            const node_name = node.name.?;
            const maybe_bone_id = self.bones_names_map.get(node_name);

            var anims_transform = node.transform;
            if (maybe_bone_id) |bone_id| {
                anims_transform = in_bone_pose_transforms[@intCast(bone_id)];
            }

            const node_transform = anims_transform.generate_model_matrix();
            node_matrix_list[node_index] = zm.mul(node_transform, parent_mat);

            if (maybe_bone_id) |bone_id| {
                const bone_info = &self.bones_info[@intCast(bone_id)];
                const final_transform = zm.mul(bone_info.bone_offset_matrix, zm.mul(node_matrix_list[node_index], self.global_inverse_transform));
                out_bone_matrix_transforms[@intCast(bone_id)] = final_transform;
            }
        }
    }

    pub fn gen_static_compound_physics_shape(self: *const Model) !*zphy.CompoundShapeSettings {
        var shape_settings = try zphy.CompoundShapeSettings.createStatic();
        for (self.nodes) |*node| {
            if (node.mesh_set) |mid| {
                const physics_shape_settings = mid.physics_shape_settings orelse return error.NoShapeSettings;
                var scaled_shape_settings = try zphy.DecoratedShapeSettings.createScaled(
                    physics_shape_settings,
                    .{node.transform.scale[0], node.transform.scale[1], node.transform.scale[2]}
                );
                defer scaled_shape_settings.asShapeSettings().release();

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
};
