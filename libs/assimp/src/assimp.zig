const util = @import("util.zig");
const c = util.c;
const std = @import("std");

pub const Vector3D = c.aiVector3D;
pub const Vector4D = c.aiColor4D;
pub const VertexWeight = c.aiVertexWeight;
pub const BoundingBox = c.aiAABB;

pub const Node = opaque {
    pub const AssimpType = c.aiNode;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }
    
    // mName: struct_aiString = @import("std").mem.zeroes(struct_aiString),
    // mTransformation: struct_aiMatrix4x4 = @import("std").mem.zeroes(struct_aiMatrix4x4),
    // mParent: [*c]struct_aiNode = @import("std").mem.zeroes([*c]struct_aiNode),
    // mNumChildren: c_uint = @import("std").mem.zeroes(c_uint),
    // mChildren: [*c][*c]struct_aiNode = @import("std").mem.zeroes([*c][*c]struct_aiNode),
    // mNumMeshes: c_uint = @import("std").mem.zeroes(c_uint),
    // mMeshes: [*c]c_uint = @import("std").mem.zeroes([*c]c_uint),
    // mMetaData: [*c]struct_aiMetadata = @import("std").mem.zeroes([*c]struct_aiMetadata),

    pub fn name(pself: Ptr) []const u8 {
        const self = pself.cast();
        return util.stringFromAiString(&self.mName);
    }

    pub fn transformation(pself: Ptr) util.Mat4x4 {
        const self = pself.cast();
        return util.matFromAiTransform(&self.mTransformation);
    }

    pub fn transformation_decompose(pself: Ptr) struct {pos: @Vector(4, f32), rot: @Vector(4, f32), sca: @Vector(4, f32)} {
        const self = pself.cast();
        var position: c.aiVector3D = undefined;
        var scaling: c.aiVector3D = undefined;
        var rotation: c.aiQuaternion = undefined;
        c.aiDecomposeMatrix(&self.mTransformation, &scaling, &rotation, &position);
        return .{
            .pos = @Vector(4, f32){position.x, position.y, position.z, 0.0},
            .rot = @Vector(4, f32){rotation.x, rotation.y, rotation.z, rotation.w},
            .sca = @Vector(4, f32){scaling.x, scaling.y, scaling.z, 1.0},
        };
    }

    pub fn parent(pself: Ptr) ?Ptr {
        const self = pself.cast();
        return @ptrCast(self.mParent);
    }

    pub fn children(pself: Ptr) ?[]const Ptr {
        const self = pself.cast();
        if (self.mChildren == null) { return null; }

        return util.double_cast_array(Node, self.mChildren, self.mNumChildren);
    }

    pub fn has_meshes(pself: Ptr) bool {
        return (pself.cast().mNumMeshes > 0);
    }

    pub fn meshes(pself: Ptr) []c_uint {
        if (!pself.has_meshes()) { 
            // return 0 length slice, this feels kind of scuffed
            return ([0]c_uint{})[0..0]; 
        }
        const self = pself.cast();
        return self.mMeshes[0..self.mNumMeshes];
    }

    pub fn metadata(pself: Ptr) ?Metadata {
        const self = pself.cast();
        return @ptrCast(self.mMetaData);
    }
};

pub const Scene = opaque {
    pub const AssimpType = c.aiScene;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mFlags: c_uint,
    // mRootNode: [*c]c.aiNode,
    // mNumMeshes: c_uint,
    // mMeshes: [*c][*c]c.aiMesh,
    // mNumMaterials: c_uint,
    // mMaterials: [*c][*c]c.aiMaterial,
    // mNumAnimations: c_uint,
    // mAnimations: [*c][*c]c.aiAnimation,
    // mNumTextures: c_uint,
    // mTextures: [*c][*c]c.aiTexture,
    // mNumLights: c_uint,
    // mLights: [*c][*c]c.aiLight,
    // mNumCameras: c_uint,
    // mCameras: [*c][*c]c.aiCamera,
    // mMetaData: [*c]c.aiMetadata,
    // mName: aiString,
    // mNumSkeletons: c_uint,
    // mSkeletons: [*c][*c]c.aiSkeleton,
    // mPrivate: [*c]u8,
    
    pub fn root_node(pself: Ptr) ?Node.Ptr {
        return @ptrCast(pself.cast().mRootNode);
    }

    pub fn meshes(pself: Ptr) []const ?Mesh.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Mesh, self.mMeshes, self.mNumMeshes);
    }

    pub fn metadata(pself: Ptr) ?Metadata.Ptr {
        const self = pself.cast();
        return @ptrCast(self.mMetaData);
    }

    pub fn name(pself: Ptr) []const u8 {
        return util.stringFromAiString(&pself.cast().mName);
    }
};

