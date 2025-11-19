const eng = @import("self");
const Imui = eng.ui;
const zm = eng.zmath;
const label = @import("label.zig");

pub fn create(imui: *Imui, text: []const u8, is_open_param: ?*bool, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const l = imui.push_layout(.X, key ++ .{@src()});
    const is_open = is_open_param orelse (imui.get_widget_data(bool, l) catch unreachable)[0];

    if (imui.get_widget(l)) |lw| {
        lw.semantic_size[0].kind = .ParentPercentage;
        lw.semantic_size[0].value = 1.0;
        lw.children_gap = 8;
        lw.flags.clickable = true;
        lw.flags.render = true;
    }
    var l_interaction = imui.generate_widget_signals(l);

    _ = label.create(imui, if (is_open.*) "▼" else "▶");
    _ = label.create(imui, text);
    const line_widget = Imui.Widget {
        .key = Imui.LabelKey,
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, },
            Imui.SemanticSize{ .kind = .Pixels, .value = 1.0, .shrinkable = false, },
        },
        .background_colour = imui.palette().border,
        .flags = .{
            .render = true,
        },
        .anchor = .{0.0, 0.5},
        .pivot = .{0.0, 0.5},
    };
    _ = imui.add_widget(line_widget, .{});

    imui.pop_layout();

    // behaviour
    if (l_interaction.clicked) {
        is_open.* = !is_open.*;
        l_interaction.data_changed = true;
    }

    return l_interaction;
}
