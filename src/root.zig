pub const Engine = @import("engine.zig");

pub const zmath = @import("zmath");
pub const znoise = @import("znoise");
pub const zmesh = @import("zmesh");

pub const gitrev = @import("build_options").engine_gitrev;
pub const gitchanged = @import("build_options").engine_gitchanged;

pub const gfx = @import("gfx/gfx.zig");
pub const assets = @import("asset/asset.zig");
pub const input = @import("input/input.zig");
pub const time = @import("engine/time.zig");
pub const mesh = @import("asset/model/model.zig");
pub const physics = @import("physics/physics.zig");
pub const image = @import("asset/image/image.zig");
pub const ecs = @import("engine/ecs.zig");
pub const animation = @import("animation/animation.zig");

pub const camera = @import("engine/camera.zig");
pub const particles = @import("particles/particle_system.zig");
pub const particles_renderer = @import("particles/particle_renderer.zig");
pub const AnimationGraph = @import("animation/animation_graph.zig");
pub const ui = @import("ui/ui.zig");
pub const debugg = @import("debug/debug.zig");

pub const util = struct {
    pub const Path = @import("util/path.zig");
    pub const Profiler = @import("util/profiler.zig");
    pub const Rect = @import("util/rect.zig");
    pub const BoundingBox = @import("util/bounding_box.zig");
    pub const easings = @import("util/easings.zig");
    pub const gen = @import("util/gen_list.zig");
};

pub const Transform = @import("util/transform.zig");

pub const window = @import("window/window.zig");

pub const serialize = @import("serialize/serialize.zig");

const App = @import("app");
const EntityComponentsTuple = ecs.StandardEntityComponents ++ App.EntityComponents;
pub const AppEcsSystem = ecs.EcsSystem(EntityComponentsTuple);

pub fn get() *Engine {
    return @import("global_engine.zig").__global_engine;
}

