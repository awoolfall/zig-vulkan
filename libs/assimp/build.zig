const std = @import("std");

pub const Options = struct {
};

pub const Package = struct {
    options: Options,
    assimp: *std.Build.Module,
    assimp_options: *std.Build.Module,
    // assimp_c_cpp: *std.Build.CompileStep,

    pub fn link(pkg: Package, exe: *std.Build.CompileStep) void {
        exe.linkLibC();
        exe.addIncludePath(.{ .path = thisDir() ++ "/libs/assimp/include/" });
        exe.addLibraryPath(.{ .path = thisDir() ++ "/libs/assimp/lib/Debug/" });
        exe.linkSystemLibrary("assimp-vc143-mtd"); // TODO make this more robust
        exe.addModule("assimp", pkg.assimp);
        exe.addModule("assimp_options", pkg.assimp_options);
    }
};

pub fn package(
    b: *std.Build,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    args: struct {
        options: Options = .{},
    },
) Package {
    _ = target;
    _ = optimize;

    const step = b.addOptions();
    // step.addOption(bool, "use_double_precision", args.options.use_double_precision);
    // step.addOption(bool, "enable_asserts", args.options.enable_asserts);
    // step.addOption(bool, "enable_cross_platform_determinism", args.options.enable_cross_platform_determinism);
    // step.addOption(bool, "enable_debug_renderer", args.options.enable_debug_renderer);

    const assimp_options = step.createModule();

    const assimp = b.createModule(.{
        .source_file = .{ .path = thisDir() ++ "/src/assimp.zig" },
        .dependencies = &.{
            .{ .name = "assimp_options", .module = assimp_options },
        },
    });

    return .{
        .options = args.options,
        .assimp = assimp,
        .assimp_options = assimp_options,
    };
}

pub fn build(b: *std.Build) void {
    _ = b;
    // const optimize = b.standardOptimizeOption(.{});
    // const target = b.standardTargetOptions(.{});

    // const test_step = b.step("test", "Run zphysics tests");
    // test_step.dependOn(runTests(b, optimize, target));
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
