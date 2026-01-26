pub const Engine = @import("engine.zig");

pub const zmath = @import("zmath");
pub const znoise = @import("znoise");
pub const zmesh = @import("zmesh");

pub const gitrev = @import("build_options").engine_gitrev;
pub const gitchanged = @import("build_options").engine_gitchanged;

pub const platform = @import("platform/platform.zig");
pub const gfx = @import("gfx/gfx.zig");
pub const assets = @import("asset/asset.zig");
pub const input = @import("input/input.zig");
pub const time = @import("engine/time.zig");
pub const mesh = @import("engine/mesh.zig");
pub const physics = @import("physics/physics.zig");
pub const image = @import("engine/image.zig");
pub const entity = @import("engine/entity.zig");
pub const gen = @import("engine/gen_list.zig");
pub const Transform = @import("engine/transform.zig");
pub const ecs = @import("engine/ecs.zig");

pub const camera = @import("engine/camera.zig");
pub const path = @import("engine/path.zig");
pub const particles = @import("particles/particle_system.zig");
pub const particles_renderer = @import("particles/particle_renderer.zig");
pub const easings = @import("easings.zig");
pub const animation = @import("engine/anim_controller.zig");
pub const ui = @import("ui/ui.zig");
pub const debugg = @import("debug/debug.zig");

pub const Rect = @import("rect.zig");

pub const window = @import("window.zig");

pub const serialize = @import("serialize/serialize.zig");

const App = @import("app");
const EntityComponentsTuple = entity.StandardEntityComponents ++ App.EntityComponents;
pub const AppEcsSystem = ecs.EcsSystem(EntityComponentsTuple);

pub fn get() *Engine {
    return @import("global_engine.zig").__global_engine;
}

