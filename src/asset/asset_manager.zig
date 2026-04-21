const std = @import("std");
const eng = @import("self");

const AssetId = @import("asset_id.zig").AssetId;

const StandardAssets = @import("asset.zig").StandardAssets;

const Self = @This();

const AssetTypeInfo = @typeInfo(@TypeOf(StandardAssets));

alloc: std.mem.Allocator,

resource_directory: std.fs.Dir,

asset_metadata: std.AutoHashMap(u64, AssetMetadata),
asset_filename_map: std.StringHashMap(u64),
asset_prettyname_map: std.StringHashMap(u64),

assets: AssetTypesTuple(StandardAssets),

pub fn deinit(self: *Self) void {
    self.resource_directory.close();

    var metadata_iterator = self.asset_metadata.iterator();
    while (metadata_iterator.next()) |entry| {
        entry.value_ptr.deinit(self.alloc);
    }
    self.asset_metadata.deinit();

    self.asset_filename_map.deinit();
    self.asset_prettyname_map.deinit();

    inline for (AssetTypeInfo.@"struct".fields, 0..) |_, idx| {
        self.assets[idx].deinit();
    }
}

pub fn init(alloc: std.mem.Allocator, resource_directory_path: []const u8) !Self {
    var dir = try std.fs.openDirAbsolute(resource_directory_path, .{ .iterate = true, });
    errdefer dir.close();

    const metadata_file = try open_resources_metadata_file(dir);
    errdefer metadata_file.close();

    var assets: AssetTypesTuple(StandardAssets) = undefined;
    inline for (AssetTypeInfo.@"struct".fields, 0..) |_, idx| {
        assets[idx] = try .init(alloc);
        errdefer assets[idx].deinit();
    }

    var self = Self {
        .alloc = alloc,
        .resource_directory = dir,
        .assets = assets,
        .asset_metadata = .init(alloc),
        .asset_filename_map = .init(alloc),
    };

    try self.iterate_resource_directory_and_generate_metadata();

    return self;
}

pub fn resolve_resource_relative_path(self: *const Self, alloc: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    return std.fs.path.join(alloc, .{ self.resource_directory, relative_path });
}

fn open_resources_metadata_file(resources_dir: std.fs.Dir) !std.fs.File {
    return try resources_dir.openFile("asset_metadata.meta", .{ .mode = .read_write, });
}

fn iterate_resource_directory_and_generate_metadata(self: *Self) !void {
    var dir_iter = self.resource_directory.iterate();
    outer_blk: {
        while (dir_iter.next() catch break :outer_blk) |entry| {
            switch (entry.kind) {
                .file => {
                    if (!self.asset_filename_map.contains(entry.name)) {
                        const metadata = self.create_metadata_for_file(entry.name) catch |err| {
                            std.log.err("Unable to create metadata for file: {s}: {}", .{entry.name, err});
                            continue;
                        };
                        self.set_metadata_for_file(metadata) catch |err| {
                            std.log.err("Unable to set file metadata: {s}: {}", .{metadata.file_relative_path, err});
                            continue;
                        };
                    }
                },
                .sym_link => {
                    std.log.warn("Sym_link in the resource directory? really? I'm going to ignore {s}", .{entry.name});
                },
                .directory => {
                    // TODO need to recurse, apparently there is a Dir.walk method that might do this automatically
                    std.log.warn("sub-directories in the resources directory is not yet supported", .{});
                },
                else => {},
            }
        }
    }
}

fn create_metadata_for_file(self: *const Self, file_relative_path: []const u8) !AssetMetadata {
    const asset_id = generate_unique_id();

    const file_stat = self.resource_directory.statFile(file_relative_path) catch |err| {
        std.log.err("Unable to stat resource file: {s}: {}", .{file_relative_path, err});
        return err;
    };

    const owned_relative_path = try self.alloc.dupe(u8, file_relative_path);
    errdefer self.alloc.free(owned_relative_path);

    const owned_pretty_name = try self.alloc.dupe(u8, file_relative_path);
    errdefer self.alloc.free(owned_pretty_name);

    const metadata = AssetMetadata {
        .file_relative_path = owned_relative_path,
        .last_modify_time = file_stat.mtime,
        .unique_id = asset_id,
        .pretty_name = owned_pretty_name,
    };

    return metadata;
}