pub const Mesh = opaque {
    pub const AssimpType = c.aiMesh;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mPrimitiveTypes: c_uint = @import("std").mem.zeroes(c_uint),
    // mNumVertices: c_uint = @import("std").mem.zeroes(c_uint),
    // mNumFaces: c_uint = @import("std").mem.zeroes(c_uint),
    // mVertices: [*c]struct_aiVector3D = @import("std").mem.zeroes([*c]struct_aiVector3D),
    // mNormals: [*c]struct_aiVector3D = @import("std").mem.zeroes([*c]struct_aiVector3D),
    // mTangents: [*c]struct_aiVector3D = @import("std").mem.zeroes([*c]struct_aiVector3D),
    // mBitangents: [*c]struct_aiVector3D = @import("std").mem.zeroes([*c]struct_aiVector3D),
    // mColors: [8][*c]struct_aiColor4D = @import("std").mem.zeroes([8][*c]struct_aiColor4D),
    // mTextureCoords: [8][*c]struct_aiVector3D = @import("std").mem.zeroes([8][*c]struct_aiVector3D),
    // mNumUVComponents: [8]c_uint = @import("std").mem.zeroes([8]c_uint),
    // mFaces: [*c]struct_aiFace = @import("std").mem.zeroes([*c]struct_aiFace),
    // mNumBones: c_uint = @import("std").mem.zeroes(c_uint),
    // mBones: [*c][*c]struct_aiBone = @import("std").mem.zeroes([*c][*c]struct_aiBone),
    // mMaterialIndex: c_uint = @import("std").mem.zeroes(c_uint),
    // mName: struct_aiString = @import("std").mem.zeroes(struct_aiString),
    // mNumAnimMeshes: c_uint = @import("std").mem.zeroes(c_uint),
    // mAnimMeshes: [*c][*c]struct_aiAnimMesh = @import("std").mem.zeroes([*c][*c]struct_aiAnimMesh),
    // mMethod: enum_aiMorphingMethod = @import("std").mem.zeroes(enum_aiMorphingMethod),
    // mAABB: struct_aiAABB = @import("std").mem.zeroes(struct_aiAABB),
    // mTextureCoordsNames: [*c][*c]struct_aiString = @import("std").mem.zeroes([*c][*c]struct_aiString),

    pub fn num_vertices(pself: Ptr) u32 {
        return pself.cast().mNumVertices;
    }

    pub fn vertices(pself: Ptr) ?[]const Vector3D {
        const self = pself.cast();
        if (self.mVertices == null) { return null; }

        return @as([*c]Vector3D, @ptrCast(self.mVertices))[0..self.mNumVertices];
    }

    pub fn faces(pself: Ptr) ?[]const Face {
        const self = pself.cast();
        if (self.mFaces == null) { return null; }

        return @as([*c]Face, @ptrCast(self.mFaces))[0..self.mNumFaces];
    }

    pub fn normals(pself: Ptr) ?[]const Vector3D {
        const self = pself.cast();
        if (self.mNormals == null) { return null; }

        return @as([*c]Vector3D, @ptrCast(self.mNormals))[0..self.mNumVertices];
    }

    pub fn tangents(pself: Ptr) ?[]const Vector3D {
        const self = pself.cast();
        if (self.mTangents == null) { return null; }

        return @as([*c]Vector3D, @ptrCast(self.mTangents))[0..self.mNumVertices];
    }

    pub fn bitangents(pself: Ptr) ?[]const Vector3D {
        const self = pself.cast();
        if (self.mBitangents == null) { return null; }

        return @as([*c]Vector3D, @ptrCast(self.mBitangents))[0..self.mNumVertices];
    }

    pub fn colors(pself: Ptr, index: u4) ?[]const Vector4D {
        const self = pself.cast();
        if (self.mColors[index] == null) { return null; }

        return @as([*c]Vector4D, @ptrCast(self.mColors[index]))[0..self.mNumVertices];
    }

    pub fn texcoords(pself: Ptr, index: u4) ?[]const Vector3D {
        const self = pself.cast();
        if (self.mTextureCoords[index] == null) { return null; }

        return @as([*c]Vector3D, @ptrCast(self.mTextureCoords[index]))[0..self.mNumVertices];
    }

    pub fn num_uv_components(pself: Ptr, index: u4) u32 {
        return pself.cast().mNumUVComponents[index];
    }

    pub fn num_faces(pself: Ptr) u32 {
        return pself.cast().mNumFaces;
    }

    pub fn bones(pself: Ptr) ?[]const Bone.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Bone, self.mBones, self.mNumBones);
    }

    pub fn material_index(pself: Ptr) u32 {
        return pself.cast().mMaterialIndex;
    }

    pub fn name(pself: Ptr) []const u8 {
        return util.stringFromAiString(&pself.cast().mName);
    }

    pub fn bounding_box(pself: Ptr) BoundingBox {
        return pself.cast().mAABB;
    }
};

