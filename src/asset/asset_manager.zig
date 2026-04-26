const std = @import("std");
const eng = @import("self");
const GenericAssetId = @import("asset_id.zig");

const StandardAssets = @import("asset.zig").StandardAssets;

const Self = @This();

const AssetTypeInfo = @typeInfo(@TypeOf(StandardAssets));

alloc: std.mem.Allocator,

resource_directory: std.fs.Dir,
resource_directory_str: []const u8,

asset_metadata: std.AutoHashMap(u64, AssetMetadata),
asset_uri_map: std.StringHashMap(u64),

asset_type_extension_register: std.StringHashMap(usize),

assets: AssetTypesTuple(StandardAssets),

pub fn deinit(self: *Self) void {
    self.resource_directory.close();
    self.alloc.free(self.resource_directory_str);

    var metadata_iterator = self.asset_metadata.iterator();
    while (metadata_iterator.next()) |entry| {
        entry.value_ptr.deinit(self.alloc);
    }
    self.asset_metadata.deinit();

    // name strings are freed by metadata above
    self.asset_uri_map.deinit();

    // asset type extensions use static strings within each asset type file
    // so dont need to be freed
    self.asset_type_extension_register.deinit();

    inline for (AssetTypeInfo.@"struct".fields, 0..) |_, idx| {
        self.assets[idx].deinit();
    }
}

pub fn init(alloc: std.mem.Allocator, resource_directory_path: []const u8) !Self {
    var dir = try std.fs.openDirAbsolute(resource_directory_path, .{ .iterate = true, });
    errdefer dir.close();

    const owned_resource_directory_str = try std.fs.cwd().realpathAlloc(alloc, resource_directory_path);
    errdefer alloc.free(owned_resource_directory_str);

    var asset_ext_type_register = std.StringHashMap(usize).init(alloc);
    errdefer asset_ext_type_register.deinit();

    var assets: AssetTypesTuple(StandardAssets) = undefined;
    inline for (AssetTypeInfo.@"struct".fields, 0..) |_, idx| {
        assets[idx] = try .init(alloc);
        errdefer assets[idx].deinit();

        for (StandardAssets[idx].extensions) |ext| {
            try asset_ext_type_register.put(ext, idx);
        }
    }

    return Self {
        .alloc = alloc,
        .resource_directory = dir,
        .resource_directory_str = owned_resource_directory_str,
        .assets = assets,
        .asset_metadata = .init(alloc),
        .asset_uri_map = .init(alloc),
        .asset_type_extension_register = asset_ext_type_register,
    };
}

// fn iterate_resource_directory_and_generate_metadata(self: *Self) !void {
//     var dir_iter = self.resource_directory.iterate();
//     outer_blk: {
//         while (dir_iter.next() catch break :outer_blk) |entry| {
//             switch (entry.kind) {
//                 .file => {
//                     if (!self.asset_name_map.contains(entry.name)) {
//                         const file_uri = try std.fmt.allocPrint(self.alloc, "res:{s}", .{entry.name});
//                         errdefer self.alloc.free(file_uri);
//
//                         const file_stat = self.resource_directory.statFile(entry.name) catch |err| {
//                             std.log.err("Unable to stat resource file: {s}: {}", .{file_uri, err});
//                             return err;
//                         };
//
//                         const metadata = AssetMetadata {
//                             .uri = file_uri,
//                             .last_modify_time = file_stat.mtime,
//                         };
//
//                         const asset_id = generate_unique_id();
//                         std.log.info("found new resource file {s}, {}, type: {}", .{file_uri, asset_id, asset_type});
//
//                         self.asset_metadata.putNoClobber(asset_id, metadata) catch unreachable;
//                         self.asset_name_map.putNoClobber(owned_name, asset_id) catch unreachable;
//                     }
//                 },
//                 .sym_link => {
//                     std.log.warn("Sym_link in the resource directory? really? I'm going to ignore {s}", .{entry.name});
//                 },
//                 .directory => {
//                     // TODO need to recurse, apparently there is a Dir.walk method that might do this automatically
//                     std.log.warn("sub-directories in the resources directory is not yet supported", .{});
//                 },
//                 else => {},
//             }
//         }
//     }
// }

var __g_unique_id_count: usize = 0;
pub fn generate_unique_id() u64 {
    var hasher = std.hash.XxHash64.init(0xE0B1F6023A24ECB2); // static randomly generated seed
    std.hash.autoHash(&hasher, .{
        std.time.nanoTimestamp(),
        __g_unique_id_count,
        // TODO add some unique identifier for the user machine. Maybe pull git email?
    });
    __g_unique_id_count += 1;
    return hasher.final();
}

