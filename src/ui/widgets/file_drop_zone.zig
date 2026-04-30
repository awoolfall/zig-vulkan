const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const Imui = eng.ui;
const gfx = eng.gfx;

pub fn create(imui: *Imui, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const box_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src()}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, },
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, },
        },
        .border_width_px = .all(4.0),
        .corner_radii_px = .all(20.0),
        .border_colour = zm.f32x4(1.0, 1.0, 1.0, 0.2),
        .flags = .{
            .render = true,
        },
    };

    const box = imui.add_widget(box_widget, null);
    var signals = imui.generate_widget_signals(box);

    if (signals.hover) {
        if (eng.get().input.dropped_files.len != 0) {
            signals.data_changed = true;
        }
    }

    return signals;
}
