const std = @import("std");

const zwin32 = @import("libs/zig-gamedev/libs/zwin32/build.zig");
const zmath = @import("libs/zig-gamedev/libs/zmath/build.zig");
const zmesh = @import("libs/zig-gamedev/libs/zmesh/build.zig");
const zphysics = @import("libs/zig-gamedev/libs/zphysics/build.zig");
const zstbi = @import("libs/zig-gamedev/libs/zstbi/build.zig");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig_dx11",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const options = b.addOptions();
    options.addOption(u32, "gitrev", find_git_revision());

    exe.addOptions("build_options", options);

    // This *creates* a RunStep in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const zwin32_pkg = zwin32.package(b, target, optimize, .{});
    zwin32_pkg.link(exe, .{ 
        .d3d12 = true, 
        .xaudio2 = false, 
        .directml = false 
    });

    const zmath_pkg = zmath.package(b, target, optimize, .{});
    zmath_pkg.link(exe);

    const zmesh_pkg = zmesh.package(b, target, optimize, .{});
    zmesh_pkg.link(exe);

    const zphysics_pkg = zphysics.package(b, target, optimize, .{
        .options = .{
            .use_double_precision = false,
            .enable_cross_platform_determinism = true,
            .enable_debug_renderer = true,
        }
    });
    zphysics_pkg.link(exe);

    const zstbi_pkg = zstbi.package(b, target, optimize, .{});
    zstbi_pkg.link(exe);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn find_git_revision() u32 {
    const gitrev_s = blk: {
        const argv = [_][]const u8{ "git", "rev-parse", "--short", "HEAD" };

        if (std.ChildProcess.run(.{
            .allocator = std.heap.page_allocator,
            .argv = argv[0..],
        })) |res| {
            break :blk res.stdout;
        } else |_| {
            std.log.warn("unable to read git revision", .{});
            break :blk "0";
        }
    };

    var gitrev: u32 = 0;
    if (std.fmt.parseUnsigned(u32, gitrev_s[0..7], 16)) |g| {
        gitrev = g;
    } else |e| {std.log.err("e {}", .{e});}

    return gitrev;
}