pub fn get_asset_type_index(comptime T: type) comptime_int {
    inline for (AssetTypeInfo.@"struct".fields, 0..) |_, idx| {
        if (T == StandardAssets[idx]) { return idx; }
    }
    @compileError(std.fmt.comptimePrint("The type '{s}' is not an asset type.", .{@typeName(T)}));
}

pub fn get_asset_unique_id(self: *Self, asset_uri: []const u8) !u64 {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    
    const uri = try std.Uri.parse(asset_uri);

    const path = try uri.path.toRawMaybeAlloc(arena.allocator());
    _ = path;

    const asset_unique_id = if (self.asset_uri_map.get(asset_uri)) |asset_id| idblk: {
        break :idblk asset_id;
    } else idblk: {
        const owned_uri = try self.alloc.dupe(u8, asset_uri);
        errdefer self.alloc.free(owned_uri);

        // split asset_uri path gradually to find the base asset id then create ephemeral metadata
        // i.e. for 'asset:models/character.glb/animations/idle'
        // has a base asset of asset:models/character.glb
        // and a sub asset at location 'animations/idle'
        // this might recurse to i.e. 'res:models/character.glb/animations/idle/variation_1'

        const asset_file_path = try eng.util.uri.resolve_file_uri(eng.get().frame_allocator, asset_uri);

        // check file exists, if so it can be used as a base asset
        const base_asset_id: ?u64 = blk: {
            std.fs.cwd().access(asset_file_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => {
                    const base_asset_uri = std.fs.path.dirname(asset_uri) orelse return error.AssetUriDoesNotReferenceABaseAsset;
                    break :blk try self.get_asset_unique_id(base_asset_uri);
                },
                else => return err,
            };
            break :blk null;
        };

        const last_modify_time = if (base_asset_id) |base_id| blk: {
            const base_metadata = self.asset_metadata.get(base_id) orelse return error.AssetDoesNotHaveMetadata;
            break :blk base_metadata.last_modify_time;
        } else blk: {
            const file_stat = self.resource_directory.statFile(asset_file_path) catch |err| return err;
            break :blk file_stat.mtime;
        };

        const new_asset_id = generate_unique_id();

        const new_asset_metadata = AssetMetadata {
            .uri = owned_uri,
            .type_index = std.math.maxInt(usize),
            .last_modify_time = last_modify_time,
            .base_asset_id = base_asset_id,
        };

        std.debug.assert(new_asset_id != base_asset_id);

        try self.asset_metadata.put(new_asset_id, new_asset_metadata);
        errdefer _ = self.asset_metadata.remove(new_asset_id);

        try self.asset_uri_map.put(owned_uri, new_asset_id);
        errdefer _ = self.asset_uri_map.remove(owned_uri);

        break :idblk new_asset_id;
    };

    return asset_unique_id;
}

pub fn get_asset_id(self: *Self, asset_uri: []const u8) !GenericAssetId {
    const asset_unique_id = try self.get_asset_unique_id(asset_uri);

    return .{ .unique_id = asset_unique_id };
}

fn load_asset(self: *Self, comptime AssetType: type, asset_id: GenericAssetId) !void {
    const asset_type_index = get_asset_type_index(AssetType);
    const asset_metadata = self.asset_metadata.getPtr(asset_id.unique_id) orelse return error.AssetMetadataDoesNotExist;

    if (!self.assets[asset_type_index].map.contains(asset_id.unique_id)) {
        var new_asset = try self.assets[asset_type_index].loader.load(self.alloc, asset_metadata.uri);
        errdefer self.assets[asset_type_index].loader.unload(&new_asset);

        try self.assets[asset_type_index].map.put(asset_id.unique_id, new_asset);
    } else {
        std.log.warn("Load asset called on asset which has already been loaded: {s}", .{asset_metadata.uri});
    }
}

fn unload_asset(self: *Self, comptime AssetType: type, asset_id: GenericAssetId) !void {
    const asset_type_index = get_asset_type_index(AssetType);

    if (self.assets[asset_type_index].map.getPtr(asset_id.unique_id)) |asset_ptr| {
        self.assets[asset_type_index].loader.unload(asset_ptr);
        _ = self.assets[asset_type_index].map.remove(asset_id.unique_id);
    } else {
        const asset_metadata = self.asset_metadata.getPtr(asset_id.unique_id) orelse return;
        std.log.warn("Unload asset called on asset which is not currently loaded: {s}", .{asset_metadata.uri});
    }
}

const ReloadAssetError = error {
    AssetHasNoMetadata,
    FailedToResolveUri,
    FailedToStatFile,
    FailedToLoadAsset,
    FailedToPutAssetInMap,
};

