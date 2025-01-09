const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = .{
        .no_export = b.option(
            bool,
            "no_export",
            "Disable exporting",
        ) orelse false,
        // .use_double_precision = b.option(
        //     bool,
        //     "use_double_precision",
        //     "Enable double precision",
        // ) orelse false,
        // .enable_asserts = b.option(
        //     bool,
        //     "enable_asserts",
        //     "Enable assertions",
        // ) orelse (optimize == .Debug),
        // .enable_cross_platform_determinism = b.option(
        //     bool,
        //     "enable_cross_platform_determinism",
        //     "Enables cross-platform determinism",
        // ) orelse true,
        // .enable_debug_renderer = b.option(
        //     bool,
        //     "enable_debug_renderer",
        //     "Enable debug renderer",
        // ) orelse false,
    };

    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }

    const options_module = options_step.createModule();

    const assimp_module = b.addModule("root", .{
        .root_source_file = b.path("src/assimp.zig"),
        .imports = &.{
            .{ .name = "assimp_options", .module = options_module },
        },
    });
    assimp_module.addIncludePath(b.path("libs/assimp/include"));

    const unzip = b.addStaticLibrary(.{
        .name = "unzip",
        .target = target,
        .optimize = optimize,
    });

    const zlib_conf_step = b.addConfigHeader(.{ 
        .style = .{ .cmake = b.path("libs/assimp/contrib/zlib/zconf.h.in") },
    }, .{});
    unzip.addConfigHeader(zlib_conf_step);
    unzip.installConfigHeader(zlib_conf_step);

    unzip.addIncludePath(b.path("libs/assimp/contrib/unzip"));
    unzip.addIncludePath(b.path("libs/assimp/contrib/zlib"));
    unzip.linkLibC();
    unzip.linkLibCpp();
    unzip.addCSourceFiles(.{
        .files = &.{
            "libs/assimp/contrib/unzip/ioapi.c",
            "libs/assimp/contrib/unzip/unzip.c",
            "libs/assimp/contrib/zlib/adler32.c",
            "libs/assimp/contrib/zlib/compress.c",
            "libs/assimp/contrib/zlib/crc32.c",
            "libs/assimp/contrib/zlib/deflate.c",
            "libs/assimp/contrib/zlib/gzclose.c",
            "libs/assimp/contrib/zlib/gzlib.c",
            "libs/assimp/contrib/zlib/gzread.c",
            "libs/assimp/contrib/zlib/gzwrite.c",
            "libs/assimp/contrib/zlib/infback.c",
            "libs/assimp/contrib/zlib/inffast.c",
            "libs/assimp/contrib/zlib/inflate.c",
            "libs/assimp/contrib/zlib/inftrees.c",
            "libs/assimp/contrib/zlib/trees.c",
            "libs/assimp/contrib/zlib/uncompr.c",
            "libs/assimp/contrib/zlib/zutil.c",
        },
        .flags = &.{
            "-fno-access-control",
            "-fno-sanitize=undefined",
        },
    });

    const zip = b.addStaticLibrary(.{
        .name = "zip",
        .target = target,
        .optimize = optimize,
    });

    zip.addIncludePath(b.path("libs/assimp/contrib/zip/src"));
    zip.linkLibC();
    zip.linkLibCpp();
    zip.root_module.addCMacro("MINIZ_USE_UNALIGNED_LOADS_AND_STORES", "0");
    zip.addCSourceFiles(.{
        .files = &.{
            "libs/assimp/contrib/zip/src/zip.c",
        },
        .flags = &.{
            //"-std=c++17",
            "-fno-access-control",
            "-fno-sanitize=undefined",
        },
    });

    const pugixml = b.addStaticLibrary(.{
        .name = "pugixml",
        .target = target,
        .optimize = optimize,
    });

    pugixml.addIncludePath(b.path("libs/assimp/contrib/pugixml/src"));
    pugixml.linkLibC();
    pugixml.linkLibCpp();
    pugixml.addCSourceFiles(.{
        .files = &.{
            "libs/assimp/contrib/pugixml/src/pugixml.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-fno-access-control",
            "-fno-sanitize=undefined",
        },
    });

    const openddlparser = b.addStaticLibrary(.{
        .name = "openddlparser",
        .target = target,
        .optimize = optimize,
    });

    openddlparser.addIncludePath(b.path("libs/assimp/contrib/openddlparser/code"));
    openddlparser.addIncludePath(b.path("libs/assimp/contrib/openddlparser/include"));
    openddlparser.linkLibC();
    openddlparser.linkLibCpp();
    openddlparser.root_module.addCMacro("OPENDDLPARSER_BUILD", "1");
    openddlparser.addCSourceFiles(.{
        .files = &.{
            "libs/assimp/contrib/openddlparser/code/DDLNode.cpp",
            "libs/assimp/contrib/openddlparser/code/OpenDDLCommon.cpp",
            "libs/assimp/contrib/openddlparser/code/OpenDDLExport.cpp",
            "libs/assimp/contrib/openddlparser/code/OpenDDLParser.cpp",
            "libs/assimp/contrib/openddlparser/code/OpenDDLStream.cpp",
            "libs/assimp/contrib/openddlparser/code/Value.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-fno-access-control",
            "-fno-sanitize=undefined",
        },
    });

    const cencode = b.addStaticLibrary(.{
        .name = "cencode",
        .target = target,
        .optimize = optimize,
    });

    cencode.addIncludePath(b.path("libs/assimp/code/AssetLib/Assjson/"));
    cencode.linkLibC();
    cencode.addCSourceFiles(.{
        .files = &.{
            "libs/assimp/code/AssetLib/Assjson/cencode.c",
        },
        .flags = &.{
            "-fno-access-control",
            "-fno-sanitize=undefined",
        },
    });

    const poly2tri = b.addStaticLibrary(.{
        .name = "poly2tri",
        .target = target,
        .optimize = optimize,
    });

    poly2tri.addIncludePath(b.path("libs/assimp/contrib/poly2tri"));
    poly2tri.linkLibC();
    poly2tri.linkLibCpp();
    poly2tri.addCSourceFiles(.{
        .files = &.{
            "libs/assimp/contrib/poly2tri/poly2tri/common/shapes.cc",
            "libs/assimp/contrib/poly2tri/poly2tri/sweep/advancing_front.cc",
            "libs/assimp/contrib/poly2tri/poly2tri/sweep/cdt.cc",
            "libs/assimp/contrib/poly2tri/poly2tri/sweep/sweep.cc",
            "libs/assimp/contrib/poly2tri/poly2tri/sweep/sweep_context.cc",
        },
        .flags = &.{
            "-std=c++17",
            "-fno-access-control",
            "-fno-sanitize=undefined",
        },
    });

    const assimp = b.addStaticLibrary(.{
        .name = "assimp",
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(assimp);

    const assimp_conf_step = b.addConfigHeader(.{ 
        .style = .{ .cmake = b.path("libs/assimp/include/assimp/config.h.in") },
        .include_path = "assimp/config.h",
    }, .{});
    assimp.addConfigHeader(assimp_conf_step);
    assimp_module.addConfigHeader(assimp_conf_step);

    const assimp_rev_step = b.addConfigHeader(
        .{ 
            .style = .{ .cmake = b.path("libs/assimp/revision.h.in") },
        }, 
        .{
            .GIT_COMMIT_HASH = 0,
            .GIT_BRANCH = "",
            .ASSIMP_VERSION_MAJOR = 5,
            .ASSIMP_VERSION_MINOR = 3,
            .ASSIMP_VERSION_PATCH = 0,
            .ASSIMP_PACKAGE_VERSION = 0,
            .CMAKE_SHARED_LIBRARY_PREFIX = "",
            .LIBRARY_SUFFIX = "",
            .CMAKE_DEBUG_POSTFIX = "",
        }
    );
    assimp.addConfigHeader(assimp_rev_step);

    assimp.linkLibrary(unzip);
    assimp.linkLibrary(zip);
    assimp.linkLibrary(cencode);
    assimp.linkLibrary(poly2tri);
    assimp.linkLibrary(pugixml);
    assimp.linkLibrary(openddlparser);

    assimp.addIncludePath(b.path("libs/assimp/include"));
    assimp.addIncludePath(b.path("libs/assimp/include/assimp"));
    assimp.addIncludePath(b.path("libs/assimp/code"));
    assimp.addIncludePath(b.path("libs/assimp/"));
    assimp.addIncludePath(b.path("libs/assimp/contrib/zlib"));
    assimp.addIncludePath(b.path("libs/assimp/contrib/unzip"));
    assimp.addIncludePath(b.path("libs/assimp/contrib/rapidjson/include"));
    assimp.addIncludePath(b.path("libs/assimp/contrib/openddlparser/include"));
    assimp.addIncludePath(b.path("libs/assimp/contrib/utf8cpp/source"));
    assimp.addIncludePath(b.path("libs/assimp/contrib/pugixml/src"));
    assimp.addIncludePath(b.path("libs/assimp/contrib/poly2tri"));
    assimp.addIncludePath(b.path("libs/assimp/contrib"));
    assimp.root_module.addCMacro("RAPIDJSON_HAS_STDSTRING", "1");
    assimp.root_module.addCMacro("ASSIMP_BUILD_NO_C4D_IMPORTER", "1");
    assimp.root_module.addCMacro("ASSIMP_BUILD_NO_IFC_IMPORTER", "1");
    assimp.root_module.addCMacro("ASSIMP_BUILD_NO_M3D_IMPORTER", "1");
    assimp.root_module.addCMacro("ASSIMP_BUILD_NO_M3D_EXPORTER", "1");
    assimp.root_module.addCMacro("OPENDDLPARSER_BUILD", "1");
    assimp.root_module.addCMacro("STB_USE_HUNTER", "0");
    assimp.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "1");

    if (options.no_export) assimp.root_module.addCMacro("ASSIMP_BUILD_NO_EXPORT", "1");

    assimp.linkLibC();
    assimp.linkLibCpp();

    const src_dir = "libs/assimp/code";
    const contrib_dir = "libs/assimp/contrib";
    _ = contrib_dir;
    assimp.addCSourceFiles(.{
        .files = &.{
            src_dir ++ "/AssetLib/3DS/3DSConverter.cpp",
            src_dir ++ "/AssetLib/3DS/3DSExporter.cpp",
            src_dir ++ "/AssetLib/3DS/3DSLoader.cpp",
            src_dir ++ "/AssetLib/3MF/D3MFExporter.cpp",
            src_dir ++ "/AssetLib/3MF/D3MFImporter.cpp",
            src_dir ++ "/AssetLib/3MF/D3MFOpcPackage.cpp",
            src_dir ++ "/AssetLib/3MF/XmlSerializer.cpp",
            src_dir ++ "/AssetLib/AC/ACLoader.cpp",
            src_dir ++ "/AssetLib/AMF/AMFImporter.cpp",
            src_dir ++ "/AssetLib/AMF/AMFImporter_Geometry.cpp",
            src_dir ++ "/AssetLib/AMF/AMFImporter_Material.cpp",
            src_dir ++ "/AssetLib/AMF/AMFImporter_Postprocess.cpp",
            src_dir ++ "/AssetLib/ASE/ASELoader.cpp",
            src_dir ++ "/AssetLib/ASE/ASEParser.cpp",
            src_dir ++ "/AssetLib/Assbin/AssbinExporter.cpp",
            src_dir ++ "/AssetLib/Assbin/AssbinFileWriter.cpp",
            src_dir ++ "/AssetLib/Assbin/AssbinLoader.cpp",
            src_dir ++ "/AssetLib/Assjson/json_exporter.cpp",
            src_dir ++ "/AssetLib/Assjson/mesh_splitter.cpp",
            src_dir ++ "/AssetLib/Assxml/AssxmlExporter.cpp",
            src_dir ++ "/AssetLib/Assxml/AssxmlFileWriter.cpp",
            src_dir ++ "/AssetLib/B3D/B3DImporter.cpp",
            src_dir ++ "/AssetLib/Blender/BlenderBMesh.cpp",
            src_dir ++ "/AssetLib/Blender/BlenderCustomData.cpp",
            src_dir ++ "/AssetLib/Blender/BlenderDNA.cpp",
            src_dir ++ "/AssetLib/Blender/BlenderLoader.cpp",
            src_dir ++ "/AssetLib/Blender/BlenderModifier.cpp",
            src_dir ++ "/AssetLib/Blender/BlenderScene.cpp",
            src_dir ++ "/AssetLib/Blender/BlenderTessellator.cpp",
            src_dir ++ "/AssetLib/BVH/BVHLoader.cpp",
            // src_dir ++ "/AssetLib/C4D/C4DImporter.cpp",
            src_dir ++ "/AssetLib/COB/COBLoader.cpp",
            src_dir ++ "/AssetLib/Collada/ColladaExporter.cpp",
            src_dir ++ "/AssetLib/Collada/ColladaHelper.cpp",
            src_dir ++ "/AssetLib/Collada/ColladaLoader.cpp",
            src_dir ++ "/AssetLib/Collada/ColladaParser.cpp",
            src_dir ++ "/AssetLib/CSM/CSMLoader.cpp",
            src_dir ++ "/AssetLib/DXF/DXFLoader.cpp",
            src_dir ++ "/AssetLib/FBX/FBXAnimation.cpp",
            src_dir ++ "/AssetLib/FBX/FBXBinaryTokenizer.cpp",
            src_dir ++ "/AssetLib/FBX/FBXConverter.cpp",
            src_dir ++ "/AssetLib/FBX/FBXDeformer.cpp",
            src_dir ++ "/AssetLib/FBX/FBXDocument.cpp",
            src_dir ++ "/AssetLib/FBX/FBXDocumentUtil.cpp",
            src_dir ++ "/AssetLib/FBX/FBXExporter.cpp",
            src_dir ++ "/AssetLib/FBX/FBXExportNode.cpp",
            src_dir ++ "/AssetLib/FBX/FBXExportProperty.cpp",
            src_dir ++ "/AssetLib/FBX/FBXImporter.cpp",
            src_dir ++ "/AssetLib/FBX/FBXMaterial.cpp",
            src_dir ++ "/AssetLib/FBX/FBXMeshGeometry.cpp",
            src_dir ++ "/AssetLib/FBX/FBXModel.cpp",
            src_dir ++ "/AssetLib/FBX/FBXNodeAttribute.cpp",
            src_dir ++ "/AssetLib/FBX/FBXParser.cpp",
            src_dir ++ "/AssetLib/FBX/FBXProperties.cpp",
            src_dir ++ "/AssetLib/FBX/FBXTokenizer.cpp",
            src_dir ++ "/AssetLib/FBX/FBXUtil.cpp",
            src_dir ++ "/AssetLib/glTF/glTFCommon.cpp",
            src_dir ++ "/AssetLib/glTF/glTFExporter.cpp",
            src_dir ++ "/AssetLib/glTF/glTFImporter.cpp",
            src_dir ++ "/AssetLib/glTF2/glTF2Exporter.cpp",
            src_dir ++ "/AssetLib/glTF2/glTF2Importer.cpp",
            src_dir ++ "/AssetLib/HMP/HMPLoader.cpp",
            src_dir ++ "/AssetLib/IFC/IFCBoolean.cpp",
            src_dir ++ "/AssetLib/IFC/IFCCurve.cpp",
            src_dir ++ "/AssetLib/IFC/IFCGeometry.cpp",
            src_dir ++ "/AssetLib/IFC/IFCLoader.cpp",
            src_dir ++ "/AssetLib/IFC/IFCMaterial.cpp",
            src_dir ++ "/AssetLib/IFC/IFCOpenings.cpp",
            src_dir ++ "/AssetLib/IFC/IFCProfile.cpp",
            src_dir ++ "/AssetLib/IFC/IFCReaderGen1_2x3.cpp",
            src_dir ++ "/AssetLib/IFC/IFCReaderGen2_2x3.cpp",
            src_dir ++ "/AssetLib/IFC/IFCReaderGen_4.cpp",
            src_dir ++ "/AssetLib/IFC/IFCUtil.cpp",
            src_dir ++ "/AssetLib/IQM/IQMImporter.cpp",
            src_dir ++ "/AssetLib/Irr/IRRLoader.cpp",
            src_dir ++ "/AssetLib/Irr/IRRMeshLoader.cpp",
            src_dir ++ "/AssetLib/Irr/IRRShared.cpp",
            src_dir ++ "/AssetLib/LWO/LWOAnimation.cpp",
            src_dir ++ "/AssetLib/LWO/LWOBLoader.cpp",
            src_dir ++ "/AssetLib/LWO/LWOLoader.cpp",
            src_dir ++ "/AssetLib/LWO/LWOMaterial.cpp",
            src_dir ++ "/AssetLib/LWS/LWSLoader.cpp",
            src_dir ++ "/AssetLib/M3D/M3DExporter.cpp",
            src_dir ++ "/AssetLib/M3D/M3DImporter.cpp",
            src_dir ++ "/AssetLib/M3D/M3DWrapper.cpp",
            src_dir ++ "/AssetLib/MD2/MD2Loader.cpp",
            src_dir ++ "/AssetLib/MD3/MD3Loader.cpp",
            src_dir ++ "/AssetLib/MD5/MD5Loader.cpp",
            src_dir ++ "/AssetLib/MD5/MD5Parser.cpp",
            src_dir ++ "/AssetLib/MDC/MDCLoader.cpp",
            src_dir ++ "/AssetLib/MDL/HalfLife/HL1MDLLoader.cpp",
            src_dir ++ "/AssetLib/MDL/HalfLife/UniqueNameGenerator.cpp",
            src_dir ++ "/AssetLib/MDL/MDLLoader.cpp",
            src_dir ++ "/AssetLib/MDL/MDLMaterialLoader.cpp",
            src_dir ++ "/AssetLib/MMD/MMDImporter.cpp",
            src_dir ++ "/AssetLib/MMD/MMDPmxParser.cpp",
            src_dir ++ "/AssetLib/MS3D/MS3DLoader.cpp",
            src_dir ++ "/AssetLib/NDO/NDOLoader.cpp",
            src_dir ++ "/AssetLib/NFF/NFFLoader.cpp",
            src_dir ++ "/AssetLib/Obj/ObjExporter.cpp",
            src_dir ++ "/AssetLib/Obj/ObjFileImporter.cpp",
            src_dir ++ "/AssetLib/Obj/ObjFileMtlImporter.cpp",
            src_dir ++ "/AssetLib/Obj/ObjFileParser.cpp",
            src_dir ++ "/AssetLib/OFF/OFFLoader.cpp",
            src_dir ++ "/AssetLib/Ogre/OgreBinarySerializer.cpp",
            src_dir ++ "/AssetLib/Ogre/OgreImporter.cpp",
            src_dir ++ "/AssetLib/Ogre/OgreMaterial.cpp",
            src_dir ++ "/AssetLib/Ogre/OgreStructs.cpp",
            src_dir ++ "/AssetLib/Ogre/OgreXmlSerializer.cpp",
            src_dir ++ "/AssetLib/OpenGEX/OpenGEXExporter.cpp",
            src_dir ++ "/AssetLib/OpenGEX/OpenGEXImporter.cpp",
            src_dir ++ "/AssetLib/Ply/PlyExporter.cpp",
            src_dir ++ "/AssetLib/Ply/PlyLoader.cpp",
            src_dir ++ "/AssetLib/Ply/PlyParser.cpp",
            src_dir ++ "/AssetLib/Q3BSP/Q3BSPFileImporter.cpp",
            src_dir ++ "/AssetLib/Q3BSP/Q3BSPFileParser.cpp",
            src_dir ++ "/AssetLib/Q3D/Q3DLoader.cpp",
            src_dir ++ "/AssetLib/Raw/RawLoader.cpp",
            src_dir ++ "/AssetLib/SIB/SIBImporter.cpp",
            src_dir ++ "/AssetLib/SMD/SMDLoader.cpp",
            src_dir ++ "/AssetLib/Step/StepExporter.cpp",
            src_dir ++ "/AssetLib/STEPParser/STEPFileEncoding.cpp",
            src_dir ++ "/AssetLib/STEPParser/STEPFileReader.cpp",
            src_dir ++ "/AssetLib/STL/STLExporter.cpp",
            src_dir ++ "/AssetLib/STL/STLLoader.cpp",
            src_dir ++ "/AssetLib/Terragen/TerragenLoader.cpp",
            src_dir ++ "/AssetLib/Unreal/UnrealLoader.cpp",
            src_dir ++ "/AssetLib/X/XFileExporter.cpp",
            src_dir ++ "/AssetLib/X/XFileImporter.cpp",
            src_dir ++ "/AssetLib/X/XFileParser.cpp",
            src_dir ++ "/AssetLib/X3D/X3DExporter.cpp",
            src_dir ++ "/AssetLib/X3D/X3DGeoHelper.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Geometry2D.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Geometry3D.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Group.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Light.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Metadata.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Networking.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Postprocess.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Rendering.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Shape.cpp",
            src_dir ++ "/AssetLib/X3D/X3DImporter_Texturing.cpp",
            src_dir ++ "/AssetLib/X3D/X3DXmlHelper.cpp",
            src_dir ++ "/AssetLib/XGL/XGLLoader.cpp",
            src_dir ++ "/CApi/AssimpCExport.cpp",
            src_dir ++ "/CApi/CInterfaceIOWrapper.cpp",
            src_dir ++ "/Common/AssertHandler.cpp",
            src_dir ++ "/Common/Assimp.cpp",
            src_dir ++ "/Common/Base64.cpp",
            src_dir ++ "/Common/BaseImporter.cpp",
            src_dir ++ "/Common/BaseProcess.cpp",
            src_dir ++ "/Common/Bitmap.cpp",
            src_dir ++ "/Common/Compression.cpp",
            src_dir ++ "/Common/CreateAnimMesh.cpp",
            src_dir ++ "/Common/DefaultIOStream.cpp",
            src_dir ++ "/Common/DefaultIOSystem.cpp",
            src_dir ++ "/Common/DefaultLogger.cpp",
            src_dir ++ "/Common/Exceptional.cpp",
            src_dir ++ "/Common/Exporter.cpp",
            src_dir ++ "/Common/Importer.cpp",
            src_dir ++ "/Common/ImporterRegistry.cpp",
            src_dir ++ "/Common/IOSystem.cpp",
            src_dir ++ "/Common/material.cpp",
            src_dir ++ "/Common/PostStepRegistry.cpp",
            src_dir ++ "/Common/RemoveComments.cpp",
            src_dir ++ "/Common/scene.cpp",
            src_dir ++ "/Common/SceneCombiner.cpp",
            src_dir ++ "/Common/ScenePreprocessor.cpp",
            src_dir ++ "/Common/SGSpatialSort.cpp",
            src_dir ++ "/Common/simd.cpp",
            src_dir ++ "/Common/SkeletonMeshBuilder.cpp",
            src_dir ++ "/Common/SpatialSort.cpp",
            src_dir ++ "/Common/StandardShapes.cpp",
            src_dir ++ "/Common/Subdivision.cpp",
            src_dir ++ "/Common/TargetAnimation.cpp",
            src_dir ++ "/Common/Version.cpp",
            src_dir ++ "/Common/VertexTriangleAdjacency.cpp",
            src_dir ++ "/Common/ZipArchiveIOSystem.cpp",
            src_dir ++ "/Geometry/GeometryUtils.cpp",
            src_dir ++ "/Material/MaterialSystem.cpp",
            src_dir ++ "/Pbrt/PbrtExporter.cpp",
            src_dir ++ "/PostProcessing/ArmaturePopulate.cpp",
            src_dir ++ "/PostProcessing/CalcTangentsProcess.cpp",
            src_dir ++ "/PostProcessing/ComputeUVMappingProcess.cpp",
            src_dir ++ "/PostProcessing/ConvertToLHProcess.cpp",
            src_dir ++ "/PostProcessing/DeboneProcess.cpp",
            src_dir ++ "/PostProcessing/DropFaceNormalsProcess.cpp",
            src_dir ++ "/PostProcessing/EmbedTexturesProcess.cpp",
            src_dir ++ "/PostProcessing/FindDegenerates.cpp",
            src_dir ++ "/PostProcessing/FindInstancesProcess.cpp",
            src_dir ++ "/PostProcessing/FindInvalidDataProcess.cpp",
            src_dir ++ "/PostProcessing/FixNormalsStep.cpp",
            src_dir ++ "/PostProcessing/GenBoundingBoxesProcess.cpp",
            src_dir ++ "/PostProcessing/GenFaceNormalsProcess.cpp",
            src_dir ++ "/PostProcessing/GenVertexNormalsProcess.cpp",
            src_dir ++ "/PostProcessing/ImproveCacheLocality.cpp",
            src_dir ++ "/PostProcessing/JoinVerticesProcess.cpp",
            src_dir ++ "/PostProcessing/LimitBoneWeightsProcess.cpp",
            src_dir ++ "/PostProcessing/MakeVerboseFormat.cpp",
            src_dir ++ "/PostProcessing/OptimizeGraph.cpp",
            src_dir ++ "/PostProcessing/OptimizeMeshes.cpp",
            src_dir ++ "/PostProcessing/PretransformVertices.cpp",
            src_dir ++ "/PostProcessing/ProcessHelper.cpp",
            src_dir ++ "/PostProcessing/RemoveRedundantMaterials.cpp",
            src_dir ++ "/PostProcessing/RemoveVCProcess.cpp",
            src_dir ++ "/PostProcessing/ScaleProcess.cpp",
            src_dir ++ "/PostProcessing/SortByPTypeProcess.cpp",
            src_dir ++ "/PostProcessing/SplitByBoneCountProcess.cpp",
            src_dir ++ "/PostProcessing/SplitLargeMeshes.cpp",
            src_dir ++ "/PostProcessing/TextureTransform.cpp",
            src_dir ++ "/PostProcessing/TriangulateProcess.cpp",
            src_dir ++ "/PostProcessing/ValidateDataStructure.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-fno-access-control",
            "-fno-sanitize=undefined",
        },
    });
}

