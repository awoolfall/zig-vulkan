const std = @import("std");
const eng = @import("self");

const Self = @This();

pub const ShapeUnion = union(enum) {
    Box: struct { width: f32 = 1.0, height: f32 = 1.0, depth: f32 = 1.0 },
    Sphere: struct { radius: f32 = 0.5 },
    Capsule: struct { half_height: f32 = 0.7, radius: f32 = 0.2 },
    ModelCompoundConvexHull: eng.assets.ModelAssetId,
};

shape: ShapeUnion,
offset_transform: eng.Transform,
