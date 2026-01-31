const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;
const zm = eng.zmath;

pub fn create(imui: *Imui, colour_rgb: *zm.F32x4, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    // Create display color from the raw values, clamped to 0-1 for display
    const clamped_r = @min(colour_rgb[0], 1.0);
    const clamped_g = @min(colour_rgb[1], 1.0);
    const clamped_b = @min(colour_rgb[2], 1.0);
    const colour_display = zm.f32x4(clamped_r, clamped_g, clamped_b, 1.0);
    
    // Calculate intensity as the max component (brightness excess)
    const intensity = @max(@max(colour_rgb[0], colour_rgb[1]), colour_rgb[2]);
    const alpha = colour_rgb[3];

    // Create horizontal layout container
    const container = imui.push_layout(.X, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(container)) |container_widget| {
        container_widget.semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, },
            Imui.SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable = false, },
        };
        container_widget.children_gap = 5;
    }

    // Color swatch indicator
    const swatch_widget = Imui.Widget{
        .key = Imui.gen_key(key ++ .{@src().line, 0}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .Pixels, .value = 20.0, .shrinkable = false, },
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, },
        },
        .background_colour = colour_display,
        .border_colour = imui.palette().border,
        .border_width_px = .all(1),
        .corner_radii_px = .all(2),
        .flags = .{
            .clickable = true,
            .hover_effect = true,
        },
    };
    const swatch_id = imui.add_widget(swatch_widget, null);
    const swatch_signals = imui.generate_widget_signals(swatch_id);

    // RGB hex + intensity + alpha display
    var hex_buffer: [24]u8 = undefined;
    const hex_text = std.fmt.bufPrint(
        &hex_buffer,
        "#{X:0>2}{X:0>2}{X:0>2} i:{d:.2} a:{d:.2}",
        .{
            @as(u8, @intFromFloat(clamped_r * 255)),
            @as(u8, @intFromFloat(clamped_g * 255)),
            @as(u8, @intFromFloat(clamped_b * 255)),
            intensity,
            alpha,
        },
    ) catch unreachable;
    _ = Imui.widgets.label.create(imui, hex_text);

    return swatch_signals;
}
