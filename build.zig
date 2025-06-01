const std = @import("std");
const builtin = @import("builtin");

pub const GraphicsBackend = enum {
    Direct3D11,
    Vulkan,
    OpenGL_ES3,
    Noop,
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    //const optimize = b.standardOptimizeOption(.{});

    const os = if (target.query.os_tag) |t| t else builtin.target.os.tag;
    std.log.info("Target OS: {s}", .{@tagName(os)});

    const default_backend: GraphicsBackend = switch (os) {
        .windows => .Direct3D11,
        else => .Noop,
    };
    const graphics_backend = b.option(GraphicsBackend, "graphics_backend", "Graphics backend to use")
        orelse default_backend;
    std.log.info("Graphics backend is {}", .{graphics_backend});

    const options = b.addOptions();
    options.addOption(u32, "engine_gitrev", find_git_revision((std.Build.LazyPath { .cwd_relative = ".", }).getPath(b)));
    options.addOption(bool, "engine_gitchanged", find_git_changed((std.Build.LazyPath { .cwd_relative = ".", }).getPath(b)));
    options.addOption(GraphicsBackend, "graphics_backend", graphics_backend);
    // TODO: remove this in a distribution build
    options.addOption([]const u8, "engine_src_path", b.pathFromRoot("src"));

    const engine = b.addModule("root", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    engine.addImport("self", engine);

    // declare app module, this is imported from the super project
    engine.addImport("app", b.createModule(.{}));

    if (os == .windows) {
        const zwindows = b.dependency("zwindows", .{
        });
        engine.addImport("zwindows", zwindows.module("zwindows"));
        // const zwin32_path = zwin32.path("").getPath(b);
        // try @import("zwin32").install_xaudio2(&tests.step, .bin, zwin32_path);
        // try @import("zwin32").install_d3d12(&tests.step, .bin, zwin32_path);
        // try @import("zwin32").install_directml(&tests.step, .bin, zwin32_path);
    }

    switch (graphics_backend) {
        .Direct3D11 => {
            std.debug.assert(os == .windows);
        },
        .Vulkan => {
            const env_map = try std.process.getEnvMap(b.allocator);
            if (env_map.get("VK_SDK_PATH")) |path| {
                engine.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/Lib", .{ path }) catch @panic("OOM") });
                engine.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/Include", .{ path }) catch @panic("OOM") });
            }
        },
        .OpenGL_ES3 => {
            const zopengl = b.dependency("zopengl", .{
            });
            engine.addImport("zopengl", zopengl.module("root"));
        },
        else => {},
    }

    const zmath = b.dependency("zmath", .{
    });
    engine.addImport("zmath", zmath.module("root"));

    const zmesh = b.dependency("zmesh", .{
    });
    engine.addImport("zmesh", zmesh.module("root"));
    engine.linkLibrary(zmesh.artifact("zmesh"));

    const zphysics = b.dependency("zphysics", .{
        .use_double_precision = false,
        .enable_cross_platform_determinism = true,
        .enable_debug_renderer = true,
    });
    engine.addImport("zphysics", zphysics.module("root"));
    engine.linkLibrary(zphysics.artifact("joltc"));

    const zstbi = b.dependency("zstbi", .{
    });
    engine.addImport("zstbi", zstbi.module("root"));

    const znoise = b.dependency("znoise", .{
    });
    engine.addImport("znoise", znoise.module("root"));
    engine.linkLibrary(znoise.artifact("FastNoiseLite"));

    const assimp_module = b.dependency("assimp", .{
        .no_export = true,
    });
    engine.addImport("assimp", assimp_module.module("root"));
    engine.linkLibrary(assimp_module.artifact("assimp"));

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/tests.zig" },
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

        if (std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = argv[0..],
            .cwd = cwd,
        })) |res| {
            break :blk res.stdout;
        } else |_| {
            std.log.warn("unable to read git revision", .{});
            break :blk "0000000";
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

    if (std.process.Child.run(.{
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
