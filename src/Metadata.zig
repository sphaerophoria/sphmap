const std = @import("std");

pub const Tags = [2][]usize;

min_lat: f32 = std.math.floatMax(f32),
max_lat: f32 = -std.math.floatMax(f32),
min_lon: f32 = std.math.floatMax(f32),
max_lon: f32 = -std.math.floatMax(f32),
bus_node_start_idx: u32 = 0,
end_nodes: u64 = 0,
end_ways: u64 = 0,
way_tags: []Tags = &.{},
