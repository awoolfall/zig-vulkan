#pragma once

#include <inttypes.h>
#include <stdbool.h>

#ifndef SLANGC_API
#define SLANGC_API
#endif

#if __cplusplus
extern "C" {
#endif

struct SlangGlobal;

SLANGC_API struct SlangGlobal* initialise(void);
SLANGC_API void deinitialise(struct SlangGlobal* global);

struct Session;

enum CompileTargets
{
    TARGET_UNKNOWN,
    TARGET_NONE,
    TARGET_GLSL,
    TARGET_GLSL_VULKAN_DEPRECATED,          //< deprecated and removed: just use `SLANG_GLSL`.
    TARGET_GLSL_VULKAN_ONE_DESC_DEPRECATED, //< deprecated and removed.
    TARGET_HLSL,
    TARGET_SPIRV,
    TARGET_SPIRV_ASM,
    TARGET_DXBC,
    TARGET_DXBC_ASM,
    TARGET_DXIL,
    TARGET_DXIL_ASM,
    TARGET_C_SOURCE,              ///< The C language
    TARGET_CPP_SOURCE,            ///< C++ code for shader kernels.
    TARGET_HOST_EXECUTABLE,       ///< Standalone binary executable (for hosting CPU/OS)
    TARGET_SHADER_SHARED_LIBRARY, ///< A shared library/Dll for shader kernels (for hosting
                                 ///< CPU/OS)
    TARGET_SHADER_HOST_CALLABLE,  ///< A CPU target that makes the compiled shader code available
                                 ///< to be run immediately
    TARGET_CUDA_SOURCE,           ///< Cuda source
    TARGET_PTX,                   ///< PTX
    TARGET_CUDA_OBJECT_CODE,      ///< Object code that contains CUDA functions.
    TARGET_OBJECT_CODE,           ///< Object code that can be used for later linking
    TARGET_HOST_CPP_SOURCE,       ///< C++ code for host library or executable.
    TARGET_HOST_HOST_CALLABLE,    ///< Host callable host code (ie non kernel/shader)
    TARGET_CPP_PYTORCH_BINDING,   ///< C++ PyTorch binding code.
    TARGET_METAL,                 ///< Metal shading language
    TARGET_METAL_LIB,             ///< Metal library
    TARGET_METAL_LIB_ASM,         ///< Metal library assembly
    TARGET_HOST_SHARED_LIBRARY,   ///< A shared library/Dll for host code (for hosting CPU/OS)
    TARGET_WGSL,                  ///< WebGPU shading language
    TARGET_WGSL_SPIRV_ASM,        ///< SPIR-V assembly via WebGPU shading language
    TARGET_WGSL_SPIRV,            ///< SPIR-V via WebGPU shading language
    TARGET_TARGET_COUNT_OF
};

enum CompilerOptionName
{
    MacroDefine, // stringValue0: macro name;  stringValue1: macro value
    DepFile,
    EntryPointName,
    Specialize,
    Help,
    HelpStyle,
    Include, // stringValue: additional include path.
    Language,
    MatrixLayoutColumn,         // bool
    MatrixLayoutRow,            // bool
    ZeroInitialize,             // bool
    IgnoreCapabilities,         // bool
    RestrictiveCapabilityCheck, // bool
    ModuleName,                 // stringValue0: module name.
    Output,
    Profile, // intValue0: profile
    Stage,   // intValue0: stage
    Target,  // intValue0: CodeGenTarget
    Version,
    WarningsAsErrors, // stringValue0: "all" or comma separated list of warning codes or names.
    DisableWarnings,  // stringValue0: comma separated list of warning codes or names.
    EnableWarning,    // stringValue0: warning code or name.
    DisableWarning,   // stringValue0: warning code or name.
    DumpWarningDiagnostics,
    InputFilesRemain,
    EmitIr,                        // bool
    ReportDownstreamTime,          // bool
    ReportPerfBenchmark,           // bool
    ReportCheckpointIntermediates, // bool
    SkipSPIRVValidation,           // bool
    SourceEmbedStyle,
    SourceEmbedName,
    SourceEmbedLanguage,
    DisableShortCircuit,            // bool
    MinimumSlangOptimization,       // bool
    DisableNonEssentialValidations, // bool
    DisableSourceMap,               // bool
    UnscopedEnum,                   // bool
    PreserveParameters, // bool: preserve all resource parameters in the output code.

    // Target

    Capability,                // intValue0: CapabilityName
    DefaultImageFormatUnknown, // bool
    DisableDynamicDispatch,    // bool
    DisableSpecialization,     // bool
    FloatingPointMode,         // intValue0: FloatingPointMode
    DebugInformation,          // intValue0: DebugInfoLevel
    LineDirectiveMode,
    Optimization, // intValue0: OptimizationLevel
    Obfuscate,    // bool

    VulkanBindShift, // intValue0 (higher 8 bits): kind; intValue0(lower bits): set; intValue1:
                     // shift
    VulkanBindGlobals,       // intValue0: index; intValue1: set
    VulkanInvertY,           // bool
    VulkanUseDxPositionW,    // bool
    VulkanUseEntryPointName, // bool
    VulkanUseGLLayout,       // bool
    VulkanEmitReflection,    // bool

    GLSLForceScalarLayout,   // bool
    EnableEffectAnnotations, // bool

    EmitSpirvViaGLSL,     // bool (will be deprecated)
    EmitSpirvDirectly,    // bool (will be deprecated)
    SPIRVCoreGrammarJSON, // stringValue0: json path
    IncompleteLibrary,    // bool, when set, will not issue an error when the linked program has
                          // unresolved extern function symbols.

    // Downstream

    CompilerPath,
    DefaultDownstreamCompiler,
    DownstreamArgs, // stringValue0: downstream compiler name. stringValue1: argument list, one
                    // per line.
    PassThrough,

    // Repro

    DumpRepro,
    DumpReproOnError,
    ExtractRepro,
    LoadRepro,
    LoadReproDirectory,
    ReproFallbackDirectory,

    // Debugging

    DumpAst,
    DumpIntermediatePrefix,
    DumpIntermediates, // bool
    DumpIr,            // bool
    DumpIrIds,
    PreprocessorOutput,
    OutputIncludes,
    ReproFileSystem,
    SerialIr,    // bool
    SkipCodeGen, // bool
    ValidateIr,  // bool
    VerbosePaths,
    VerifyDebugSerialIr,
    NoCodeGen, // Not used.

    // Experimental

    FileSystem,
    Heterogeneous,
    NoMangle,
    NoHLSLBinding,
    NoHLSLPackConstantBufferElements,
    ValidateUniformity,
    AllowGLSL,
    EnableExperimentalPasses,
    BindlessSpaceIndex, // int

    // Internal

    ArchiveType,
    CompileCoreModule,
    Doc,

    IrCompression, //< deprecated

    LoadCoreModule,
    ReferenceModule,
    SaveCoreModule,
    SaveCoreModuleBinSource,
    TrackLiveness,
    LoopInversion, // bool, enable loop inversion optimization

    // Deprecated
    ParameterBlocksUseRegisterSpaces,

    CountOfParsableOptions,

    // Used in parsed options only.
    DebugInformationFormat,  // intValue0: DebugInfoFormat
    VulkanBindShiftAll,      // intValue0: kind; intValue1: shift
    GenerateWholeProgram,    // bool
    UseUpToDateBinaryModule, // bool, when set, will only load
                             // precompiled modules if it is up-to-date with its source.
    EmbedDownstreamIR,       // bool
    ForceDXLayout,           // bool

    // Add this new option to the end of the list to avoid breaking ABI as much as possible.
    // Setting of EmitSpirvDirectly or EmitSpirvViaGLSL will turn into this option internally.
    EmitSpirvMethod, // enum SlangEmitSpirvMethod

    EmitReflectionJSON, // bool
    SaveGLSLModuleBinSource,

    SkipDownstreamLinking, // bool, experimental
    DumpModule,
    CountOf
};

enum CompilerOptionValueKind
{
    Int,
    String
};

struct CompilerOptionValue
{
    enum CompilerOptionValueKind kind;
    int32_t intValue0;
    int32_t intValue1;
    const char* stringValue0;
    const char* stringValue1;
};

struct PreprocessorMacro
{
    const char* name;
    const char* value;
};

struct CompilerOption
{
    enum CompilerOptionName name;
    struct CompilerOptionValue value;
};

struct SessionCreateInfo
{
    enum CompileTargets compile_target;

    const char* profile;

    struct PreprocessorMacro* p_preprocessor_macros;
    uint32_t preprocessor_macros_count;

    struct CompilerOption* p_compile_options;
    uint32_t compile_options_count;
};

SLANGC_API struct Session* create_session(struct SlangGlobal* global, struct SessionCreateInfo create_info);
SLANGC_API void destroy_session(struct Session* session);

struct Blob;

SLANGC_API struct Blob* create_blob(void);
SLANGC_API void destroy_blob(struct Blob* blob);
SLANGC_API const void* blob_get_buffer_ptr(struct Blob* blob);
SLANGC_API uint64_t blob_get_buffer_size(struct Blob* blob);

struct Module;

struct ModuleCreateInfo
{
    const char* module_name;
    const char* module_path;
    const char* shader_source; // can be nullptr to search include directories for 'module_path'
    struct Blob* diagnostics_blob; // can be nullptr
};

SLANGC_API struct Module* session_load_module(struct Session* session, struct ModuleCreateInfo create_info);
SLANGC_API void destroy_module(struct Module* module);

struct EntryPoint;

struct EntryPointCreateInfo
{
    const char* entry_point_name;
    struct Blob* diagnostics_blob; // can be nullptr
};

SLANGC_API struct EntryPoint* find_and_create_entry_point(struct Module* module, struct EntryPointCreateInfo create_info);
SLANGC_API void destroy_entry_point(struct EntryPoint* entry_point);

struct ComposedProgram;

struct ComposedProgramCreateInfo
{
    struct Module** p_modules;
    uint32_t modules_count;

    struct EntryPoint** p_entry_points;
    uint32_t entry_points_count;

    struct ComposedProgram** p_composed_programs;
    uint32_t composed_programs_count;

    struct Blob* diagnostics_blob; // can be nullptr
};

SLANGC_API struct ComposedProgram* create_composed_program(struct Session* session, struct ComposedProgramCreateInfo create_info);
SLANGC_API void destroy_composed_program(struct ComposedProgram* program);

struct LinkedProgram;

struct LinkedProgramCreateInfo
{
    struct Blob* diagnostics_blob; // can be nullptr
};

SLANGC_API struct LinkedProgram* create_linked_program(struct ComposedProgram* program, struct LinkedProgramCreateInfo create_info);
SLANGC_API void destroy_linked_program(struct LinkedProgram* program);

struct GetEntryPointCodeCreateInfo
{
    int32_t entry_point_index;
    struct Blob* output_blob;
    struct Blob* diagnostics_blob; // can be nullptr
};

SLANGC_API bool get_entry_point_code(struct LinkedProgram* program, struct GetEntryPointCodeCreateInfo create_info);

struct GetTargetCodeCreateInfo
{
    struct Blob* output_blob;
    struct Blob* diagnostics_blob; // can be nullptr
};

SLANGC_API bool get_target_code(struct LinkedProgram* program, struct GetTargetCodeCreateInfo create_info);

#if __cplusplus
}
#endif
