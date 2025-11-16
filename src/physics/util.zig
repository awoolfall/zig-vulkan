const std = @import("std");
const zphy = @import("zphysics");

pub const CollideShapeCollector = extern struct {
    __v: *const zphy.CollideShapeCollector.VTable = &vtable,

    alloc: *std.mem.Allocator,
    hits: *std.ArrayList(zphy.CollideShapeResult),

    const vtable = zphy.CollideShapeCollector.VTable{ 
        .reset = _Reset,
        .onBody = _OnBody,
        .onBodyEnd = _OnBodyEnd,
        .setUserData = _SetUserData,
        .addHit = _AddHit,
    };

    fn _Reset(
        self: *zphy.CollideShapeCollector,
    ) callconv(.c) void { 
        _ = self;
    }
    fn _OnBody(
        self: *zphy.CollideShapeCollector,
        in_body: *const zphy.Body,
    ) callconv(.c) void { 
        _ = self;
        _ = in_body;
    }
    fn _OnBodyEnd(
        self: *zphy.CollideShapeCollector,
    ) callconv(.c) void {
        _ = self;
    }
    fn _SetUserData(
        self: *zphy.CollideShapeCollector,
        in_user_data: u64,
    ) callconv(.c) void {
        _ = self;
        _ = in_user_data;
    }
    fn _AddHit(
        self: *zphy.CollideShapeCollector,
        collide_shape_result: *const zphy.CollideShapeResult,
    ) callconv(.c) void {
        const pself = @as(*CollideShapeCollector, @ptrCast(self));
        pself.hits.append(pself.alloc.*, collide_shape_result.*) catch unreachable;
    }

    pub fn deinit(self: *CollideShapeCollector) void {
        const alloc = self.alloc.*;
        self.hits.deinit(alloc);
        alloc.destroy(self.hits);
        alloc.destroy(self.alloc);
    }

    pub fn init(alloc: std.mem.Allocator) !CollideShapeCollector {
        const alloc_ptr = try alloc.create(std.mem.Allocator);
        errdefer alloc.destroy(alloc_ptr);
        alloc_ptr.* = alloc;

        const hits = try alloc.create(std.ArrayList(zphy.CollideShapeResult));
        errdefer alloc.destroy(hits);
        hits.* = std.ArrayList(zphy.CollideShapeResult).empty;

        return CollideShapeCollector {
            .alloc = alloc_ptr,
            .hits = hits,
        };
    }
};