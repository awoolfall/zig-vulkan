#include "slang_c.h"

#include <cassert>
#include <slang/slang.h>
#include <slang/slang-com-ptr.h>
#include <slang/slang-com-helper.h>

#include <vector>

struct SlangGlobal
{
    Slang::ComPtr<slang::IGlobalSession> session;
};

struct SlangGlobal* initialise()
{
    Slang::ComPtr<slang::IGlobalSession> session;
    auto res = slang::createGlobalSession(session.writeRef());

    if (SLANG_FAILED(res)) {
        return nullptr;
    }

    struct SlangGlobal* global = new struct SlangGlobal;
    global->session = session;
    return global;
}

void deinitialise(struct SlangGlobal* global)
{
    assert(global != nullptr);
    delete global;
}

struct Session
{
    Slang::ComPtr<slang::ISession> session;
};

SlangCompileTarget convert_compile_target(CompileTargets target)
{  
    switch (target) {
        case CompileTargets::TARGET_UNKNOWN: return SlangCompileTarget::SLANG_TARGET_UNKNOWN;
        case CompileTargets::TARGET_NONE: return SlangCompileTarget::SLANG_TARGET_NONE;
        case CompileTargets::TARGET_GLSL: return SlangCompileTarget::SLANG_GLSL;
        case CompileTargets::TARGET_GLSL_VULKAN_DEPRECATED: return SlangCompileTarget::SLANG_GLSL_VULKAN_DEPRECATED;
        case CompileTargets::TARGET_GLSL_VULKAN_ONE_DESC_DEPRECATED: return SlangCompileTarget::SLANG_GLSL_VULKAN_ONE_DESC_DEPRECATED;
        case CompileTargets::TARGET_HLSL: return SlangCompileTarget::SLANG_HLSL;
        case CompileTargets::TARGET_SPIRV: return SlangCompileTarget::SLANG_SPIRV;
        case CompileTargets::TARGET_SPIRV_ASM: return SlangCompileTarget::SLANG_SPIRV_ASM;
        case CompileTargets::TARGET_DXBC: return SlangCompileTarget::SLANG_DXBC;
        case CompileTargets::TARGET_DXBC_ASM: return SlangCompileTarget::SLANG_DXBC_ASM;
        case CompileTargets::TARGET_DXIL: return SlangCompileTarget::SLANG_DXIL;
        case CompileTargets::TARGET_DXIL_ASM: return SlangCompileTarget::SLANG_DXIL_ASM;
        case CompileTargets::TARGET_C_SOURCE: return SlangCompileTarget::SLANG_C_SOURCE;
        case CompileTargets::TARGET_CPP_SOURCE: return SlangCompileTarget::SLANG_CPP_SOURCE;
        case CompileTargets::TARGET_HOST_EXECUTABLE: return SlangCompileTarget::SLANG_HOST_EXECUTABLE;
        case CompileTargets::TARGET_SHADER_SHARED_LIBRARY: return SlangCompileTarget::SLANG_SHADER_SHARED_LIBRARY;
        case CompileTargets::TARGET_SHADER_HOST_CALLABLE: return SlangCompileTarget::SLANG_SHADER_HOST_CALLABLE;
        case CompileTargets::TARGET_CUDA_SOURCE: return SlangCompileTarget::SLANG_CUDA_SOURCE;
        case CompileTargets::TARGET_PTX: return SlangCompileTarget::SLANG_PTX;
        case CompileTargets::TARGET_CUDA_OBJECT_CODE: return SlangCompileTarget::SLANG_CUDA_OBJECT_CODE;
        case CompileTargets::TARGET_OBJECT_CODE: return SlangCompileTarget::SLANG_OBJECT_CODE;
        case CompileTargets::TARGET_HOST_CPP_SOURCE: return SlangCompileTarget::SLANG_HOST_CPP_SOURCE;
        case CompileTargets::TARGET_HOST_HOST_CALLABLE: return SlangCompileTarget::SLANG_HOST_HOST_CALLABLE;
        case CompileTargets::TARGET_CPP_PYTORCH_BINDING: return SlangCompileTarget::SLANG_CPP_PYTORCH_BINDING;
        case CompileTargets::TARGET_METAL: return SlangCompileTarget::SLANG_METAL;
        case CompileTargets::TARGET_METAL_LIB: return SlangCompileTarget::SLANG_METAL_LIB;
        case CompileTargets::TARGET_METAL_LIB_ASM: return SlangCompileTarget::SLANG_METAL_LIB_ASM;
        case CompileTargets::TARGET_HOST_SHARED_LIBRARY: return SlangCompileTarget::SLANG_HOST_SHARED_LIBRARY;
        case CompileTargets::TARGET_WGSL: return SlangCompileTarget::SLANG_WGSL;
        case CompileTargets::TARGET_WGSL_SPIRV_ASM: return SlangCompileTarget::SLANG_WGSL_SPIRV_ASM;
        case CompileTargets::TARGET_WGSL_SPIRV: return SlangCompileTarget::SLANG_WGSL_SPIRV;
        case CompileTargets::TARGET_TARGET_COUNT_OF: return SlangCompileTarget::SLANG_TARGET_COUNT_OF;
    }
}

