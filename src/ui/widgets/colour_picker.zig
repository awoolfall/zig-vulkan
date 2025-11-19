const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const Imui = eng.ui;
const gfx = eng.gfx;
const button = @import("button.zig");

pub const ContainerData = struct {
    colour_image: gfx.Image.Ref,
    colour_image_view: gfx.ImageView.Ref,

    pub fn deinit(self: *const ContainerData, alloc: std.mem.Allocator) void {
        _ = alloc;
        _ = self;
        //self.colour_image_view.deinit();
        //self.colour_image.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !ContainerData {
        _ = alloc;
        return undefined;
    }

    pub fn clone(self: *ContainerData, alloc: std.mem.Allocator) !ContainerData {
        _ = alloc;
        return self.*;
    }

    pub fn init_c(alloc: std.mem.Allocator) !ContainerData {
        const picker_image_size = 16;
        const picker_image_size_f32: f32 = @floatFromInt(picker_image_size);

        const picker_image_data = try alloc.alloc([4]u8, picker_image_size * picker_image_size);
        defer alloc.free(picker_image_data);

        for (0..picker_image_size) |i| {
            const if32: f32 = @floatFromInt(i);
            for (0..picker_image_size) |j| {
                const jf32: f32 = @floatFromInt(j);

                const c = zm.hslToRgb(zm.f32x4(
                    if32 / picker_image_size_f32,
                    1.0,
                    jf32 / picker_image_size_f32,
                    1.0
                ));

                picker_image_data[i + (picker_image_size * j)] = [4]u8{
                    @as(u8, @intFromFloat(@min(@max(c[0] * 255.0, 0.0), 255.0))),
                    @as(u8, @intFromFloat(@min(@max(c[1] * 255.0, 0.0), 255.0))),
                    @as(u8, @intFromFloat(@min(@max(c[2] * 255.0, 0.0), 255.0))),
                    @as(u8, @intFromFloat(@min(@max(c[3] * 255.0, 0.0), 255.0))),
                };
            }
        }

        const picker_image = try gfx.Image.init(
            .{
                .format = .Rgba8_Unorm,
                .access_flags = .{},
                .usage_flags = .{ .ShaderResource = true, },
                .dst_layout = .ShaderReadOnlyOptimal,
                .width = picker_image_size,
                .height = picker_image_size,
            }, 
            std.mem.sliceAsBytes(picker_image_data)
        );
        errdefer picker_image.deinit();

        const picker_image_view = try gfx.ImageView.init(.{ .image = picker_image, .view_type = .ImageView2D });
        errdefer picker_image_view.deinit();

        return ContainerData {
            .colour_image = picker_image,
            .colour_image_view = picker_image_view,
        };
    }
};

pub fn create(imui: *Imui, picked_colour_hsl: *?zm.F32x4, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const container = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(container)) |c| {
        c.semantic_size[0] = Imui.SemanticSize { .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        c.semantic_size[1] = Imui.SemanticSize { .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
    }

    const container_data, const container_data_state = imui.get_widget_data(ContainerData, container) catch |err| {
        std.log.err("Unable to get colour picker container data: {}", .{err});
        unreachable;
    };

    if (container_data_state == .Init) {
        container_data.* = ContainerData.init_c(eng.get().general_allocator) catch unreachable;
    }

    const picker_image_signals = Imui.widgets.image.create(imui, container_data.colour_image_view, gfx.GfxState.get().default.sampler, key ++ .{@src()});
    
    picked_colour_hsl.* = null;
    return picker_image_signals;
}
