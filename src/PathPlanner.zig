const std = @import("std");
const map_data = @import("map_data.zig");
const Allocator = std.mem.Allocator;
const PointLookup = map_data.PointLookup;
const NodeAdjacencyMap = map_data.NodeAdjacencyMap;
const NodeId = map_data.NodeId;
const lin = @import("lin.zig");
const Point = lin.Point;
const Vec = lin.Vec;

// With momentum, the a star nodes are not singular positions, but nodes
// representing where we are and where we came from. This is necessary for each
// node to have individual turning costs.
//
// LinearAstarLookup allows us to represent all combinations of nodes with
// their neighbors without the cost of expensive hashmap lookups
//
// This happens to line up with the storage format of the NodeAdjacencyMap, so
// we yoink their internal data. If they change, we'll have to calculate
// offsets ourselves
fn LinearAstarLookup(comptime T: type) type {
    return struct {
        storage: []T,
        // reference to NodeAdjacencyMap starts
        segment_starts: []const u32,

        const Self = @This();
        fn init(alloc: Allocator, adjacency_map: *const NodeAdjacencyMap) !Self {
            return .{
                .storage = try alloc.alloc(T, adjacency_map.storage.len),
                .segment_starts = adjacency_map.segment_starts,
            };
        }

        fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.storage);
        }

        fn get(self: *Self, node: AStarNode) *T {
            return &self.storage[self.segment_starts[node.me.value] + node.came_from.value];
        }
    };
}

const GScores = LinearAstarLookup(f32);
const CameFrom = LinearAstarLookup(AStarNode);

alloc: Allocator,
points: *const PointLookup,
adjacency_map: *const NodeAdjacencyMap,
node_costs: *const map_data.NodePairCostMultiplierMap,
gscores: GScores,
came_from: CameFrom,
turning_cost: f32,
min_cost_multiplier: f32,
q: std.PriorityQueue(NodeWithFscore, void, order),
start: NodeId,
end: NodeId,

const PathPlanner = @This();

const NeighborIndex = struct {
    value: u8,
};

const AStarNode = struct {
    me: NodeId,
    came_from: NeighborIndex,
};

const NodeWithFscore = struct {
    id: AStarNode,
    fscore: f32,
};

pub fn init(alloc: Allocator, points: *const PointLookup, adjacency_map: *const NodeAdjacencyMap, node_costs: *const map_data.NodePairCostMultiplierMap, start: NodeId, end: NodeId, turning_cost: f32, min_cost_multiplier: f32) !PathPlanner {
    var gscores = try GScores.init(alloc, adjacency_map);
    @memset(gscores.storage, std.math.inf(f32));
    errdefer gscores.deinit(alloc);

    var came_from = try CameFrom.init(alloc, adjacency_map);
    errdefer came_from.deinit(alloc);

    var q = std.PriorityQueue(NodeWithFscore, void, PathPlanner.order).init(alloc, {});
    errdefer q.deinit();
    try q.ensureTotalCapacity(500);

    var ret = PathPlanner{
        .alloc = alloc,
        .points = points,
        .adjacency_map = adjacency_map,
        .node_costs = node_costs,
        .gscores = gscores,
        .came_from = came_from,
        .q = q,
        .start = start,
        .end = end,
        .turning_cost = turning_cost,
        .min_cost_multiplier = min_cost_multiplier,
    };

    try ret.q.add(.{
        .id = .{
            .me = start,
            .came_from = .{ .value = 0xff },
        },
        .fscore = ret.distance(start, end),
    });

    return ret;
}

pub fn deinit(self: *PathPlanner) void {
    self.gscores.deinit(self.alloc);
    self.came_from.deinit(self.alloc);
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

fn reconstructPath(self: *PathPlanner, end: AStarNode) ![]const NodeId {
    var ret = std.ArrayList(NodeId).init(self.alloc);
    defer ret.deinit();

    var it = end;
    while (it.me.value != self.start.value) {
        try ret.append(it.me);
        it = self.came_from.get(it).*;
    }
    return try ret.toOwnedSlice();
}

fn turningCost(self: *const PathPlanner, ab: Vec, bc: Vec) f32 {
    const ab_len = ab.length();
    const bc_len = bc.length();
    if (ab_len == 0 or bc_len == 0) {
        return 0.0;
    }

    const ab_norm = ab.mul(1.0 / ab_len);
    const bc_norm = bc.mul(1.0 / bc_len);

    const turning_amount = 0.5 - ab_norm.dot(bc_norm) / 2.0;
    return turning_amount * self.turning_cost;
}

fn cameFromPoint(self: *const PathPlanner, node: AStarNode, current_point: Point) Point {
    const current_neighbors = self.adjacency_map.getNeighbors(node.me);

    if (node.came_from.value >= current_neighbors.len) {
        return current_point;
    }

    return self.points.get(current_neighbors[node.came_from.value]);
}

fn updateNeighbor(self: *PathPlanner, current: AStarNode, neighbor: AStarNode, current_score: f32) !void {
    const neighbor_neighbors = self.adjacency_map.getNeighbors(neighbor.me);

    const current_point = self.points.get(current.me);
    const current_from_point = self.cameFromPoint(current, current_point);

    std.debug.assert(current.me.value == neighbor_neighbors[neighbor.came_from.value].value);

    const neighbor_point = self.points.get(neighbor.me);

    const this_turning_cost = self.turningCost(
        current_point.sub(current_from_point),
        neighbor_point.sub(current_point),
    );

    const node_cost = self.node_costs.getCost(current.me, neighbor.me);
    const tentative_score = current_score + self.distance(current.me, neighbor.me) * node_cost + this_turning_cost;
    const neighbor_entry = self.gscores.get(neighbor);
    if (tentative_score >= neighbor_entry.*) {
        return;
    }

    neighbor_entry.* = tentative_score;
    const fscore = tentative_score + self.distance(neighbor.me, self.end) * self.min_cost_multiplier;
    self.came_from.get(neighbor).* = current;

    const neighbor_w_fscore = NodeWithFscore{
        .id = neighbor,
        .fscore = fscore,
    };

    try self.q.add(neighbor_w_fscore);
}

fn findMyNeighborIndex(self: *const PathPlanner, me: NodeId, neighbor: NodeId) NeighborIndex {
    const neighbor_neighbors = self.adjacency_map.getNeighbors(neighbor);
    for (neighbor_neighbors, 0..) |node_id, i| {
        if (node_id.value == me.value) {
            return .{ .value = @intCast(i) };
        }
    }

    @panic("No neighbor");
}

fn step(self: *PathPlanner) !?[]const NodeId {
    const current_node_id = self.q.removeOrNull() orelse return error.NoPath;
    if (current_node_id.id.me.value == self.end.value) {
        return try self.reconstructPath(current_node_id.id);
    }

    const neighbors = self.adjacency_map.getNeighbors(current_node_id.id.me);
    var current_gscore = self.gscores.get(current_node_id.id).*;
    if (current_node_id.id.me.value == self.start.value) {
        current_gscore = 0.0;
    }

    for (neighbors) |neighbor| {
        const me_neighbor = self.findMyNeighborIndex(current_node_id.id.me, neighbor);
        const neighbor_id: AStarNode = .{
            .me = neighbor,
            .came_from = me_neighbor,
        };
        try self.updateNeighbor(current_node_id.id, neighbor_id, current_gscore);
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
