const std = @import("std");

pub const Tag = struct {
    key: []const u8,
    val: []const u8,
};

min_lat: f32 = std.math.floatMax(f32),
max_lat: f32 = -std.math.floatMax(f32),
min_lon: f32 = std.math.floatMax(f32),
max_lon: f32 = -std.math.floatMax(f32),
end_nodes: u64 = 0,
way_tags: [][]Tag = &.{},
