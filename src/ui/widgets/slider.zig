const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;
const zm = eng.zmath;

pub const SliderId = struct {
    filled_bar: Imui.WidgetId, 
    background_bar: Imui.WidgetId,
    middle_dot: Imui.WidgetId,
};

pub const SliderOptions = struct {
    min: f32 = 0.0,
    max: f32 = 1.0,
    step: f32 = 1.0,
};

pub fn create(imui: *Imui, value: *f32, options: SliderOptions, key: anytype) Imui.WidgetSignal(SliderId) {
    const complete_percent = std.math.clamp((value.* - options.min) / (options.max - options.min), 0.0, 1.0);
    const box = imui.push_layout(.X, key ++ .{@src().line});
    if (imui.get_widget(box)) |bw| {
        bw.semantic_size[0].kind = .ParentPercentage;
        bw.semantic_size[0].value = 1.0;
        bw.semantic_size[1].kind = .Pixels;
        bw.semantic_size[1].value = 16.0;
        bw.flags.render = false;
        bw.anchor = .{ 0.0, 0.0 };
        bw.pivot = .{ 0.0, 0.0 };
    }

    const filled_bar_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src().line}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = complete_percent, .shrinkable_percent = 0.0, },
            Imui.SemanticSize{ .kind = .Pixels, .value = 8.0, .shrinkable_percent = 0.0, },
        },
        .background_colour = imui.palette().primary,
        .border_colour = imui.palette().primary,
        .border_width_px = .all(1),
        .corner_radii_px = .all(4),
        .flags = .{
            .clickable = true,
            .hover_effect = false,
        },
        .anchor = .{0.0, 0.5},
        .pivot = .{0.0, 0.5},
    };
    const filled_bar_widget_id = imui.add_widget(filled_bar_widget, .{});

    const l1 = imui.push_layout(.X, key ++ .{@src().line});
    if (imui.get_widget(l1)) |lw| {
        lw.semantic_size[0].kind = .ParentPercentage;
        lw.semantic_size[0].value = (1.0 - complete_percent);
        lw.semantic_size[1].kind = .ParentPercentage;
        lw.semantic_size[1].value = 1.0;
        lw.flags.render = false;
        lw.layout_axis = null;
    }

    const empty_bar_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src().line}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0, },
            Imui.SemanticSize{ .kind = .Pixels, .value = 8.0, .shrinkable_percent = 0.0, },
        },
        .flags = .{
            .render = true,
            .hover_effect = false,
            .clickable = true,
        },
        .background_colour = imui.palette().primary * zm.f32x4(1.0, 1.0, 1.0, 0.2),
        .border_colour = imui.palette().border,
        .border_width_px = .all(1),
        .corner_radii_px = .all(4),
        .anchor = .{0.0, 0.5},
        .pivot = .{0.0, 0.5},
    };
    const empty_bar_widget_id = imui.add_widget(empty_bar_widget, .{});

    const middle_dot_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src().line}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
            Imui.SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable_percent = 0.0, },
        },
        .flags = .{
            .render = true,
            .clickable = true,
            .allows_overflow_x = true,
            .allows_overflow_y = true,
        },
        .background_colour = imui.palette().background,
        .border_colour = imui.palette().primary,
        .border_width_px = .all(1),
        .corner_radii_px = .all(8),
        .anchor = .{0.0, 0.5},
        .pivot = .{0.5, 0.5},
    };
    const middle_dot_widget_id = imui.add_widget(middle_dot_widget, .{});

    imui.pop_layout(); // l1
    imui.pop_layout();

    var signals = Imui.combine_signals(
        .{
            imui.generate_widget_signals(filled_bar_widget_id),
            imui.generate_widget_signals(empty_bar_widget_id),
            imui.generate_widget_signals(middle_dot_widget_id),
        },
        SliderId{ .filled_bar = filled_bar_widget_id, .background_bar = box, .middle_dot = middle_dot_widget_id, }
    );

    if (signals.dragged) {
        if (imui.get_widget_from_last_frame(signals.id.background_bar)) |b| {
            const pixel_width: f32 = @floatFromInt(b.content_rect().width);
            const percent = @as(f32, @floatFromInt(imui.input.cursor_position[0] - b.computed.rect().left)) / pixel_width;
            const a = std.math.round((1.0 / options.step) * percent * (options.max - options.min)) * options.step;
            value.* = std.math.clamp(a + options.min, options.min, options.max);
            signals.data_changed = true;
        }
    }

    return signals;
}
