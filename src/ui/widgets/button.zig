const eng = @import("self");
const Imui = eng.ui;
const es = eng.util.easings;
const label = @import("label.zig");

pub const ButtonId = struct {
    box: Imui.WidgetId,
    text: Imui.WidgetId,
};

pub fn create(imui: *Imui, text: []const u8, key: anytype) Imui.WidgetSignal(ButtonId) {
    const box_layout = imui.push_layout(.X, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(box_layout)) |w| {
        w.semantic_size[0].shrinkable = false;
        w.layout_axis = null;
        w.background_colour = imui.palette().primary;
        w.border_width_px = .all(1);
        w.padding_px = .lr_tb(16, 8);
        w.corner_radii_px = .all(6);
        w.flags.clickable = true;
        w.flags.render = true;
        w.active_t_timescale = 0.05;
        // w.margin_px = .{
        //     .top = @floatCast((std.math.sin(engine.get().time.time_since_start_of_app() + @as(f64, @floatFromInt(w.key & 0xffff))) + 1.0) * 10.0),
        //     .bottom = @floatCast((2.0 - (std.math.sin(engine.get().time.time_since_start_of_app() + @as(f64, @floatFromInt(w.key & 0xffff))) + 1.0)) * 10.0),
        // };
        if (imui.get_widget_from_last_frame(box_layout)) |lw| {
            w.margin_px = .{
                .top = es.ease_out_expo(lw.active_t) * 3.0,
                //.bottom = (1.0 - es.ease_out_expo(lw.active_t)) * 3.0,
            };
            w.border_width_px = .{
                .left = 1,
                .right = 1,
                .top = 1,
                .bottom = 1.0 + (1.0 - es.ease_out_expo(lw.active_t)) * 3.0,
            };
        }
    }

    const label_id = label.create(imui, text);
    if (imui.get_widget(label_id.id)) |text_widget| {
        text_widget.anchor = .{0.5, 0.5};
        text_widget.pivot = .{0.5, 0.5};
    }

    const signals = Imui.combine_signals(
        .{
            imui.generate_widget_signals(box_layout),
            label_id,
        },
        ButtonId{ .box = box_layout, .text = label_id.id, }
    );

    return signals;
}
