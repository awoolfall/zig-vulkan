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
