const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;
const label = @import("label.zig");

pub const NumberSliderSettings = struct {
    scale: f32 = 0.01,
};

pub fn create(imui: *Imui, value: *f32, settings: NumberSliderSettings, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const background = imui.push_layout(.X, key ++ .{@src()});
    defer imui.pop_layout();
    if (imui.get_widget(background)) |background_widget| {
        background_widget.semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0, },
            Imui.SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
        };
        background_widget.flags.render = true;
        background_widget.flags.hover_effect = false;
        background_widget.flags.clickable = true;
        background_widget.background_colour = imui.palette().muted;
        background_widget.border_colour = imui.palette().border;
        background_widget.border_width_px = .all(1);
        background_widget.corner_radii_px = .all(4);
        background_widget.padding_px = .all(4);
    }
    
    var text_buffer: [32]u8 = undefined;
    const text = label.create(imui, std.fmt.bufPrint(&text_buffer, "{d:.2}", .{value.*}) catch unreachable);
    if (imui.get_widget(text.id)) |text_widget| {
        _ = text_widget;
    }

    var background_signals = imui.generate_widget_signals(background);
    if (background_signals.dragged) {
        value.* += eng.get().input.mouse_delta[0] * settings.scale;
        background_signals.data_changed = true;
    }

    return background_signals;
}