slang::CompilerOptionName convert_compiler_option_name(CompilerOptionName name)
{
    switch (name) {
        case CompilerOptionName::MacroDefine: return slang::CompilerOptionName::MacroDefine;
        case CompilerOptionName::DepFile: return slang::CompilerOptionName::DepFile;
        case CompilerOptionName::EntryPointName: return slang::CompilerOptionName::EntryPointName;
        case CompilerOptionName::Specialize: return slang::CompilerOptionName::Specialize;
        case CompilerOptionName::Help: return slang::CompilerOptionName::Help;
        case CompilerOptionName::HelpStyle: return slang::CompilerOptionName::HelpStyle;
        case CompilerOptionName::Include: return slang::CompilerOptionName::Include;
        case CompilerOptionName::Language: return slang::CompilerOptionName::Language;
        case CompilerOptionName::MatrixLayoutColumn: return slang::CompilerOptionName::MatrixLayoutColumn;
        case CompilerOptionName::MatrixLayoutRow: return slang::CompilerOptionName::MatrixLayoutRow;
        case CompilerOptionName::ZeroInitialize: return slang::CompilerOptionName::ZeroInitialize;
        case CompilerOptionName::IgnoreCapabilities: return slang::CompilerOptionName::IgnoreCapabilities;
        case CompilerOptionName::RestrictiveCapabilityCheck: return slang::CompilerOptionName::RestrictiveCapabilityCheck;
        case CompilerOptionName::ModuleName: return slang::CompilerOptionName::ModuleName;
        case CompilerOptionName::Output: return slang::CompilerOptionName::Output;
        case CompilerOptionName::Profile: return slang::CompilerOptionName::Profile;
        case CompilerOptionName::Stage: return slang::CompilerOptionName::Stage;
        case CompilerOptionName::Target: return slang::CompilerOptionName::Target;
        case CompilerOptionName::Version: return slang::CompilerOptionName::Version;
        case CompilerOptionName::WarningsAsErrors: return slang::CompilerOptionName::WarningsAsErrors;
        case CompilerOptionName::DisableWarnings: return slang::CompilerOptionName::DisableWarnings;
        case CompilerOptionName::EnableWarning: return slang::CompilerOptionName::EnableWarning;
        case CompilerOptionName::DisableWarning: return slang::CompilerOptionName::DisableWarning;
        case CompilerOptionName::DumpWarningDiagnostics: return slang::CompilerOptionName::DumpWarningDiagnostics;
        case CompilerOptionName::InputFilesRemain: return slang::CompilerOptionName::InputFilesRemain;
        case CompilerOptionName::EmitIr: return slang::CompilerOptionName::EmitIr;
        case CompilerOptionName::ReportDownstreamTime: return slang::CompilerOptionName::ReportDownstreamTime;
        case CompilerOptionName::ReportPerfBenchmark: return slang::CompilerOptionName::ReportPerfBenchmark;
        case CompilerOptionName::ReportCheckpointIntermediates: return slang::CompilerOptionName::ReportCheckpointIntermediates;
        case CompilerOptionName::SkipSPIRVValidation: return slang::CompilerOptionName::SkipSPIRVValidation;
        case CompilerOptionName::SourceEmbedStyle: return slang::CompilerOptionName::SourceEmbedStyle;
        case CompilerOptionName::SourceEmbedName: return slang::CompilerOptionName::SourceEmbedName;
        case CompilerOptionName::SourceEmbedLanguage: return slang::CompilerOptionName::SourceEmbedLanguage;
        case CompilerOptionName::DisableShortCircuit: return slang::CompilerOptionName::DisableShortCircuit;
        case CompilerOptionName::MinimumSlangOptimization: return slang::CompilerOptionName::MinimumSlangOptimization;
        case CompilerOptionName::DisableNonEssentialValidations: return slang::CompilerOptionName::DisableNonEssentialValidations;
        case CompilerOptionName::DisableSourceMap: return slang::CompilerOptionName::DisableSourceMap;
        case CompilerOptionName::UnscopedEnum: return slang::CompilerOptionName::UnscopedEnum;
        case CompilerOptionName::PreserveParameters: return slang::CompilerOptionName::PreserveParameters;
        case CompilerOptionName::Capability: return slang::CompilerOptionName::Capability;
        case CompilerOptionName::DefaultImageFormatUnknown: return slang::CompilerOptionName::DefaultImageFormatUnknown;
        case CompilerOptionName::DisableDynamicDispatch: return slang::CompilerOptionName::DisableDynamicDispatch;
        case CompilerOptionName::DisableSpecialization: return slang::CompilerOptionName::DisableSpecialization;
        case CompilerOptionName::FloatingPointMode: return slang::CompilerOptionName::FloatingPointMode;
        case CompilerOptionName::DebugInformation: return slang::CompilerOptionName::DebugInformation;
        case CompilerOptionName::LineDirectiveMode: return slang::CompilerOptionName::LineDirectiveMode;
        case CompilerOptionName::Optimization: return slang::CompilerOptionName::Optimization;
        case CompilerOptionName::Obfuscate: return slang::CompilerOptionName::Obfuscate;
        case CompilerOptionName::VulkanBindShift: return slang::CompilerOptionName::VulkanBindShift;
        case CompilerOptionName::VulkanBindGlobals: return slang::CompilerOptionName::VulkanBindGlobals;
        case CompilerOptionName::VulkanInvertY: return slang::CompilerOptionName::VulkanInvertY;
        case CompilerOptionName::VulkanUseDxPositionW: return slang::CompilerOptionName::VulkanUseDxPositionW;
        case CompilerOptionName::VulkanUseEntryPointName: return slang::CompilerOptionName::VulkanUseEntryPointName;
        case CompilerOptionName::VulkanUseGLLayout: return slang::CompilerOptionName::VulkanUseGLLayout;
        case CompilerOptionName::VulkanEmitReflection: return slang::CompilerOptionName::VulkanEmitReflection;
        case CompilerOptionName::GLSLForceScalarLayout: return slang::CompilerOptionName::GLSLForceScalarLayout;
        case CompilerOptionName::EnableEffectAnnotations: return slang::CompilerOptionName::EnableEffectAnnotations;
        case CompilerOptionName::EmitSpirvViaGLSL: return slang::CompilerOptionName::EmitSpirvViaGLSL;
        case CompilerOptionName::EmitSpirvDirectly: return slang::CompilerOptionName::EmitSpirvDirectly;
        case CompilerOptionName::SPIRVCoreGrammarJSON: return slang::CompilerOptionName::SPIRVCoreGrammarJSON;
        case CompilerOptionName::IncompleteLibrary: return slang::CompilerOptionName::IncompleteLibrary;
        case CompilerOptionName::CompilerPath: return slang::CompilerOptionName::CompilerPath;
        case CompilerOptionName::DefaultDownstreamCompiler: return slang::CompilerOptionName::DefaultDownstreamCompiler;
        case CompilerOptionName::DownstreamArgs: return slang::CompilerOptionName::DownstreamArgs;
        case CompilerOptionName::PassThrough: return slang::CompilerOptionName::PassThrough;
        case CompilerOptionName::DumpRepro: return slang::CompilerOptionName::DumpRepro;
        case CompilerOptionName::DumpReproOnError: return slang::CompilerOptionName::DumpReproOnError;
        case CompilerOptionName::ExtractRepro: return slang::CompilerOptionName::ExtractRepro;
        case CompilerOptionName::LoadRepro: return slang::CompilerOptionName::LoadRepro;
        case CompilerOptionName::LoadReproDirectory: return slang::CompilerOptionName::LoadReproDirectory;
        case CompilerOptionName::ReproFallbackDirectory: return slang::CompilerOptionName::ReproFallbackDirectory;
        case CompilerOptionName::DumpAst: return slang::CompilerOptionName::DumpAst;
        case CompilerOptionName::DumpIntermediatePrefix: return slang::CompilerOptionName::DumpIntermediatePrefix;
        case CompilerOptionName::DumpIntermediates: return slang::CompilerOptionName::DumpIntermediates;
        case CompilerOptionName::DumpIr: return slang::CompilerOptionName::DumpIr;
        case CompilerOptionName::DumpIrIds: return slang::CompilerOptionName::DumpIrIds;
        case CompilerOptionName::PreprocessorOutput: return slang::CompilerOptionName::PreprocessorOutput;
        case CompilerOptionName::OutputIncludes: return slang::CompilerOptionName::OutputIncludes;
        case CompilerOptionName::ReproFileSystem: return slang::CompilerOptionName::ReproFileSystem;
        case CompilerOptionName::SerialIr: return slang::CompilerOptionName::SerialIr;
        case CompilerOptionName::SkipCodeGen: return slang::CompilerOptionName::SkipCodeGen;
        case CompilerOptionName::ValidateIr: return slang::CompilerOptionName::ValidateIr;
        case CompilerOptionName::VerbosePaths: return slang::CompilerOptionName::VerbosePaths;
        case CompilerOptionName::VerifyDebugSerialIr: return slang::CompilerOptionName::VerifyDebugSerialIr;
        case CompilerOptionName::NoCodeGen: return slang::CompilerOptionName::NoCodeGen;
        case CompilerOptionName::FileSystem: return slang::CompilerOptionName::FileSystem;
        case CompilerOptionName::Heterogeneous: return slang::CompilerOptionName::Heterogeneous;
        case CompilerOptionName::NoMangle: return slang::CompilerOptionName::NoMangle;
        case CompilerOptionName::NoHLSLBinding: return slang::CompilerOptionName::NoHLSLBinding;
        case CompilerOptionName::NoHLSLPackConstantBufferElements: return slang::CompilerOptionName::NoHLSLPackConstantBufferElements;
        case CompilerOptionName::ValidateUniformity: return slang::CompilerOptionName::ValidateUniformity;
        case CompilerOptionName::AllowGLSL: return slang::CompilerOptionName::AllowGLSL;
        case CompilerOptionName::EnableExperimentalPasses: return slang::CompilerOptionName::EnableExperimentalPasses;
        case CompilerOptionName::BindlessSpaceIndex: return slang::CompilerOptionName::BindlessSpaceIndex;
        case CompilerOptionName::ArchiveType: return slang::CompilerOptionName::ArchiveType;
        case CompilerOptionName::CompileCoreModule: return slang::CompilerOptionName::CompileCoreModule;
        case CompilerOptionName::Doc: return slang::CompilerOptionName::Doc;
        case CompilerOptionName::IrCompression: return slang::CompilerOptionName::IrCompression;
        case CompilerOptionName::LoadCoreModule: return slang::CompilerOptionName::LoadCoreModule;
        case CompilerOptionName::ReferenceModule: return slang::CompilerOptionName::ReferenceModule;
        case CompilerOptionName::SaveCoreModule: return slang::CompilerOptionName::SaveCoreModule;
        case CompilerOptionName::SaveCoreModuleBinSource: return slang::CompilerOptionName::SaveCoreModuleBinSource;
        case CompilerOptionName::TrackLiveness: return slang::CompilerOptionName::TrackLiveness;
        case CompilerOptionName::LoopInversion: return slang::CompilerOptionName::LoopInversion;
        case CompilerOptionName::ParameterBlocksUseRegisterSpaces: return slang::CompilerOptionName::ParameterBlocksUseRegisterSpaces;
        case CompilerOptionName::CountOfParsableOptions: return slang::CompilerOptionName::CountOfParsableOptions;
        case CompilerOptionName::DebugInformationFormat: return slang::CompilerOptionName::DebugInformationFormat;
        case CompilerOptionName::VulkanBindShiftAll: return slang::CompilerOptionName::VulkanBindShiftAll;
        case CompilerOptionName::GenerateWholeProgram: return slang::CompilerOptionName::GenerateWholeProgram;
        case CompilerOptionName::UseUpToDateBinaryModule: return slang::CompilerOptionName::UseUpToDateBinaryModule;
        case CompilerOptionName::EmbedDownstreamIR: return slang::CompilerOptionName::EmbedDownstreamIR;
        case CompilerOptionName::ForceDXLayout: return slang::CompilerOptionName::ForceDXLayout;
        case CompilerOptionName::EmitSpirvMethod: return slang::CompilerOptionName::EmitSpirvMethod;
        case CompilerOptionName::EmitReflectionJSON: return slang::CompilerOptionName::EmitReflectionJSON;
        case CompilerOptionName::SaveGLSLModuleBinSource: return slang::CompilerOptionName::SaveGLSLModuleBinSource;
        case CompilerOptionName::SkipDownstreamLinking: return slang::CompilerOptionName::SkipDownstreamLinking;
        case CompilerOptionName::DumpModule: return slang::CompilerOptionName::DumpModule;
        case CompilerOptionName::CountOf: return slang::CompilerOptionName::CountOf;
      break;
    }
}

