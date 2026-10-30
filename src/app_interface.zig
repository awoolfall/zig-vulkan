const std = @import("std");

const Self = @This();

fn_init: *const fn () callconv(.c) i32,
fn_deinit: *const fn () callconv(.c) i32,
fn_update: *const fn () callconv(.c) i32,
fn_render: *const fn () callconv(.c) i32,

fn_app_dll_load: *const fn (engine: ?*anyopaque) callconv(.c) void,
fn_app_dll_unload: *const fn (engine: ?*anyopaque) callconv(.c) void,

pub fn init_interface(lib: *std.DynLib) !Self {
    const fn_init = lib.lookup(@FieldType(Self, "fn_init"), "app_init") orelse return error.NoInitFunction;
    const fn_deinit = lib.lookup(@FieldType(Self, "fn_deinit"), "app_deinit") orelse return error.NoDeinitFunction;
    const fn_update = lib.lookup(@FieldType(Self, "fn_update"), "app_update") orelse return error.NoUpdateFunction;
    const fn_render = lib.lookup(@FieldType(Self, "fn_render"), "app_render") orelse return error.NoRenderFunction;

    const fn_app_dll_load = lib.lookup(@FieldType(Self, "fn_app_dll_load"), "app_dll_load") orelse return error.NoDllLoadFunction;
    const fn_app_dll_unload = lib.lookup(@FieldType(Self, "fn_app_dll_unload"), "app_dll_unload") orelse return error.NoDllUnLoadFunction;

    return Self{
        .fn_init = fn_init,
        .fn_deinit = fn_deinit,
        .fn_update = fn_update,
        .fn_render = fn_render,

        .fn_app_dll_load = fn_app_dll_load,
        .fn_app_dll_unload = fn_app_dll_unload,
    };
}