pub const Face = extern struct {
    aiFace: c.aiFace,

    pub fn indices(self: *const Face) ?[]const c_uint {
        if (self.aiFace.mIndices == null) { return null; }

        return self.aiFace.mIndices[0..self.aiFace.mNumIndices];
    }
};

pub const Metadata = opaque {
    pub const AssimpType = c.aiMetadata;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mNumProperties: c_uint = @import("std").mem.zeroes(c_uint),
    // mKeys: [*c]struct_aiString = @import("std").mem.zeroes([*c]struct_aiString),
    // mValues: [*c]struct_aiMetadataEntry = @import("std").mem.zeroes([*c]struct_aiMetadataEntry),
    
    pub fn num_properties(pself: Ptr) u32 {
        return pself.cast().mNumProperties;
    }

    pub fn get_key_at_index(pself: Ptr, index: u32) ?[]const u8 {
        const self = pself.cast();
        if (index >= self.mNumProperties) {
            return null;
        }
        return util.stringFromAiString(self.mKeys[index]);
    }

    pub fn get_property_at_index(pself: Ptr, index: u32) ?MetadataEntry {
        const self = pself.cast();
        if (index >= self.mNumProperties) {
            return null;
        }
        return @ptrCast(self.mValues[index]);
    }
    
    pub fn get_property(pself: Ptr, key: []const u8) ?MetadataEntry {
        const self = pself.cast();
        const keys: []c.aiString = self.mKeys[0..self.mNumProperties];
        for (keys, 0..) |*k, idx| {
            if (std.mem.eql(u8, util.stringFromAiString(k), key)) {
                return @ptrCast(self.mValues[idx]);
            }
        }
        return null;
    }
};

pub const MetadataEntry = opaque {
    pub const AssimpType = c.aiMetadataEntry;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mType: aiMetadataType = @import("std").mem.zeroes(aiMetadataType),
    // mData: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),

    // @TODO
};

pub const Bone = opaque {
    pub const AssimpType = c.aiBone;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mName: struct_aiString = @import("std").mem.zeroes(struct_aiString),
    // mNumWeights: c_uint = @import("std").mem.zeroes(c_uint),
    // mArmature: [*c]struct_aiNode = @import("std").mem.zeroes([*c]struct_aiNode),
    // mNode: [*c]struct_aiNode = @import("std").mem.zeroes([*c]struct_aiNode),
    // mWeights: [*c]struct_aiVertexWeight = @import("std").mem.zeroes([*c]struct_aiVertexWeight),
    // mOffsetMatrix: struct_aiMatrix4x4 = @import("std").mem.zeroes(struct_aiMatrix4x4),

    pub fn name(pself: Ptr) []const u8 {
        return util.stringFromAiString(pself.cast().mName);
    }

    pub fn weights(pself: Ptr) []const VertexWeight {
        const self = pself.cast();
        return self.mWeights[0..self.mNumWeights];
    }

    pub fn armature(pself: Ptr) ?Node.Ptr {
        return pself.cast().mArmature;
    }

    pub fn node(pself: Ptr) ?Node.Ptr {
        return pself.cast().mNode;
    }

    pub fn offset_matrix(pself: Ptr) util.Mat4x4 {
        return util.matFromAiTransform(pself.cast().mOffsetMatrix);
    }
};

pub fn aiImportFile(pFile: [*:0]const u8, pFlags: u32) !Scene.Ptr {
    const scene: ?Scene.Ptr = @ptrCast(c.aiImportFile(pFile, pFlags));
    if (scene == null) {
        return error.FailedImport;
    }
    return scene.?;
}

pub fn aiReleaseImport(pScene: Scene.Ptr) void {
    c.aiReleaseImport(@ptrCast(pScene));
}
