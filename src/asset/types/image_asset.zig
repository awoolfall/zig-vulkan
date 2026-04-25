const std = @import("std");
const eng = @import("self");
const zstbi = @import("zstbi");

const Self = @This();

pub const BaseType = eng.gfx.Image.Ref;
pub const Loader = Self;
pub const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".r32" };

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return Self {};
}

pub fn load(self: *Self, alloc: std.mem.Allocator, asset_uri: []const u8) !BaseType {
    _ = self;

    const file_path = try eng.util.uri.resolve_file_uri(alloc, asset_uri);
    defer alloc.free(file_path);

    var image = try eng.image.ImageLoader.load_from_file(alloc, file_path, .{});
    defer image.deinit();

    // @TODO make mip generation optional
    // generate mips down to 32 by 32
    const mip_levels: u32 = @max(std.math.log2(@min(image.width, image.height)), 5) - 4;

    return eng.gfx.Image.init(
        .{
            .height = image.height,
            .width = image.width,
            .depth = 1,
            .format = try determine_image_format(&image),
            .array_length = 1,
            .mip_levels = mip_levels,

            .usage_flags = .{ .ShaderResource = true, },
            .access_flags = .{},
            .dst_layout = .ShaderReadOnlyOptimal,
        },
        image.data,
    );
}

pub fn unload(self: *Self, asset: *BaseType) void {
    _ = self;
    asset.deinit();
}

fn determine_image_format(image: *const eng.image.Image) !eng.gfx.ImageFormat {
    return blk: {
        if (image.is_hdr) {
            switch (image.num_components) {
                1 => break :blk eng.gfx.ImageFormat.R32_Float,
                2 => break :blk eng.gfx.ImageFormat.Rg32_Float,
                4 => break :blk eng.gfx.ImageFormat.Rgba32_Float,
                else => return error.UnsupportedImageFormat,
            }
        } else {
            switch (image.num_components) {
                4 => break :blk eng.gfx.ImageFormat.Rgba8_Unorm,
                else => return error.UnsupportedImageFormat,
            }
        }
    };
}
