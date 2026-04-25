const std = @import("std");
const eng = @import("self");

fn resolve_file_uri_head(arena_alloc: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    if (std.mem.eql(u8, uri.scheme, "src")) {
        return try std.fs.path.join(arena_alloc, &.{ eng.get().exe_path, "..", "..", "src" });
    } else if (std.mem.eql(u8, uri.scheme, "res")) {
        return eng.get().asset_manager.resource_directory_str;
    } else {
        return error.InvalidScheme;
    }
}

pub fn resolve_file_uri(alloc: std.mem.Allocator, uri_str: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const uri = try std.Uri.parse(uri_str);

    const relative_path_head = try resolve_file_uri_head(arena.allocator(), uri);

    const resource_relative_path = try uri.path.toRawMaybeAlloc(arena.allocator());

    return try std.fs.path.join(alloc, &.{ relative_path_head, resource_relative_path });
}

pub fn resolve_file_uri_c(alloc: std.mem.Allocator, uri_str: []const u8) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const uri = try std.Uri.parse(uri_str);

    const relative_path_head = try resolve_file_uri_head(arena.allocator(), uri);

    const resource_relative_path = try uri.path.toRawMaybeAlloc(arena.allocator());

    return try std.fs.path.joinZ(alloc, &.{ relative_path_head, resource_relative_path });
}
