const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const Imui = eng.ui;
const gfx = eng.gfx;
const button = @import("button.zig");

const ColourPickerData = struct {
    colour_image: gfx.Image.Ref,
    colour_image_view: gfx.ImageView.Ref,
    sampler: gfx.Sampler.Ref,
};

var __global_colour_picker_data: ?*ColourPickerData = null;

fn colour_picker_global_init(alloc: std.mem.Allocator) !void {
    if (__global_colour_picker_data == null) {
        __global_colour_picker_data = try alloc.create(ColourPickerData);
        errdefer {
            alloc.destroy(__global_colour_picker_data.?);
            __global_colour_picker_data = null;
        }

        const picker_image_size = 512;
        const picker_image_size_f32: f32 = @floatFromInt(picker_image_size);

        const picker_image_data = try alloc.alloc([4]u8, picker_image_size * picker_image_size);
        defer alloc.free(picker_image_data);

        for (0..picker_image_size) |i| {
            const if32: f32 = @floatFromInt(i);
            for (0..picker_image_size) |j| {
                const jf32: f32 = @floatFromInt(j);

                const c = uv_to_rgb(.{ if32 / picker_image_size_f32, jf32 / picker_image_size_f32 });

                picker_image_data[i + (picker_image_size * j)] = [4]u8{
                    @as(u8, @intFromFloat(@min(@max(c[0] * 255.0, 0.0), 255.0))),
                    @as(u8, @intFromFloat(@min(@max(c[1] * 255.0, 0.0), 255.0))),
                    @as(u8, @intFromFloat(@min(@max(c[2] * 255.0, 0.0), 255.0))),
                    @as(u8, @intFromFloat(@min(@max(c[3] * 255.0, 0.0), 255.0))),
                };
            }
        }

        __global_colour_picker_data.?.colour_image = try gfx.Image.init(
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
        errdefer __global_colour_picker_data.?.colour_image.deinit();

        __global_colour_picker_data.?.colour_image_view = try gfx.ImageView.init(.{ .image = __global_colour_picker_data.?.colour_image, .view_type = .ImageView2D });
        errdefer __global_colour_picker_data.?.colour_image_view.deinit();

        __global_colour_picker_data.?.sampler = try gfx.Sampler.init(.{ .filter_min_mag = .Linear, });
        errdefer __global_colour_picker_data.?.sampler.deinit();
    }
}

fn colour_picker_global_deinit(alloc: std.mem.Allocator) void {
    if (__global_colour_picker_data) |g| {
        g.colour_image_view.deinit();
        g.colour_image.deinit();
        g.sampler.deinit();

        alloc.destroy(g);
        __global_colour_picker_data = null;
    }
}

inline fn uv_to_rgb(uv: [2]f32) zm.F32x4 {
    const uv_vec = zm.f32x4(uv[0], uv[1], 0.0, 0.0);
    const uv_cen = uv_vec - zm.f32x4(0.5, 0.5, 0.0, 0.0);
    const dist_from_center = zm.length2(uv_cen)[0];
    const angle = (std.math.atan2(uv_cen[1], uv_cen[0]) + std.math.pi);
    if (dist_from_center > 0.4 and dist_from_center <= 0.5) {
        return zm.hsvToRgb(zm.f32x4(angle / (2.0 * std.math.pi), 1.0, 1.0, 1.0));
    } else {
        return zm.f32x4(0.0, 0.0, 0.0, 1.0);
    }
}

pub fn create(imui: *Imui, picked_colour_rgb: *?zm.F32x4, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    // global colour picker data management
    if (__global_colour_picker_data == null) {
        colour_picker_global_init(imui.alloc) catch unreachable;
        imui.deinit_functions.append(imui.alloc, colour_picker_global_deinit) catch unreachable;
    }
    const colour_picker_data = __global_colour_picker_data.?;

    // colour picker widget
    var picker_image_signals = Imui.widgets.image.create(imui, colour_picker_data.colour_image_view, colour_picker_data.sampler, key ++ .{@src()});
    if (imui.get_widget(picker_image_signals.id)) |w| {
        w.flags.clickable = true;
    }
    picker_image_signals = imui.generate_widget_signals(picker_image_signals.id);
    
    // Handle color picking on click
    if (picker_image_signals.clicked or picker_image_signals.dragged) {
        const input = &eng.get().input;
        const image_widget = imui.get_widget_from_last_frame(picker_image_signals.id) orelse {
            return picker_image_signals;
        };
        
        const image_rect = image_widget.rect();
        const cursor_pos = [2]f32{
            @floatFromInt(input.cursor_position[0]),
            @floatFromInt(input.cursor_position[1]),
        };
        
        // Calculate normalized position within the picker image (0-1 range)
        const local_x = (cursor_pos[0] - image_rect.left) / image_rect.width();
        const local_y = (cursor_pos[1] - image_rect.top) / image_rect.height();
        
        // Clamp to valid range
        const normalized_x = @max(0.0, @min(1.0, local_x));
        const normalized_y = 1.0 - @max(0.0, @min(1.0, local_y));
        
        // Convert from HSL picker coordinates to RGB color
        const rgb = uv_to_rgb(.{ normalized_x, normalized_y });
        
        picked_colour_rgb.* = rgb;

        picker_image_signals.data_changed = true;
    }
    
    return picker_image_signals;
}
