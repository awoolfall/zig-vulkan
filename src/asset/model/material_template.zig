const std = @import("std");
const eng = @import("self");
const assimp = @import("assimp");

const Self = @This();

double_sided: bool = true,
metallic_factor: f32 = 0.0,
roughness_factor: f32 = 1.0,
shininess: f32 = 0.0,
emissiveness: f32 = 0.0,
opacity: f32 = 1.0,
unlit: bool = false,
diffuse_map: ?MaterialTextureMap = null,
normals_map: ?MaterialTextureMap = null,

pub fn deinit(self: *Self) void {
    if (self.diffuse_map) |*m| m.deinit();
    if (self.normals_map) |*m| m.deinit();
}

pub fn init_from_assimp(
    alloc: std.mem.Allocator,
    textures_names_map: *const std.StringHashMap(usize),
    textures: []eng.gfx.Image.Ref,
    assimp_material: assimp.Material.Ptr
) !Self {
    var material = Self {};

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
    material.diffuse_map = try MaterialTextureMap.init_from_assimp(textures_names_map, textures, assimp_material, assimp.TextureType.Diffuse);
    material.normals_map = try MaterialTextureMap.init_from_assimp(textures_names_map, textures, assimp_material, assimp.TextureType.Normals);

    return material;
}

pub const MaterialTextureMap = struct {
    map: eng.gfx.ImageView.Ref,
    uv_index: u8,
    sampler: ?eng.gfx.Sampler.Ref = null,

    pub fn deinit(self: *MaterialTextureMap) void {
        self.map.deinit();
        if (self.sampler) |*s| s.deinit();
    }

    pub fn init_from_assimp(
        textures_names_map: *const std.StringHashMap(usize),
        textures: []eng.gfx.Image.Ref,
        assimp_material: assimp.Material.Ptr,
        texture_type: assimp.TextureType,
    ) !?MaterialTextureMap {
        const texture_props = assimp_material.get_texture_properties(texture_type, 0)
            orelse return null;

        const texture_index =   if (assimp.index_from_embedded_texture_path(texture_props.path())) |idx| idx
                                else textures_names_map.get(texture_props.path()) orelse return null;

        return MaterialTextureMap {
            .map = try eng.gfx.ImageView.init(.{
                .image = textures[texture_index],
                .view_type = .ImageView2D,
            }),
            .uv_index = @truncate(texture_props.uvindex),
            .sampler = try eng.gfx.Sampler.init(.{
                .filter_min_mag = .Linear,
            }),
        };
    }
};
