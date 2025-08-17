const std = @import("std");
const stbi = @import("zstbi");
const path = @import("path.zig");

pub const Image = struct {
    alloc: std.mem.Allocator,
    data: []u8,
    width: u32,
    height: u32,
    num_components: u32,
    bytes_per_component: u32,
    bytes_per_row: u32,
    is_hdr: bool,

    pub fn deinit(self: *Image) void {
        self.alloc.free(self.data);
    }

    pub fn to_zstbi(self: *const Image) !stbi.Image {
        const zstbi_image = try stbi.Image.createEmpty(
            self.width,
            self.height,
            self.num_components,
            .{
                .bytes_per_component = self.bytes_per_component,
                .bytes_per_row = self.bytes_per_row,
            }
        );
        errdefer zstbi_image.deinit();
        
        @memcpy(zstbi_image.data[0..], self.data[0..]);

        return zstbi_image;
    }
};

pub const ImageLoader = struct {
    const Self = @This();

    alloc: std.mem.Allocator,

    pub fn deinit(self: *Self) void {
        _ = self;
        stbi.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !Self {
        stbi.init(alloc);

        return Self {
            .alloc = alloc,
        };
    }

    pub const Options = struct {
        force_channels: ?u8 = null,
    };

    pub fn load_from_file(alloc: std.mem.Allocator, file_path: []const u8, options: Options) !Image {
        const cpath = try alloc.dupeZ(u8, file_path);
        defer alloc.free(cpath);

        const ext = std.fs.path.extension(cpath);
        if (std.mem.eql(u8, ext, ".r32")) {
            const file = try std.fs.cwd().openFile(cpath, .{ .mode = .read_only });
            defer file.close();

            const file_len = try file.getEndPos();
            const buf = try alloc.alloc(u8, @intCast(file_len));
            errdefer alloc.free(buf);

            const read_len = try file.readAll(buf);
            if (read_len != file_len) {
                return error.FailedToReadImage;
            }

            const bytes_per_component: u32 = 4;
            if (@mod(file_len, bytes_per_component) != 0) {
                return error.ImageDataLengthIsNotMultipleOfBytesPerComponent;
            }
            const components_in_file: u32 = @intCast(@divExact(file_len, bytes_per_component));
            const row_len: u32 = @intCast(std.math.sqrt(components_in_file));
            const bytes_per_row: u32 = row_len * bytes_per_component;

            return Image {
                .alloc = alloc,
                .data = buf,
                .width = row_len,
                .height = row_len,
                .num_components = 1,
                .bytes_per_component = bytes_per_component,
                .bytes_per_row = bytes_per_row,
                .is_hdr = true,
            };
        } else {
            var stbi_image = try stbi.Image.loadFromFile(cpath, if (options.force_channels) |nc| nc else 0);
            defer stbi_image.deinit();

            const owned_data = try alloc.dupe(u8, stbi_image.data);
            errdefer alloc.free(owned_data);

            return Image {
                .alloc = alloc,
                .data = owned_data,
                .width = stbi_image.width,
                .height = stbi_image.height,
                .num_components = stbi_image.num_components,
                .bytes_per_component = stbi_image.bytes_per_component,
                .bytes_per_row = stbi_image.bytes_per_row,
                .is_hdr = stbi_image.is_hdr,
            };
        }
    }

    pub fn load_from_memory(self: *const Self, data: []const u8) !Image {
        _ = self;
        return try stbi.Image.loadFromMemory(data, 4);
    }
};