slang::CompilerOptionValueKind convert_compiler_value_kind(CompilerOptionValueKind kind)
{
    switch (kind) {
    case CompilerOptionValueKind::Int: return slang::CompilerOptionValueKind::Int;
    case CompilerOptionValueKind::String: return slang::CompilerOptionValueKind::String;
    }
}

slang::CompilerOptionValue convert_compiler_option_value(CompilerOptionValue value)
{
    slang::CompilerOptionValue v;
    v.kind = convert_compiler_value_kind(value.kind);
    v.intValue0 = value.intValue0;
    v.intValue1 = value.intValue1;
    v.stringValue0 = value.stringValue0;
    v.stringValue1 = value.stringValue1;
    return v;
}

slang::CompilerOptionEntry convert_compiler_option(CompilerOption option)
{
    slang::CompilerOptionEntry opt;
    opt.name = convert_compiler_option_name(option.name);
    opt.value = convert_compiler_option_value(option.value);
    return opt;
}

Session* create_session(SlangGlobal* global, SessionCreateInfo create_info)
{
    slang::TargetDesc targetDesc = {};
    targetDesc.profile = global->session->findProfile(create_info.profile);
    if (targetDesc.profile == SlangProfileID::SLANG_PROFILE_UNKNOWN) {
        return nullptr;
    }

    targetDesc.format = convert_compile_target(create_info.compile_target);

    std::vector<slang::PreprocessorMacroDesc> preprocessor_macro_descriptions;
    preprocessor_macro_descriptions.reserve(create_info.preprocessor_macros_count);
    for (size_t i = 0; i < create_info.preprocessor_macros_count; i++) {
        slang::PreprocessorMacroDesc desc;
        desc.name = create_info.p_preprocessor_macros[i].name;
        desc.value = create_info.p_preprocessor_macros[i].value;
        preprocessor_macro_descriptions.push_back(desc);
    }

    std::vector<slang::CompilerOptionEntry> options;
    options.reserve(create_info.compile_options_count);
    for (size_t i = 0; i < create_info.compile_options_count; i++) {
        options.push_back(convert_compiler_option(create_info.p_compile_options[i]));
    }

    slang::SessionDesc sessionDesc = {};
    sessionDesc.targets = &targetDesc;
    sessionDesc.targetCount = 1;
    sessionDesc.preprocessorMacros = preprocessor_macro_descriptions.data();
    sessionDesc.preprocessorMacroCount = preprocessor_macro_descriptions.size();
    sessionDesc.compilerOptionEntries = options.data();
    sessionDesc.compilerOptionEntryCount = options.size();
    sessionDesc.searchPaths = create_info.p_search_paths;
    sessionDesc.searchPathCount = create_info.search_paths_count;
    
    Slang::ComPtr<slang::ISession> session;
    auto res = global->session->createSession(sessionDesc, session.writeRef());

    if (!session || SLANG_FAILED(res)) {
        return nullptr;
    }

    Session* s = new Session();
    s->session = session;
    return s;
}