fn set_metadata_for_file(self: *Self, metadata: AssetMetadata) !void {
    self.asset_metadata.putNoClobber(metadata.unique_id, metadata) catch |err| {
        std.log.err("Unable to insert resource file metadata in asset metadata map: {s}: {}", .{metadata.file_relative_path, err});
        return err;
    };
    errdefer _ = self.asset_metadata.remove(metadata.unique_id);

    self.asset_filename_map.putNoClobber(metadata.file_relative_path, metadata.unique_id) catch |err| {
        std.log.err("Unable to insert resource file name in asset filename map: {s}: {}", .{metadata.file_relative_path, err});
        return err;
    };
    errdefer _ = self.asset_filename_map.remove(metadata.file_relative_path);

    self.asset_prettyname_map.putNoClobber(metadata.pretty_name, metadata.unique_id) catch |err| {
        std.log.err("Unable to insert resource file name in asset pretty name map: {s}: {}", .{metadata.file_relative_path, err});
        return err;
    };
    errdefer _ = self.asset_prettyname_map.remove(metadata.pretty_name);
}

pub fn generate_unique_id() u64 {
    var hasher = std.hash.XxHash64.init(0xE0B1F6023A24ECB2); // static randomly generated seed
    hasher.update(std.time.nanoTimestamp());
    // TODO add some unique identifier for the user machine. Maybe pull git email?
    return hasher.final();
}

fn get_asset_type_index(comptime T: type) comptime_int {
    inline for (AssetTypeInfo.@"struct".fields, 0..) |_, idx| {
        if (T == StandardAssets[idx]) { return idx; }
    }
    @compileError(std.fmt.comptimePrint("The type '{s}' is not an asset type.", .{@typeName(T)}));
}

pub fn set_asset_pretty_name(self: *Self, asset_id: u64, new_pretty_name: []const u8) !void {
    const metadata = self.asset_metadata.getPtr(asset_id) orelse return error.AssetMetadataDoesNotExist;

    const owned_new_pretty_name = try self.alloc.dupe(u8, new_pretty_name);
    errdefer self.alloc.free(owned_new_pretty_name);
    
    try self.asset_prettyname_map.putNoClobber(new_pretty_name, asset_id);
    errdefer _ = self.asset_prettyname_map.remove(new_pretty_name);

    _ = self.asset_prettyname_map.remove(metadata.pretty_name);

    self.alloc.free(metadata.pretty_name);
    metadata.pretty_name = owned_new_pretty_name;
}

pub fn get_asset_id_from_pretty_name(self: *const Self, comptime AssetType: type, asset_pretty_name: []const u8) !AssetId(AssetType) {
    const asset_id = self.asset_prettyname_map.get(asset_pretty_name) orelse return error.AssetWithNameDoesNotExist;
    // TODO: return error if the asset type does not match
    return AssetId(AssetType) {
        .unique_id = asset_id,
    };
}

pub fn get_asset(self: *const Self, comptime AssetType: type, asset_id: AssetId(AssetType)) !*AssetType.BaseType {
    const asset_type_index = get_asset_type_index(AssetType);
    if (!self.assets[asset_type_index].contains(asset_id.unique_id)) {
        const asset_metadata = self.asset_metadata.getPtr(asset_id.unique_id) orelse return error.AssetMetadataDoesNotExist;
        AssetType.Loader.load(self.alloc, asset_metadata.asset_uri);
    }
    return self.assets[asset_type_index].getPtr(asset_id.unique_id) orelse return error.CouldNotGetAsset;
}

const AssetMetadata = struct {
    asset_uri: []const u8,
    last_modify_time: i128,
    unique_id: u64,
    pretty_name: []const u8,

    pub fn deinit(self: *AssetMetadata, alloc: std.mem.Allocator) void {
        alloc.free(self.file_relative_path);
        alloc.free(self.pretty_name);
    }
};

fn AssetTypesTuple(comptime AssetLoaders: anytype) type {
    const info = @typeInfo(@TypeOf(AssetLoaders));

    var type_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (info.@"struct".fields, 0..) |_, idx| {
        const AssetType = struct {
            const Self_AssetType = @This();
            pub const AssetHashMap = std.AutoHashMap(u64, AssetLoaders[idx].BaseType);

            map: AssetHashMap,

            pub fn deinit(self: *Self_AssetType) void {
                self.map.deinit();
            }

            pub fn init(alloc: std.mem.Allocator) !Self_AssetType {
                const map = AssetHashMap.init(alloc);
                errdefer map.deinit();

                return Self_AssetType {
                    .map = map,
                };
            }
        };

        type_fields[idx] = std.builtin.Type.StructField {
            .name = std.fmt.comptimePrint("{d}", .{idx}),
            .type = AssetType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(AssetType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = true,
            .fields = &type_fields,
            .decls = &.{},
            .layout = .auto,
        }
    });
}
