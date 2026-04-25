const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;
const gfx = eng.gfx;

pub fn create(imui: *Imui, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const box_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src()}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, },
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, },
        },
        .flags = .{
            .render = false, // TODO: add ability to render dotted border using 9 grid split thing
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