void destroy_session(struct Session* session)
{
    assert(session != nullptr);
    delete session;
}

struct Blob
{
    Slang::ComPtr<slang::IBlob> blob;
};

struct Blob* create_blob(void)
{
    return new struct Blob;
}

void destroy_blob(struct Blob* blob)
{
    assert(blob != nullptr);
    delete blob;
}

const void* blob_get_buffer_ptr(struct Blob* blob)
{
    if (blob->blob == nullptr) { return nullptr; }
    return blob->blob->getBufferPointer();
}

uint64_t blob_get_buffer_size(struct Blob* blob)
{
    if (blob->blob == nullptr) { return 0; }
    return blob->blob->getBufferSize();
}

struct Module
{
    Slang::ComPtr<slang::IModule> module;
};

struct Module* create_and_load_module(struct Session* session, struct ModuleCreateInfo create_info)
{
    assert(session != nullptr);
    assert(create_info.module_name != nullptr);

    slang::IBlob** diagnostics_blob = nullptr;
    if (create_info.diagnostics_blob != nullptr) {
        diagnostics_blob = create_info.diagnostics_blob->blob.writeRef();
    }

    Slang::ComPtr<slang::IModule> mod;
    if (create_info.shader_source == nullptr) {
        mod = session->session->loadModule(create_info.module_name, diagnostics_blob);
    } else {
        const char* module_path = "";
        if (create_info.module_path != nullptr) { module_path = create_info.module_path; }
        mod = session->session->loadModuleFromSourceString(create_info.module_name, module_path, create_info.shader_source, diagnostics_blob);
    }

