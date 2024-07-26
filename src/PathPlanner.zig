const std = @import("std");
const map_data = @import("map_data.zig");
const Allocator = std.mem.Allocator;
const PointLookup = map_data.PointLookup;
const NodeAdjacencyMap = map_data.NodeAdjacencyMap;
const NodeId = map_data.NodeId;

alloc: Allocator,
points: *const PointLookup,
adjacency_map: *const NodeAdjacencyMap,
gscores: []f32,
came_from: []NodeId,
q: std.PriorityQueue(NodeWithFscore, void, order),
start: NodeId,
end: NodeId,

const PathPlanner = @This();

const NodeWithFscore = struct {
    id: NodeId,
    fscore: f32,
};

pub fn init(alloc: Allocator, points: *const PointLookup, adjacency_map: *const NodeAdjacencyMap, start: NodeId, end: NodeId) !PathPlanner {
    const num_points = points.numPoints();

    const gscores = try alloc.alloc(f32, num_points);
    errdefer alloc.free(gscores);
    @memset(gscores, std.math.inf(f32));
    gscores[start.value] = 0;

    const came_from = try alloc.alloc(NodeId, points.numPoints());
    errdefer alloc.free(came_from);

    var q = std.PriorityQueue(NodeWithFscore, void, PathPlanner.order).init(alloc, {});
    errdefer q.deinit();
    try q.ensureTotalCapacity(500);

    var ret = PathPlanner{
        .alloc = alloc,
        .points = points,
        .adjacency_map = adjacency_map,
        .gscores = gscores,
        .came_from = came_from,
        .q = q,
        .start = start,
        .end = end,
    };

    try ret.q.add(.{
        .id = start,
        .fscore = ret.distance(start, end),
    });

    return ret;
}

pub fn deinit(self: *PathPlanner) void {
    self.alloc.free(self.gscores);
    self.alloc.free(self.came_from);
    self.q.deinit();
}

fn distance(self: *PathPlanner, a_id: NodeId, b_id: NodeId) f32 {
    const a = self.points.get(a_id);
    const b = self.points.get(b_id);

    return b.sub(a).length();
}

fn order(_: void, a: NodeWithFscore, b: NodeWithFscore) std.math.Order {
    return std.math.order(a.fscore, b.fscore);
}

fn reconstructPath(self: *PathPlanner) ![]const NodeId {
    var ret = std.ArrayList(NodeId).init(self.alloc);
    defer ret.deinit();

    var it = self.end;
    while (it.value != self.start.value) {
        try ret.append(it);
        it = self.came_from[it.value];
    }
    return try ret.toOwnedSlice();
}

fn updateNeighbor(self: *PathPlanner, current: NodeId, neighbor: NodeId, current_score: f32) !void {
    const tentative_score = current_score + self.distance(current, neighbor);
    if (tentative_score >= self.gscores[neighbor.value]) {
        return;
    }

    self.gscores[neighbor.value] = tentative_score;
    const fscore = tentative_score + self.distance(neighbor, self.end);
    self.came_from[neighbor.value] = current;

    const neighbor_w_fscore = NodeWithFscore{
        .id = neighbor,
        .fscore = fscore,
    };

    try self.q.add(neighbor_w_fscore);
}

fn step(self: *PathPlanner) !?[]const NodeId {
    const current_node_id = self.q.removeOrNull() orelse return error.NoPath;
    if (current_node_id.id.value == self.end.value) {
        return try self.reconstructPath();
    }

    const neighbors = self.adjacency_map.getNeighbors(current_node_id.id);
    const current_gscore = self.gscores[current_node_id.id.value];

    for (neighbors) |neighbor| {
        try self.updateNeighbor(current_node_id.id, neighbor, current_gscore);
    }

    return null;
}

pub fn run(self: *PathPlanner) ![]const NodeId {
    while (true) {
        if (try self.step()) |val| {
            return val;
        }
    }
}