fn reload_asset_if_required(self: *Self, asset_id: GenericAssetId) ReloadAssetError!void {
    const asset_metadata = self.asset_metadata.getPtr(asset_id.unique_id) orelse return error.AssetHasNoMetadata;

    const last_modify_time = if (asset_metadata.base_asset_id) |base_asset_id| blk: {
        std.debug.assert(base_asset_id != asset_id.unique_id);
        try self.reload_asset_if_required(.{ .unique_id = base_asset_id }); // recursion
        const base_metadata = self.asset_metadata.get(base_asset_id) orelse return error.AssetHasNoMetadata;
        break :blk base_metadata.last_modify_time;
    } else blk: {
        const path = eng.util.uri.resolve_file_uri(eng.get().frame_allocator, asset_metadata.uri) catch return error.FailedToResolveUri;
        const file_stat = self.resource_directory.statFile(path) catch return error.FailedToStatFile;
        break :blk file_stat.mtime;
    };

    if (last_modify_time != asset_metadata.last_modify_time and asset_metadata.type_index != std.math.maxInt(usize)) {
        std.log.info("Hot reloading asset '{s}'", .{asset_metadata.uri});

        if (asset_metadata.type_index != std.math.maxInt(usize)) {
            inline for (AssetTypeInfo.@"struct".fields, 0..) |_, asset_idx| {
                if (asset_metadata.type_index == asset_idx) {
                    // load new asset
                    var new_asset = self.assets[asset_idx].loader.load(self.alloc, asset_metadata.uri) catch return error.FailedToLoadAsset;
                    errdefer self.assets[asset_idx].loader.unload(&new_asset);

                    // unload old asset
                    try self.unload_asset(StandardAssets[asset_idx], asset_id);

                    // set new asset
                    self.assets[asset_idx].map.put(asset_id.unique_id, new_asset) catch return error.FailedToPutAssetInMap;
                }
            }
        }
        
        asset_metadata.last_modify_time = last_modify_time;
    }
}

pub fn get_asset(self: *Self, comptime AssetType: type, asset_id: GenericAssetId) !*AssetType.BaseType {
    const asset_type_index = get_asset_type_index(AssetType);
    if (asset_type_index >= AssetTypeInfo.@"struct".fields.len) {
        return error.InvalidAssetType;
    }

    const metadata = self.asset_metadata.getPtr(asset_id.unique_id) orelse return error.AssetHasNoMetadata;
    if (metadata.type_index == std.math.maxInt(usize)) {
        metadata.type_index = asset_type_index;
    }
    if (metadata.type_index != asset_type_index) {
        return error.AssetMetadataHasADifferentTypeIndex;
    }

    if (!self.assets[asset_type_index].map.contains(asset_id.unique_id)) {
        try self.load_asset(AssetType, asset_id);
    }

    // hot reload asset if the base file changes
    try self.reload_asset_if_required(asset_id);

    return self.assets[asset_type_index].map.getPtr(asset_id.unique_id) orelse return error.CouldNotGetAsset;
}

const AssetMetadata = struct {
    uri: []const u8,
    type_index: usize,
    last_modify_time: i128,

    base_asset_id: ?u64 = null,

    pub fn deinit(self: *AssetMetadata, alloc: std.mem.Allocator) void {
        alloc.free(self.uri);
    }
};

fn AssetTypesTuple(comptime AssetTypes: anytype) type {
    const info = @typeInfo(@TypeOf(AssetTypes));

    var type_fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (info.@"struct".fields, 0..) |_, idx| {
        const AssetData = struct {
            const Self_AssetType = @This();

            pub const AssetHashMap = std.AutoHashMap(u64, AssetTypes[idx].BaseType);

            loader: AssetTypes[idx].Loader,
            map: AssetHashMap,

            pub fn deinit(self: *Self_AssetType) void {
                var asset_iterator = self.map.iterator();
                while (asset_iterator.next()) |entry| {
                    self.loader.unload(entry.value_ptr);
                }

                self.map.deinit();
                self.loader.deinit();
            }

            pub fn init(alloc: std.mem.Allocator) !Self_AssetType {
                const map = AssetHashMap.init(alloc);
                errdefer map.deinit();

                const loader = try AssetTypes[idx].Loader.init(alloc);
                errdefer loader.deinit();

                return Self_AssetType {
                    .loader = loader,
                    .map = map,
                };
            }
        };

        type_fields[idx] = std.builtin.Type.StructField {
            .name = std.fmt.comptimePrint("{d}", .{idx}),
            .type = AssetData,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(AssetData),
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