    if (!mod) {
        return nullptr;
    }

    struct Module* m = new struct Module;
    m->module = mod;
    return m;
}

void destroy_module(struct Module* module)
{
    assert(module != nullptr);
    delete module;
}

struct EntryPoint
{
    Slang::ComPtr<slang::IEntryPoint> entry_point;
};

struct EntryPoint* find_and_create_entry_point(struct Module* module, struct EntryPointCreateInfo create_info)
{
    assert(module != nullptr);
    assert(create_info.entry_point_name != nullptr);
    
    slang::IBlob** diagnostics_blob = nullptr;
    if (create_info.diagnostics_blob != nullptr) {
        diagnostics_blob = create_info.diagnostics_blob->blob.writeRef();
    }

    Slang::ComPtr<slang::IEntryPoint> entry_point;
    auto res = module->module->findEntryPointByName(create_info.entry_point_name, entry_point.writeRef());

    if (!entry_point || SLANG_FAILED(res)) {
        return nullptr;
    }

    struct EntryPoint* ep = new struct EntryPoint;
    ep->entry_point = entry_point;
    return ep;
}

void destroy_entry_point(struct EntryPoint* entry_point)
{
    assert(entry_point != nullptr);
    delete entry_point;
}

struct ComposedProgram
{
    Slang::ComPtr<slang::IComponentType> program;
};

