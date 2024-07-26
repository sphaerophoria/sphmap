const lin = @import("lin.zig");

pub const NormalizedPosition = lin.Point;
pub const NormalizedOffset = lin.Vec;

down: bool = false,
pos: NormalizedPosition = undefined,

const MouseTracker = @This();

pub fn onDown(self: *MouseTracker, x: f32, y: f32) void {
    self.down = true;
    self.pos.x = x;
    self.pos.y = y;
}

pub fn onUp(self: *MouseTracker) void {
    self.down = false;
}

pub fn getMovement(self: *MouseTracker, x: f32, y: f32) NormalizedOffset {
    return .{
        .x = self.pos.x - x,
        .y = y - self.pos.y,
    };
}
