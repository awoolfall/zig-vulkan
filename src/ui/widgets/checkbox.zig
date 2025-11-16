const eng = @import("self");
const Imui = eng.ui;
const zm = eng.zmath;

pub const CheckboxId = struct {
    box: Imui.WidgetId, 
    text: Imui.WidgetId,
};

pub fn create(imui: *Imui, checked: *bool, text: []const u8, key: anytype) Imui.WidgetSignal(CheckboxId) {
    const l = imui.push_layout(.X, key ++ .{@src().line});
    if (imui.get_widget(l)) |lw| {
        lw.children_gap = 8;
    }

    const box_stack_layout = imui.push_layout(.X, key ++ .{@src().line});
    if (imui.get_widget(box_stack_layout)) |lw| {
        lw.semantic_size[0] = Imui.SemanticSize{ .kind = .Pixels, .value = 16, .shrinkable_percent = 0.0, };
        lw.semantic_size[1] = Imui.SemanticSize{ .kind = .Pixels, .value = 16, .shrinkable_percent = 0.0, };
        lw.layout_axis = null;
    }

    const box_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src().line}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage , .value = 1.0, .shrinkable_percent = 0.0, },
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0, },
        },
        .background_colour = if (checked.*) imui.palette().primary else zm.f32x4s(0.0),
        .border_colour = if (checked.*) imui.palette().primary else imui.palette().foreground,
        .border_width_px = .all(1),
        .corner_radii_px = .all(4),
        .flags = .{
            .clickable = true,
        },
    };
    const box_widget_id = imui.add_widget(box_widget, .{});
    const box_widget_signals = imui.generate_widget_signals(box_widget_id);

    const label = Imui.widgets.label.create(imui, if (checked.*) "X" else " ");
    if (imui.get_widget(label.id)) |lw| {
        lw.text_content.?.colour = imui.palette().text_light;
        lw.text_content.?.size = 16;
        lw.anchor = .{ 0.5, 0.5 };
        lw.pivot = .{ 0.5, 0.5 };
    }

    imui.pop_layout(); // box_stack_layout

    const text_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src().line}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
            Imui.SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 1.0, },
        },
        .text_content = .{
            .font = .Geist,
            .text = text,
        },
        .flags = .{ 
            .clickable = true, 
            .render_quad = false,
        },
        .anchor = .{ 0.0, 0.5 },
        .pivot = .{ 0.0, 0.5 },
    };
    const text_widget_id = imui.add_widget(text_widget, .{});
    const text_widget_signals = imui.generate_widget_signals(text_widget_id);

    imui.pop_layout();

    var combined_signals = Imui.combine_signals(
        .{
            box_widget_signals, 
            text_widget_signals, 
        },
        CheckboxId{ .box = box_widget_id, .text = text_widget_id, }
    );

    // checkbox behaviour
    if (combined_signals.clicked) {
        checked.* = !checked.*;
        combined_signals.data_changed = true;
    }

    return combined_signals;
}
