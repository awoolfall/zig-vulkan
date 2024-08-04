const std = @import("std");
const engine = @import("engine");

const Engine = engine.Engine(App);
const App = struct {
    pub const EntityData = struct {
        pub fn deinit(self: *EntityData) void {
            _ = self;
        }
    };

    pub fn init(eng: *Engine) !App {
        _ = eng;
        return App{};
    }

    pub fn deinit(app: *App) void {
        _ = app;
    }

    pub fn window_event_received(app: *App, event: *const engine.window.WindowEvent) void {
        _ = app;
        _ = event;
    }
};
