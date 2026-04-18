const eng = @import("self");

const Self = @This();

pub const STRIDE =  @sizeOf([3]f32)     // positions
                +   @sizeOf([3]f32)     // normals
                +   @sizeOf([3]f32)     // tangents
                +   @sizeOf([3]f32)     // bitangents
                +   @sizeOf([2]f32)     // tex_coords
                +   @sizeOf([4]i32)     // bone_ids
                +   @sizeOf([4]f32);    // bone_weights

pub const Topology = enum {
    Points,
    Lines,
    LineLoop,
    LineStrip,
    Triangles,
    TriangleStrip,
    TriangleFan,
};

index_count: usize,
vertex_count: usize,

indices_offset: usize,
vertices_offset: usize,

topology: Topology,
material_template: ?usize,

bounding_box: eng.util.BoundingBox,

// Check whether the mesh primitive has indices
pub inline fn has_indices(self: *const Self) bool {
    return self.index_count != 0;
}
