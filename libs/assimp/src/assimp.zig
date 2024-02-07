const util = @import("util.zig");
const c = util.c;
const std = @import("std");

pub const Vector3D = c.aiVector3D;
pub const Vector4D = c.aiColor4D;
pub const Texel4D = c.aiTexel;
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

    pub fn meshes(pself: Ptr) []const Mesh.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Mesh, self.mMeshes, self.mNumMeshes);
    }

    pub fn materials(pself: Ptr) []const Material.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Material, self.mMaterials, self.mNumMaterials);
    }

    pub fn animations(pself: Ptr) []const Animation.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Animation, self.mAnimations, self.mNumAnimations);
    }

    pub fn textures(pself: Ptr) []const Texture.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Texture, self.mTextures, self.mNumTextures);
    }

    pub fn skeletons(pself: Ptr) []const Skeleton.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Skeleton, self.mSkeletons, self.mNumSkeletons);
    }

    pub fn metadata(pself: Ptr) ?Metadata.Ptr {
        const self = pself.cast();
        return @ptrCast(self.mMetaData);
    }

    pub fn name(pself: Ptr) []const u8 {
        return util.stringFromAiString(&pself.cast().mName);
    }
};

pub const TextureType = enum(c_uint) {
    Diffuse = c.aiTextureType_DIFFUSE,
};

pub const Material = opaque {
    pub const AssimpType = c.aiMaterial;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mProperties: [*c][*c]struct_aiMaterialProperty = @import("std").mem.zeroes([*c][*c]struct_aiMaterialProperty),
    // mNumProperties: c_uint = @import("std").mem.zeroes(c_uint),
    // mNumAllocated: c_uint = @import("std").mem.zeroes(c_uint),

    pub fn properties(pself: Ptr) []const MaterialProperty.Ptr {
        const self = pself.cast();
        return util.double_cast_array(MaterialProperty, self.mProperties, self.mNumProperties);
    }

    pub fn get_texture_count(pself: Ptr, texture_type: TextureType) u32 {
        return @intCast(c.aiGetMaterialTextureCount(pself.cast(), @intFromEnum(texture_type)));
    }

    pub fn get_texture_properties(pself: Ptr, texture_type: TextureType, texture_index: u32) ?MaterialTextureProperties {
        var path_string: c.struct_aiString = undefined;
        var mapping: c.enum_aiTextureMapping = undefined;
        var uvindex: c_uint = undefined;
        var blend: c.ai_real = undefined;
        var op: c.enum_aiTextureOp = undefined;
        var mapmode: c.enum_aiTextureMapMode = undefined;
        var flags: c_uint = undefined;
        const ret = c.aiGetMaterialTexture(
            pself.cast(),
            @intFromEnum(texture_type),
            texture_index,
            &path_string,
            &mapping,
            &uvindex,
            &blend,
            &op,
            &mapmode,
            &flags);
        if (ret != c.aiReturn_SUCCESS) {
            return null;
        }
        const props = MaterialTextureProperties {
            .path_data = path_string.data,
            .path_length = path_string.length,
            .mapping = mapping,
            .uvindex = uvindex,
            .blend = blend,
            .op = op,
            .mapmode = mapmode,
            .flags = flags
        };
        return props;
    }
};

pub const MaterialTextureProperties = struct {
    path_data: [1024]u8,
    path_length: u32,
    mapping: c.enum_aiTextureMapping,
    uvindex: u32,
    blend: f32,
    op: c.enum_aiTextureOp,
    mapmode: c.enum_aiTextureMapMode,
    flags: u32,

    pub fn path(self: *const MaterialTextureProperties) []const u8 {
        return self.path_data[0..self.path_length];
    }
};

