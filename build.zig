const std = @import("std");
const builtin = @import("builtin");

pub const GraphicsBackend = enum {
    Direct3D11,
    OpenGL,
    Noop,
};

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

    const os = if (target.query.os_tag) |t| t else builtin.target.os.tag;
    std.log.info("Target OS: {s}", .{@tagName(os)});

    const default_backend: GraphicsBackend = switch (os) {
        .windows => .Direct3D11,
        else => .Noop,
    };
    std.log.info("Defaulting to {} backend", .{default_backend});

    const options = b.addOptions();
    options.addOption(u32, "engine_gitrev", find_git_revision((std.Build.LazyPath { .path = ".", }).getPath(b)));
    options.addOption(bool, "engine_gitchanged", find_git_changed((std.Build.LazyPath { .path = ".", }).getPath(b)));
    options.addOption(GraphicsBackend, "graphics_backend", b.option(
        GraphicsBackend,
        "graphics_backend", 
        "Graphics backend to use",
    ) orelse default_backend);

    const engine = b.addModule("root", .{
        .root_source_file = .{ .path = "src/engine.zig" },
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    if (os == .windows) {
        const zwin32 = b.dependency("zwin32", .{
            .target = target,
            .optimize = optimize,
        });
        engine.addImport("zwin32", zwin32.module("root"));
        // const zwin32_path = zwin32.path("").getPath(b);
        // try @import("zwin32").install_xaudio2(&tests.step, .bin, zwin32_path);
        // try @import("zwin32").install_d3d12(&tests.step, .bin, zwin32_path);
        // try @import("zwin32").install_directml(&tests.step, .bin, zwin32_path);
    } else {
        const zopengl = b.dependency("zopengl", .{
            .target = target,
            .optimize = optimize,
        });
        engine.addImport("zopengl", zopengl.module("root"));
    }

    const zmath = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("zmath", zmath.module("root"));

    const zmesh = b.dependency("zmesh", .{
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("zmesh", zmesh.module("root"));
    engine.linkLibrary(zmesh.artifact("zmesh"));

    const zphysics = b.dependency("zphysics", .{
        .target = target,
        .optimize = optimize,

        .use_double_precision = false,
        .enable_cross_platform_determinism = true,
        .enable_debug_renderer = true,
    });
    engine.addImport("zphysics", zphysics.module("root"));
    engine.linkLibrary(zphysics.artifact("joltc"));

    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("zstbi", zstbi.module("root"));
    engine.linkLibrary(zstbi.artifact("zstbi"));

    const znoise = b.dependency("znoise", .{
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("znoise", znoise.module("root"));
    engine.linkLibrary(znoise.artifact("FastNoiseLite"));

    const assimp_module = b.dependency("assimp", .{
        .target = target,
        .optimize = optimize,
        
        .no_export = true,
    });
    engine.addImport("assimp", assimp_module.module("root"));
    engine.linkLibrary(assimp_module.artifact("assimp"));

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

fn find_git_revision(cwd: []const u8) u32 {
    const gitrev_s = blk: {
        const argv = [_][]const u8{ "git", "rev-parse", "--short", "HEAD" };

        if (std.ChildProcess.run(.{
            .allocator = std.heap.page_allocator,
            .argv = argv[0..],
            .cwd = cwd,
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

fn find_git_changed(cwd: []const u8) bool {
    const argv = [_][]const u8{ "git", "diff", "--exit-code", "--quiet" };

    if (std.ChildProcess.run(.{
        .allocator = std.heap.page_allocator,
        .argv = argv[0..],
        .cwd = cwd,
    })) |res| {
        switch (res.term) {
            .Exited => |v| { return v == 1; },
            else => { return true; },
        }
    } else |_| {
        std.log.warn("unable to read git changed", .{});
        return true;
    }
}
