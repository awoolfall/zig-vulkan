const c = @cImport({
    @cInclude("assimp/cimport.h");
    @cInclude("assimp/scene.h");
});

inline fn aiBoolFromBool(b: bool) c.aiBool {
    return @intFromBool(b);
}

inline fn stringFromAiString(s: *const c.aiString) []const u8 {
    return s.data[0..s.length];
}

inline fn double_cast_array(comptime OutType: type, array: [*c][*c]OutType.AssimpType, array_length: c_uint) []?OutType.Ptr {
    return @as([*c]?OutType.Ptr, @ptrCast(array))[0..array_length];
}

pub const Node = opaque {
    const AssimpType = c.aiNode;

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
        return stringFromAiString(&self.mName);
    }

    pub fn children(pself: Ptr) []const ?Ptr {
        const self = pself.cast();
        return double_cast_array(Node, self.mChildren, self.mNumChildren);
    }
};

pub const Scene = opaque {
    const AssimpType = c.aiScene;

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

    pub fn name(pself: Ptr) []const u8 {
        return stringFromAiString(&pself.cast().mName);
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