pub const MaterialProperty = opaque {
    pub const AssimpType = c.aiMaterialProperty;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mKey: struct_aiString = @import("std").mem.zeroes(struct_aiString),
    // mSemantic: c_uint = @import("std").mem.zeroes(c_uint),
    // mIndex: c_uint = @import("std").mem.zeroes(c_uint),
    // mDataLength: c_uint = @import("std").mem.zeroes(c_uint),
    // mType: enum_aiPropertyTypeInfo = @import("std").mem.zeroes(enum_aiPropertyTypeInfo),
    // mData: [*c]u8 = @import("std").mem.zeroes([*c]u8),

    const PropertyType = enum(u32) {
        Float = c.aiPTI_Float,
        Double = c.aiPTI_Double,
        String = c.aiPTI_String,
        Integer = c.aiPTI_Integer,
        Buffer = c.aiPTI_Buffer,
    };

    pub fn key(pself: Ptr) []const u8 {
        return util.stringFromAiString(&(pself.cast().mKey));
    }

    pub fn semantic(pself: Ptr) u32 {
        return pself.cast().mSemantic;
    }

    pub fn index(pself: Ptr) u32 {
        return pself.cast().mIndex;
    }

    pub fn property_type(pself: Ptr) PropertyType {
        return @enumFromInt(pself.cast().mType);
    }

    pub fn data(pself: Ptr) []const u8 {
        const self = pself.cast();
        return self.mData[0..self.mDataLength];
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

pub const Animation = opaque {
    pub const AssimpType = c.aiAnimation;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mName: struct_aiString = @import("std").mem.zeroes(struct_aiString),
    // mDuration: f64 = @import("std").mem.zeroes(f64),
    // mTicksPerSecond: f64 = @import("std").mem.zeroes(f64),
    // mNumChannels: c_uint = @import("std").mem.zeroes(c_uint),
    // mChannels: [*c][*c]struct_aiNodeAnim = @import("std").mem.zeroes([*c][*c]struct_aiNodeAnim),
    // mNumMeshChannels: c_uint = @import("std").mem.zeroes(c_uint),
    // mMeshChannels: [*c][*c]struct_aiMeshAnim = @import("std").mem.zeroes([*c][*c]struct_aiMeshAnim),
    // mNumMorphMeshChannels: c_uint = @import("std").mem.zeroes(c_uint),
    // mMorphMeshChannels: [*c][*c]struct_aiMeshMorphAnim = @import("std").mem.zeroes([*c][*c]struct_aiMeshMorphAnim),

    pub fn name(pself: Ptr) []const u8 {
        return util.stringFromAiString(pself.cast().mName);
    }

    pub fn duration(pself: Ptr) f64 {
        return pself.cast().mDuration;
    }

    pub fn ticks_per_second(pself: Ptr) f64 {
        return pself.cast().mTicksPerSecond;
    }

    pub fn channels(pself: Ptr) []const NodeAnim.Ptr {
        const self = pself.cast();
        return util.double_cast_array(NodeAnim, self.mChannels, self.mNumChannels);
    }
};

pub const NodeAnim = opaque {
    pub const AssimpType = c.aiNodeAnim;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mNodeName: struct_aiString = @import("std").mem.zeroes(struct_aiString),
    // mNumPositionKeys: c_uint = @import("std").mem.zeroes(c_uint),
    // mPositionKeys: [*c]struct_aiVectorKey = @import("std").mem.zeroes([*c]struct_aiVectorKey),
    // mNumRotationKeys: c_uint = @import("std").mem.zeroes(c_uint),
    // mRotationKeys: [*c]struct_aiQuatKey = @import("std").mem.zeroes([*c]struct_aiQuatKey),
    // mNumScalingKeys: c_uint = @import("std").mem.zeroes(c_uint),
    // mScalingKeys: [*c]struct_aiVectorKey = @import("std").mem.zeroes([*c]struct_aiVectorKey),
    // mPreState: enum_aiAnimBehaviour = @import("std").mem.zeroes(enum_aiAnimBehaviour),
    // mPostState: enum_aiAnimBehaviour = @import("std").mem.zeroes(enum_aiAnimBehaviour),

    pub fn node_name(pself: Ptr) []const u8 {
        return util.stringFromAiString(pself.cast().mNodeName);
    }

    pub const VectorKey = extern struct {
        aiVectorKey: c.struct_aiVectorKey,

        pub fn time(self: *const VectorKey) f64 {
            return self.aiVectorKey.mTime;
        }

        pub fn value(self: *const VectorKey) @Vector(f32, 4) {
            return @Vector(f32, 4) {
                self.aiVectorKey.mValue.x,
                self.aiVectorKey.mValue.y,
                self.aiVectorKey.mValue.z,
                0.0,
            };
        }
    };

    pub const QuatKey = extern struct {
        aiQuatKey: c.struct_aiQuatKey,

        pub fn time(self: *const QuatKey) f64 {
            return self.aiQuatKey.mTime;
        }

        pub fn value(self: *const QuatKey) @Vector(f32, 4) {
            return @Vector(f32, 4){
                self.aiQuatKey.mValue.x,
                self.aiQuatKey.mValue.y,
                self.aiQuatKey.mValue.z,
                self.aiQuatKey.mValue.w,
            };
        }
    };

    pub fn position_keys(pself: Ptr) []const VectorKey {
        const self = pself.cast();
        return @as([*c]VectorKey, @ptrCast(self.mPositionKeys))[0..self.mNumPositionKeys];
    }

    pub fn rotation_keys(pself: Ptr) []const QuatKey {
        const self = pself.cast();
        return @as([*c]QuatKey, @ptrCast(self.mRotationKeys))[0..self.mNumRotationKeys];
    }

    pub fn scale_keys(pself: Ptr) []const VectorKey {
        const self = pself.cast();
        return @as([*c]VectorKey, @ptrCast(self.mScalingKeys))[0..self.mNumScalingKeys];
    }

    pub const AnimBehaviour = enum(c_uint) {
        Default = c.aiAnimBehaviour_DEFAULT,
        Constant = c.aiAnimBehaviour_CONSTANT,
        Linear = c.aiAnimBehaviour_LINEAR,
        Repeat = c.aiAnimBehaviour_REPEAT,
    };

    pub fn pre_state(pself: Ptr) AnimBehaviour {
        return @enumFromInt(pself.cast().mPreState);
    }

    pub fn post_state(pself: Ptr) AnimBehaviour {
        return @enumFromInt(pself.cast().mPostState);
    }
};

pub const Texture = opaque {
    pub const AssimpType = c.aiTexture;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mWidth: c_uint = @import("std").mem.zeroes(c_uint),
    // mHeight: c_uint = @import("std").mem.zeroes(c_uint),
    // achFormatHint: [9]u8 = @import("std").mem.zeroes([9]u8),
    // pcData: [*c]struct_aiTexel = @import("std").mem.zeroes([*c]struct_aiTexel),
    // mFilename: struct_aiString = @import("std").mem.zeroes(struct_aiString),

    pub fn width(pself: Ptr) u32 {
        return pself.cast().mWidth;
    }

    pub fn height(pself: Ptr) u32 {
        return pself.cast().mHeight;
    }
    
    pub fn is_compressed_data(pself: Ptr) bool {
        return pself.cast().mHeight == 0;
    }

    pub fn compressed_data(pself: Ptr) ?[]const u8 {
        if (!pself.is_compressed_data()) { return null; }

        return pself.cast().pcData[0..(pself.cast().mWidth)];
    }

    pub fn data(pself: Ptr) ?[]const Texel4D {
        if (pself.is_compressed_data()) { return null; }

        const self = pself.cast();
        return self.pcData[0..(self.mWidth * self.mHeight)];
    }

    pub fn data_u8_bgra(pself: Ptr) ?[]const u8 {
        std.debug.assert(@sizeOf(c.struct_aiTexel) == (4 * @sizeOf(u8)));
        if (pself.is_compressed_data()) { return null; }

        const self = pself.cast();
        return @as([*c]u8, @ptrCast(self.pcData))[0..(4 * self.mWidth * self.mHeight)];
    }

    pub fn filename(pself: Ptr) []const u8 {
        return util.stringFromAiString(pself.cast().mFilename);
    }
};

pub const Skeleton = opaque {
    pub const AssimpType = c.aiSkeleton;

    pub const Ptr = *const align(@alignOf(AssimpType)) @This();
    inline fn cast(self: Ptr) *const AssimpType { return @ptrCast(self); }

    // mName: struct_aiString = @import("std").mem.zeroes(struct_aiString),
    // mNumBones: c_uint = @import("std").mem.zeroes(c_uint),
    // mBones: [*c][*c]struct_aiSkeletonBone = @import("std").mem.zeroes([*c][*c]struct_aiSkeletonBone),

    pub fn name(pself: Ptr) []const u8 {
        return util.stringFromAiString(pself.cast().mName);
    }

    pub fn bones(pself: Ptr) []const Bone.Ptr {
        const self = pself.cast();
        return util.double_cast_array(Bone, self.mBones, self.mNumBones);
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

// Material defines
pub const AI_MATKEY_NAME: []const u8 = "?mat.name";
pub const AI_MATKEY_TWOSIDED: []const u8 = "$mat.twosided";
pub const AI_MATKEY_SHADING_MODEL: []const u8 = "$mat.shadingm";
pub const AI_MATKEY_ENABLE_WIREFRAME: []const u8 = "$mat.wireframe";
pub const AI_MATKEY_BLEND_FUNC: []const u8 = "$mat.blend";
pub const AI_MATKEY_OPACITY: []const u8 = "$mat.opacity";
pub const AI_MATKEY_TRANSPARENCYFACTOR: []const u8 = "$mat.transparencyfactor";
pub const AI_MATKEY_BUMPSCALING: []const u8 = "$mat.bumpscaling";
pub const AI_MATKEY_SHININESS: []const u8 = "$mat.shininess";
pub const AI_MATKEY_REFLECTIVITY: []const u8 = "$mat.reflectivity";
pub const AI_MATKEY_SHININESS_STRENGTH: []const u8 = "$mat.shinpercent";
pub const AI_MATKEY_REFRACTI: []const u8 = "$mat.refracti";
pub const AI_MATKEY_COLOR_DIFFUSE: []const u8 = "$clr.diffuse";
pub const AI_MATKEY_COLOR_AMBIENT: []const u8 = "$clr.ambient";
pub const AI_MATKEY_COLOR_SPECULAR: []const u8 = "$clr.specular";
pub const AI_MATKEY_COLOR_EMISSIVE: []const u8 = "$clr.emissive";
pub const AI_MATKEY_COLOR_TRANSPARENT: []const u8 = "$clr.transparent";
pub const AI_MATKEY_COLOR_REFLECTIVE: []const u8 = "$clr.reflective";
pub const AI_MATKEY_GLOBAL_BACKGROUND_IMAGE: []const u8 = "?bg.global";
pub const AI_MATKEY_GLOBAL_SHADERLANG: []const u8 = "?sh.lang";
pub const AI_MATKEY_SHADER_VERTEX: []const u8 = "?sh.vs";
pub const AI_MATKEY_SHADER_FRAGMENT: []const u8 = "?sh.fs";
pub const AI_MATKEY_SHADER_GEO: []const u8 = "?sh.gs";
pub const AI_MATKEY_SHADER_TESSELATION: []const u8 = "?sh.ts";
pub const AI_MATKEY_SHADER_PRIMITIVE: []const u8 = "?sh.ps";
pub const AI_MATKEY_SHADER_COMPUTE: []const u8 = "?sh.cs";

// ---------------------------------------------------------------------------
// PBR material support
// --------------------
// Properties defining PBR rendering techniques
pub const AI_MATKEY_USE_COLOR_MAP: []const u8 = "$mat.useColorMap";

// Metallic/Roughness Workflow
// ---------------------------
// Base RGBA color factor. Will be multiplied by final base color texture values if extant
// Note: Importers may choose to copy this into AI_MATKEY_COLOR_DIFFUSE for compatibility
// with renderers and formats that do not support Metallic/Roughness PBR
pub const AI_MATKEY_BASE_COLOR: []const u8 = "$clr.base";
pub const AI_MATKEY_BASE_COLOR_TEXTURE: c_int = c.aiTextureType_BASE_COLOR;
pub const AI_MATKEY_USE_METALLIC_MAP: []const u8 = "$mat.useMetallicMap";
// Metallic factor. 0.0 = Full Dielectric, 1.0 = Full Metal
pub const AI_MATKEY_METALLIC_FACTOR: []const u8 = "$mat.metallicFactor";
pub const AI_MATKEY_METALLIC_TEXTURE: c_int = c.aiTextureType_METALNESS;
pub const AI_MATKEY_USE_ROUGHNESS_MAP: []const u8 = "$mat.useRoughnessMap";
// Roughness factor. 0.0 = Perfectly Smooth, 1.0 = Completely Rough
pub const AI_MATKEY_ROUGHNESS_FACTOR: []const u8 = "$mat.roughnessFactor";
pub const AI_MATKEY_ROUGHNESS_TEXTURE: c_int = c.aiTextureType_DIFFUSE_ROUGHNESS;
// Anisotropy factor. 0.0 = isotropic, 1.0 = anisotropy along tangent direction,
// -1.0 = anisotropy along bitangent direction
pub const AI_MATKEY_ANISOTROPY_FACTOR: []const u8 = "$mat.anisotropyFactor";

// Specular/Glossiness Workflow
// ---------------------------
// Diffuse/Albedo Color. Note: Pure Metals have a diffuse of {0,0,0}
// AI_MATKEY_COLOR_DIFFUSE
// Specular Color.
// Note: Metallic/Roughness may also have a Specular Color
// AI_MATKEY_COLOR_SPECULAR
pub const AI_MATKEY_SPECULAR_FACTOR: []const u8 = "$mat.specularFactor";
// Glossiness factor. 0.0 = Completely Rough, 1.0 = Perfectly Smooth
pub const AI_MATKEY_GLOSSINESS_FACTOR: []const u8 = "$mat.glossinessFactor";

// Sheen
// -----
// Sheen base RGB color. Default {0,0,0}
pub const AI_MATKEY_SHEEN_COLOR_FACTOR: []const u8 = "$clr.sheen.factor";
// Sheen Roughness Factor.
pub const AI_MATKEY_SHEEN_ROUGHNESS_FACTOR: []const u8 = "$mat.sheen.roughnessFactor";
pub const AI_MATKEY_SHEEN_COLOR_TEXTURE: c_int = c.aiTextureType_SHEEN; // , 0
pub const AI_MATKEY_SHEEN_ROUGHNESS_TEXTURE: c_int = c.aiTextureType_SHEEN; // , 1

// Clearcoat
// ---------
// Clearcoat layer intensity. 0.0 = none (disabled)
pub const AI_MATKEY_CLEARCOAT_FACTOR: []const u8 = "$mat.clearcoat.factor";
pub const AI_MATKEY_CLEARCOAT_ROUGHNESS_FACTOR: []const u8 = "$mat.clearcoat.roughnessFactor";
pub const AI_MATKEY_CLEARCOAT_TEXTURE: c_int = c.aiTextureType_CLEARCOAT; // , 0
pub const AI_MATKEY_CLEARCOAT_ROUGHNESS_TEXTURE: c_int = c.aiTextureType_CLEARCOAT; // , 1
pub const AI_MATKEY_CLEARCOAT_NORMAL_TEXTURE: c_int = c.aiTextureType_CLEARCOAT; // , 2

// Transmission
// ------------
// https://github.com/KhronosGroup/glTF/tree/master/extensions/2.0/Khronos/KHR_materials_transmission
// Base percentage of light transmitted through the surface. 0.0 = Opaque, 1.0 = Fully transparent
pub const AI_MATKEY_TRANSMISSION_FACTOR: []const u8 = "$mat.transmission.factor";
// Texture defining percentage of light transmitted through the surface.
// Multiplied by AI_MATKEY_TRANSMISSION_FACTOR
pub const AI_MATKEY_TRANSMISSION_TEXTURE: c_int = c.aiTextureType_TRANSMISSION;

// Volume
// ------------
// https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_materials_volume
// The thickness of the volume beneath the surface. If the value is 0 the material is thin-walled. Otherwise the material is a volume boundary.
pub const AI_MATKEY_VOLUME_THICKNESS_FACTOR: []const u8 = "$mat.volume.thicknessFactor";
// Texture that defines the thickness.
// Multiplied by AI_MATKEY_THICKNESS_FACTOR
pub const AI_MATKEY_VOLUME_THICKNESS_TEXTURE: c_int = c.aiTextureType_TRANSMISSION; // , 1
// Density of the medium given as the average distance that light travels in the medium before interacting with a particle.
pub const AI_MATKEY_VOLUME_ATTENUATION_DISTANCE: []const u8 = "$mat.volume.attenuationDistance";
// The color that white light turns into due to absorption when reaching the attenuation distance.
pub const AI_MATKEY_VOLUME_ATTENUATION_COLOR: []const u8 = "$mat.volume.attenuationColor";

// Emissive
// --------
pub const AI_MATKEY_USE_EMISSIVE_MAP: []const u8 = "$mat.useEmissiveMap";
pub const AI_MATKEY_EMISSIVE_INTENSITY: []const u8 = "$mat.emissiveIntensity";
pub const AI_MATKEY_USE_AO_MAP: []const u8 = "$mat.useAOMap";

// ---------------------------------------------------------------------------
// Pure key names for all texture-related properties
pub const _AI_MATKEY_TEXTURE_BASE: []const u8 = "$tex.file";
pub const _AI_MATKEY_UVWSRC_BASE: []const u8 = "$tex.uvwsrc";
pub const _AI_MATKEY_TEXOP_BASE: []const u8 = "$tex.op";
pub const _AI_MATKEY_MAPPING_BASE: []const u8 = "$tex.mapping";
pub const _AI_MATKEY_TEXBLEND_BASE: []const u8 = "$tex.blend";
pub const _AI_MATKEY_MAPPINGMODE_U_BASE: []const u8 = "$tex.mapmodeu";
pub const _AI_MATKEY_MAPPINGMODE_V_BASE: []const u8 = "$tex.mapmodev";
pub const _AI_MATKEY_TEXMAP_AXIS_BASE: []const u8 = "$tex.mapaxis";
pub const _AI_MATKEY_UVTRANSFORM_BASE: []const u8 = "$tex.uvtrafo";
pub const _AI_MATKEY_TEXFLAGS_BASE: []const u8 = "$tex.flags";
