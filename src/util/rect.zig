const eng = @import("self");

const Self = @This();

left: f32 = 0.0,
top: f32 = 0.0,
right: f32 = 0.0,
bottom: f32 = 0.0,

pub inline fn all(v: f32) Self {
    return .{ .left = v, .right = v, .top = v, .bottom = v, };
}

pub inline fn lr_tb(lr: f32, tb: f32) Self {
    return .{ .left = lr, .right = lr, .top = tb, .bottom = tb, };
}

pub inline fn lt_rb(lt: f32, rb: f32) Self {
    return .{ .left = lt, .top = lt, .right = rb, .bottom = rb, };
}

pub inline fn full_screen_pixels() Self {
    return full_screen_pixels_mip(0);
}

pub inline fn full_screen_pixels_mip(mip_level: usize) Self {
    const size = eng.get().gfx.swapchain_size();
    return .{
        .left = 0.0,
        .top = 0.0,
        .right = @floatFromInt(@max(size[0] >> @intCast(mip_level), 1)),
        .bottom = @floatFromInt(@max(size[1] >> @intCast(mip_level), 1)),
    };
}

pub inline fn translate(self: *const Self, x: i32, y: i32) Self {
    return Self {
        .left = self.left + x,
        .top = self.top + y,
        .right = self.right,
        .bottom = self.bottom,
    };
}

pub inline fn resize(self: *const Self, x: i32, y: i32) Self {
    return Self {
        .left = self.left,
        .top = self.top,
        .right = self.right + x,
        .bottom = self.bottom + y,
    };
}

pub inline fn adjust(self: *const Self, adjustment_rect: Self) Self {
    return Self {
        .left = self.left + adjustment_rect.left,
        .right = self.right + adjustment_rect.right,
        .top = self.top + adjustment_rect.top,
        .bottom = self.bottom + adjustment_rect.bottom,
    };
}

pub fn contains(self: *const Self, coord: [2]f32) bool {
    return  coord[0] >= self.left and
        coord[0] <= self.right and
        coord[1] >= self.top and
        coord[1] <= self.bottom;
}

pub inline fn width(self: *const Self) f32 {
    return @abs(self.right - self.left);
}

pub inline fn height(self: *const Self) f32 {
    return @abs(self.top - self.bottom);
}
