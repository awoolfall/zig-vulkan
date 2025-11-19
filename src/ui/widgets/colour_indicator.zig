const eng = @import("self");
const Imui = eng.ui;
const zm = eng.zmath;

pub fn create(imui: *Imui, colour_rgb: *zm.F32x4, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const colour_normalized = zm.normalize3(colour_rgb.*);
    const colour_no_alpha = zm.f32x4(colour_normalized[0], colour_normalized[1], colour_normalized[2], 1.0);
    var colour_intensity = (colour_rgb.* / colour_normalized)[0];
    var colour_alpha = colour_rgb[3];

    const l = imui.push_layout(.X, key ++ .{@src().line});
    defer imui.pop_layout();

    if (imui.get_widget(l)) |lw| {
        lw.children_gap = 5;
        lw.semantic_size = .{
            .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, },
            .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, }
        };
    }

    const box_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src().line}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .Pixels, .value = 20.0, .shrinkable = false, },
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, },
        },
        .background_colour = colour_no_alpha,
        .border_colour = imui.palette().border,
        .border_width_px = .all(1),
        .corner_radii_px = .all(4),
        .flags = .{
            .clickable = true,
        },
    };
    const box_widget_id = imui.add_widget(box_widget, .{});
    const box_widget_signals = imui.generate_widget_signals(box_widget_id);

    _ = Imui.widgets.label.create(imui, "a:");
    _ = Imui.widgets.number_slider.create(imui, &colour_alpha, .{}, key ++ .{@src()});
    _ = Imui.widgets.label.create(imui, "x:");
    _ = Imui.widgets.number_slider.create(imui, &colour_intensity, .{}, key ++ .{@src()});

    return box_widget_signals;
}