struct ComposedProgram* create_composed_program(struct Session* session, struct ComposedProgramCreateInfo create_info)
{
    assert(session != nullptr);

    slang::IBlob** diagnostics_blob = nullptr;
    if (create_info.diagnostics_blob != nullptr) {
        diagnostics_blob = create_info.diagnostics_blob->blob.writeRef();
    }

    std::vector<slang::IComponentType*> components;
    for (size_t i = 0; i < create_info.modules_count; i++) {
        components.push_back(create_info.p_modules[i]->module);
    }
    for (size_t i = 0; i < create_info.entry_points_count; i++) {
        components.push_back(create_info.p_entry_points[i]->entry_point);
    }
    for (size_t i = 0; i < create_info.composed_programs_count; i++) {
        components.push_back(create_info.p_composed_programs[i]->program);
    }

    Slang::ComPtr<slang::IComponentType> composed_program;
    auto res = session->session->createCompositeComponentType(components.data(), components.size(), composed_program.writeRef(), diagnostics_blob);  

    if (!composed_program || SLANG_FAILED(res)) {
        return nullptr;
    }

    struct ComposedProgram* p = new struct ComposedProgram;
    p->program = composed_program;
    return p;
}

void destroy_composed_program(struct ComposedProgram* program)
{
    assert(program != nullptr);
    delete program;
}

