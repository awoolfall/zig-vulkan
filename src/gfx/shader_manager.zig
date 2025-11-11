const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const slang = @import("slang");

pub const ShaderDefineTuple = std.meta.Tuple(&[_]type{ []const u8, []const u8 });

const Self = @This();

alloc: std.mem.Allocator,
slang_global: *slang.c.SlangGlobal,

standard_modules: std.ArrayList(?*slang.c.Module),

pub fn deinit(self: *Self) void {
    for (self.standard_modules.items) |slang_module| {
        slang.c.destroy_module(slang_module);
    }
    self.standard_modules.deinit(self.alloc);

    slang.c.deinitialise(self.slang_global);
}

pub fn init() !Self {
    const slang_global = slang.c.initialise();
    if (slang_global == null) {
        return error.UnableToCreateGlobalSlang;
    }

    const alloc = eng.get().general_allocator;

    return Self {
        .alloc = alloc,
        .slang_global = slang_global.?,
        .standard_modules = try std.ArrayList(?*slang.c.Module).initCapacity(alloc, 4),
    };
}

pub const StandardModuleInfo = struct {
    module_name: []const u8,
    shader_code: []const u8,
    preprocessor_macros: []const ShaderDefineTuple = &.{},
};

pub fn add_standard_module(self: *Self, info: StandardModuleInfo) !void {
    var preproc_macro_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer preproc_macro_arena.deinit();
    const macro_alloc = preproc_macro_arena.allocator();

    const preprocessor_macros = try macro_alloc.alloc(slang.c.PreprocessorMacro, info.preprocessor_macros.len);
    defer macro_alloc.free(preprocessor_macros);

    for (info.preprocessor_macros, 0..) |m, idx| {
        preprocessor_macros[idx].name = try macro_alloc.dupeZ(u8, m[0]);
        preprocessor_macros[idx].value = try macro_alloc.dupeZ(u8, m[1]);
    }

    const session_create_info = slang.SessionCreateInfo {
        .compile_target = slang.c.TARGET_SPIRV,
        .profile = "spirv_1_3",
        .preprocessor_macros = preprocessor_macros,
        .compile_options = &.{
            //.{ .name = slang.c.VulkanUseEntryPointName, .value = .{ .kind = slang.c.Int, .intValue0 = 1, }, },
        },
        .search_paths = &.{
            "libs/engine/src/" // TODO integrate with asset manager, cant use relative throguh app /libs/engine/...
        },
    };

    const slang_session = try slang.check(slang.c.create_session(self.slang_global, session_create_info.to_slang()));
    defer slang.c.destroy_session(slang_session);

    const diagnostics_blob = try slang.check(slang.c.create_blob());
    defer slang.c.destroy_blob(diagnostics_blob);

    const shader_data_z = try self.alloc.dupeZ(u8, info.shader_data);
    defer self.alloc.free(shader_data_z);

    const module_name_z = try self.alloc.dupeZ(u8, info.module_name);
    defer self.alloc.free(module_name_z);

    const module_create_info = slang.c.ModuleCreateInfo {
        .module_name = @ptrCast(module_name_z.ptr),
        .module_path = "",
        .shader_source = @ptrCast(shader_data_z.ptr),
        .diagnostics_blob = diagnostics_blob,
    };

    const slang_module = slang.check(slang.c.create_and_load_module(slang_session, module_create_info)) catch {
        std.log.info("slang error creating module: {s}", .{slang.blob_str(diagnostics_blob)});
        return error.UnableToCreateSlangModule;
    };
    errdefer slang.c.destroy_module(slang_module);

    try self.standard_modules.append(self.alloc, slang_module);
}

pub const GenerateSpirvInfo = struct {
    shader_data: []const u8,
    shader_entry_points: []const []const u8,
    preprocessor_macros: []const ShaderDefineTuple = &.{},
};

