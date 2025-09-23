const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{
        .shared = b.option(
            bool,
            "shared",
            "Build Slang as shared lib",
        ) orelse false,
    };

    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }

    const slang = b.addModule("root", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    slang.addIncludePath(b.path("cpp"));

    const slangc = if (options.shared) blk: {
        const lib = b.addLibrary(.{
            .linkage = .static,
            .name = "slang",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        if (target.result.os.tag == .windows) {
            lib.root_module.addCMacro("SLANGC_API", "extern __declspec(dllexport)");
        }
        break :blk lib;
    } else b.addLibrary(.{
        .linkage = .static,
        .name = "slang",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(slangc);

    slangc.linkLibC();
    slangc.linkLibCpp();

    const env_map = try std.process.getEnvMap(b.allocator);
    if (env_map.get("VK_SDK_PATH")) |path| {
        slangc.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/Lib", .{ path }) catch @panic("OOM") });
        slangc.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/Include", .{ path }) catch @panic("OOM") });
    }
    slangc.linkSystemLibrary("slang");

    const src_dir = "cpp";
    const c_flags = &.{
        "-std=c++17",
        //if (options.no_exceptions) "-fno-exceptions" else "",
        "-fno-access-control",
        "-fno-sanitize=undefined",
    };

    slangc.addCSourceFiles(.{
        .files = &.{
            src_dir ++ "/slang_c.cpp",
        },
        .flags = c_flags,
    });

    //
    // // Creates a step for unit testing. This only builds the test executable
    // // but does not run it.
    // const lib_unit_tests = b.addTest(.{
    //     .root_module = lib_mod,
    // });
    //
    // const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    //
    // const exe_unit_tests = b.addTest(.{
    //     .root_module = exe_mod,
    // });
    //
    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    //
    // // Similar to creating the run step earlier, this exposes a `test` step to
    // // the `zig build --help` menu, providing a way for the user to request
    // // running the unit tests.
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_lib_unit_tests.step);
    // test_step.dependOn(&run_exe_unit_tests.step);
}