struct LinkedProgram
{
    Slang::ComPtr<slang::IComponentType> program;
};

struct LinkedProgram* create_linked_program(struct ComposedProgram* program, struct LinkedProgramCreateInfo create_info)
{
    assert(program != nullptr);

    slang::IBlob** diagnostics_blob = nullptr;
    if (create_info.diagnostics_blob != nullptr) {
        diagnostics_blob = create_info.diagnostics_blob->blob.writeRef();
    }

    Slang::ComPtr<slang::IComponentType> linked_program;
    auto res = program->program->link(linked_program.writeRef(), diagnostics_blob);

    if (!linked_program || SLANG_FAILED(res)) {
        return nullptr;
    }

    struct LinkedProgram* lp = new struct LinkedProgram;
    lp->program = linked_program;
    return lp;
}

void destroy_linked_program(struct LinkedProgram* program)
{
    assert(program != nullptr);
    delete program;
}

bool get_entry_point_code(struct LinkedProgram* program, struct GetEntryPointCodeCreateInfo create_info)
{
    assert(program != nullptr);
    assert(create_info.output_blob != nullptr);

    slang::IBlob** diagnostics_blob = nullptr;
    if (create_info.diagnostics_blob != nullptr) {
        diagnostics_blob = create_info.diagnostics_blob->blob.writeRef();
    }

    // @TODO figure out how entry point index and target index works.
    // all examples just have them set to 0.. so we will do that here.
    auto res = program->program->getEntryPointCode(create_info.entry_point_index, 0, create_info.output_blob->blob.writeRef(), diagnostics_blob);

    return (SLANG_SUCCEEDED(res));
}

bool get_target_code(struct LinkedProgram* program, struct GetTargetCodeCreateInfo create_info)
{
    assert(program != nullptr);
    assert(create_info.output_blob != nullptr);

    slang::IBlob** diagnostics_blob = nullptr;
    if (create_info.diagnostics_blob != nullptr) {
        diagnostics_blob = create_info.diagnostics_blob->blob.writeRef();
    }

    // @TODO figure out how entry point index and target index works.
    // all examples just have them set to 0.. so we will do that here.
    auto res = program->program->getTargetCode(0, create_info.output_blob->blob.writeRef(), diagnostics_blob);

    return (SLANG_SUCCEEDED(res));
}