pub fn generate_spirv(self: *const Self, alloc: std.mem.Allocator, info: GenerateSpirvInfo) ![:0]u8 {
    var preproc_macro_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer preproc_macro_arena.deinit();
    const macro_alloc = preproc_macro_arena.allocator();

    const preprocessor_macros = try macro_alloc.alloc(slang.c.PreprocessorMacro, info.preprocessor_macros.len);
    defer macro_alloc.free(preprocessor_macros);

    for (info.preprocessor_macros, 0..) |m, idx| {
        preprocessor_macros[idx].name = try macro_alloc.dupeZ(u8, m[0]);
        preprocessor_macros[idx].value = try macro_alloc.dupeZ(u8, m[1]);
    }

    const session_create_info = slang.SessionCreateInfo {
        .compile_target = slang.c.TARGET_SPIRV,
        .profile = "spirv_1_3",
        .preprocessor_macros = preprocessor_macros,
        .compile_options = &.{
            .{ .name = slang.c.VulkanUseEntryPointName, .value = .{ .kind = slang.c.Int, .intValue0 = 1, }, },
        },
        .search_paths = &.{
            "libs/engine/src/" // TODO integrate with asset manager, cant use relative throguh app /libs/engine/...
        },
    };

    const slang_session = try slang.check(slang.c.create_session(self.slang_global, session_create_info.to_slang()));
    defer slang.c.destroy_session(slang_session);

    const diagnostics_blob = try slang.check(slang.c.create_blob());
    defer slang.c.destroy_blob(diagnostics_blob);

    const shader_data_z = try self.alloc.dupeZ(u8, info.shader_data);
    defer self.alloc.free(shader_data_z);

    const module_create_info = slang.c.ModuleCreateInfo {
        .module_name = "shader",
        .module_path = "",
        .shader_source = @ptrCast(shader_data_z.ptr),
        .diagnostics_blob = diagnostics_blob,
    };

    const slang_module = slang.check(slang.c.create_and_load_module(slang_session, module_create_info)) catch {
        std.log.info("slang error creating module: {s}", .{slang.blob_str(diagnostics_blob)});
        return error.UnableToCreateSlangModule;
    };
    defer slang.c.destroy_module(slang_module);

    const entry_points = try alloc.alloc(?*slang.c.struct_EntryPoint, info.shader_entry_points.len);
    defer alloc.free(entry_points);

    var entry_points_list = std.ArrayList(?*slang.c.struct_EntryPoint).initBuffer(entry_points);
    defer for (entry_points_list.items) |ep| { slang.c.destroy_entry_point(ep); };

    for (info.shader_entry_points) |ep| {
        const entry_point_z = try self.alloc.dupeZ(u8, ep);
        defer self.alloc.free(entry_point_z);

        const entry_point_create_info = slang.c.EntryPointCreateInfo {
            .entry_point_name = @ptrCast(entry_point_z.ptr),
            .diagnostics_blob = diagnostics_blob,
        };

        const slang_entry_point = slang.check(slang.c.find_and_create_entry_point(slang_module, entry_point_create_info)) catch {
            std.log.info("slang error creating entrypoint \"{s}\": {s}", .{ep, slang.blob_str(diagnostics_blob)});
            return error.UnableToCreateSlangEntryPoint;
        };
        errdefer slang.c.destroy_entry_point(slang_entry_point);

        try entry_points_list.appendBounded(slang_entry_point);
    }

    const modules = try self.alloc.alloc(?*slang.c.Module, self.standard_modules.items.len + 1);
    defer self.alloc.free(modules);

    modules[0] = slang_module;
    for (self.standard_modules.items, 1..) |module, idx| {
        modules[idx] = module;
    }

    const composed_create_info = slang.ComposedProgramCreateInfo {
        .diagnostics_blob = diagnostics_blob,
        .modules = modules,
        .entry_points = entry_points_list.items[0..],
    };

    const composed_program = try slang.check(slang.c.create_composed_program(slang_session, composed_create_info.to_slang()));
    defer slang.c.destroy_composed_program(composed_program);

    const link_program_create_info = slang.c.LinkedProgramCreateInfo {
        .diagnostics_blob = diagnostics_blob,
    };

    const linked_program = slang.check(slang.c.create_linked_program(composed_program, link_program_create_info)) catch {
        std.log.info("slang error linking program: {s}", .{slang.blob_str(diagnostics_blob)});
        return error.UnableToLinkSlangProgram;
    };
    defer slang.c.destroy_linked_program(linked_program);

    const output_blob = slang.c.create_blob();
    defer slang.c.destroy_blob(output_blob);

    const get_target_create_info = slang.c.GetTargetCodeCreateInfo {
        .output_blob = output_blob,
        .diagnostics_blob = diagnostics_blob,
    };

    if (!slang.c.get_target_code(linked_program, get_target_create_info)) {
        std.log.info("slang error target code: {s}", .{slang.blob_str(diagnostics_blob)});
        return error.UnableToGetSlangTargetCode;
    }

    const spirv_shader_code = slang.blob_slice(output_blob);

    const owned_spirv = try alloc.dupeZ(u8, spirv_shader_code);
    errdefer alloc.free(owned_spirv);

    return owned_spirv;
}
