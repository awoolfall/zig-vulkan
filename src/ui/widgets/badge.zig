const eng = @import("self");
const Imui = eng.ui;
const button = @import("button.zig");

pub fn create(imui: *Imui, text: []const u8, key: anytype) Imui.WidgetSignal(button.ButtonId) {
    const button_sig = button.create(imui, text, key ++ .{@src()});
    if (imui.get_widget(button_sig.id.box)) |w| {
        w.padding_px = .lr_tb(10, 2);
    }
    return button_sig;
}
