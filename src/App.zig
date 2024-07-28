const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("Metadata.zig");
const MouseTracker = @import("MouseTracker.zig");
const map_data = @import("map_data.zig");
const lin = @import("lin.zig");
const PathPlanner = @import("PathPlanner.zig");
const Renderer = @import("Renderer.zig");
const Point = lin.Point;
const Vec = lin.Vec;
const MapPos = lin.Point;
const PointLookup = map_data.PointLookup;
const NodeAdjacencyMap = map_data.NodeAdjacencyMap;
const NodeId = map_data.NodeId;
const WayLookup = map_data.WayLookup;
const Way = map_data.Way;
const WayId = map_data.WayId;
const StringTable = map_data.StringTable;
const gui = @import("gui_bindings.zig");
const ViewState = Renderer.ViewState;

const App = @This();

alloc: Allocator,
mouse_tracker: MouseTracker = .{},
metadata: *const Metadata,
renderer: Renderer,
view_state: ViewState,
points: PointLookup,
ways: WayLookup,
string_table: StringTable,
adjacency_map: NodeAdjacencyMap,
way_buckets: WayBuckets,
path_start: ?NodeId = null,
closest_node: NodeId = NodeId{ .value = 0 },
debug_way_finding: bool = false,
debug_point_neighbors: bool = false,
debug_path_finding: bool = false,

pub fn init(alloc: Allocator, aspect_val: f32, map_data_buf: []u8, metadata: *const Metadata) !App {
    const split_data = map_data.MapDataComponents.init(map_data_buf, metadata.*);
    const meter_metdata = map_data.latLongToMeters(split_data.point_data, metadata.*);

    var string_table = try StringTable.init(alloc, split_data.string_table_data);
    errdefer string_table.deinit(alloc);

    const view_state = ViewState{
        .center = .{
            .x = meter_metdata.width / 2.0,
            .y = meter_metdata.height / 2.0,
        },
        .zoom = 2.0 / meter_metdata.width,
        .aspect = aspect_val,
    };

    const point_lookup = PointLookup{ .points = split_data.point_data };

    const index_buffer_objs = try parseIndexBuffer(alloc, point_lookup, meter_metdata.width, meter_metdata.height, split_data.index_data);
    var way_lookup = index_buffer_objs[0];
    errdefer way_lookup.deinit(alloc);

    var way_buckets = index_buffer_objs[1];
    errdefer way_buckets.deinit();

    var adjacency_map = index_buffer_objs[2];
    errdefer adjacency_map.deinit(alloc);

    var renderer = Renderer.init(split_data.point_data, split_data.index_data);
    renderer.bind().render(view_state);

    return .{
        .alloc = alloc,
        .adjacency_map = adjacency_map,
        .renderer = renderer,
        .metadata = metadata,
        .view_state = view_state,
        .points = point_lookup,
        .ways = way_lookup,
        .way_buckets = way_buckets,
        .string_table = string_table,
    };
}

pub fn deinit(self: *App) void {
    self.adjacency_map.deinit(self.alloc);
    self.ways.deinit(self.alloc);
    self.way_buckets.deinit();
    self.string_table.deinit(self.alloc);
}

pub fn onMouseDown(self: *App, x: f32, y: f32) void {
    self.mouse_tracker.onDown(x, y);
}

pub fn onMouseUp(self: *App) void {
    self.mouse_tracker.onUp();
}

pub fn onMouseMove(self: *App, x: f32, y: f32) !void {
    if (self.mouse_tracker.down) {
        const movement = self.mouse_tracker.getMovement(x, y).mul(2.0 / self.view_state.zoom);
        const new_pos = self.view_state.center.add(movement);

        // floating point imprecision may result in no actual movement of the
        // screen center. We should _not_ recenter in this case as it results
        // in slow mouse movements never moving the screen
        if (new_pos.y != self.view_state.center.y) {
            self.mouse_tracker.pos.y = y;
        }

        if (new_pos.x != self.view_state.center.x) {
            self.mouse_tracker.pos.x = x;
        }

        self.view_state.center = new_pos;
    }

    const potential_ways = self.way_buckets.get(
        self.view_state.center.y,
        self.view_state.center.x,
    );

    const bound_renderer = self.renderer.bind();
    bound_renderer.render(self.view_state);

    var calc = ClosestWayCalculator.init(
        self.view_state.center,
        self.ways,
        potential_ways,
        self.points,
    );

    if (self.debug_way_finding) {
        bound_renderer.inner.r.set(0.0);
        bound_renderer.inner.g.set(1.0);
        bound_renderer.inner.b.set(1.0);
        while (calc.step()) |debug| {
            bound_renderer.inner.point_size.set(std.math.pow(f32, std.math.e, -debug.dist * 0.05) * 50.0);
            bound_renderer.renderCoords(&.{ debug.dist_loc.x, debug.dist_loc.y }, Renderer.Gl.POINTS);
        }
    } else {
        while (calc.step()) |_| {}
    }

    gui.clearTags();
    if (calc.min_way.value < self.metadata.way_tags.len) {
        const way_tags = self.metadata.way_tags[calc.min_way.value];
        for (0..way_tags[0].len) |i| {
            const key = self.string_table.get(way_tags[0][i]);
            const val = self.string_table.get(way_tags[1][i]);
            gui.pushTag(key.ptr, key.len, val.ptr, val.len);
        }
    }

    if (calc.min_way.value < self.ways.ways.len) {
        bound_renderer.inner.r.set(0.0);
        bound_renderer.inner.g.set(1.0);
        bound_renderer.inner.b.set(1.0);
        const way = self.ways.get(calc.min_way);
        if (calc.min_way_segment > way.node_ids.len) {
            std.log.err("invalid segment", .{});
            unreachable;
        }
        const node_id = way.node_ids[calc.min_way_segment];
        self.closest_node = node_id;
        gui.setNodeId(node_id.value);

        const neighbors = self.adjacency_map.getNeighbors(node_id);
        if (self.debug_point_neighbors) {
            bound_renderer.inner.point_size.set(10.0);
            bound_renderer.renderPoints(neighbors, Renderer.Gl.POINTS);
        }
        bound_renderer.renderSelectedWay(self.ways.get(calc.min_way));
        if (self.debug_way_finding) {
            bound_renderer.renderCoords(&.{ self.view_state.center.x, self.view_state.center.y, calc.min_dist_loc.x, calc.min_dist_loc.y }, Renderer.Gl.LINE_STRIP);
        }
        bound_renderer.inner.r.set(1.0);
        bound_renderer.inner.g.set(1.0);
        bound_renderer.inner.b.set(1.0);
        bound_renderer.inner.point_size.set(10.0);
        bound_renderer.renderPoints(&.{node_id}, Renderer.Gl.POINTS);

        if (self.path_start) |path_start| {
            var pp = try PathPlanner.init(self.alloc, &self.points, &self.adjacency_map, path_start, node_id);
            defer pp.deinit();

            if (pp.run()) |new_path| {
                defer self.alloc.free(new_path);

                var seen_gscores = std.ArrayList(NodeId).init(self.alloc);
                defer seen_gscores.deinit();

                for (pp.gscores, 0..) |score, i| {
                    if (score != std.math.inf(f32)) {
                        try seen_gscores.append(NodeId{ .value = @intCast(i) });
                    }
                }

                bound_renderer.inner.r.set(1.0);
                bound_renderer.inner.g.set(0.0);
                bound_renderer.inner.b.set(0.0);
                bound_renderer.renderPoints(new_path, Renderer.Gl.LINE_STRIP);
                if (self.debug_path_finding) {
                    bound_renderer.renderPoints(seen_gscores.items, Renderer.Gl.POINTS);
                }
            } else |e| {
                std.log.err("err: {any} {d} {d}", .{ e, path_start.value, node_id.value });
            }
        }
    }
}

pub fn setAspect(self: *App, aspect: f32) void {
    self.view_state.aspect = aspect;
    self.render();
}

pub fn zoomIn(self: *App) void {
    self.view_state.zoom *= 2.0;
    self.render();
}

pub fn zoomOut(self: *App) void {
    self.view_state.zoom *= 0.5;
    self.render();
}

pub fn render(self: *App) void {
    const bound_renderer = self.renderer.bind();
    bound_renderer.render(self.view_state);
}

pub fn startPath(self: *App) void {
    self.path_start = self.closest_node;
}

pub fn stopPath(self: *App) void {
    self.path_start = null;
}

fn parseIndexBuffer(
    alloc: Allocator,
    point_lookup: PointLookup,
    width: f32,
    height: f32,
    index_buffer: []const u32,
) !struct { WayLookup, WayBuckets, NodeAdjacencyMap } {
    var ways = std.ArrayList(Way).init(alloc);
    defer ways.deinit();

    var way_buckets = try WayBuckets.init(alloc, width, height);
    var it = map_data.IndexBufferIt.init(index_buffer);
    var way_id: WayId = .{ .value = 0 };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp_alloc = arena.allocator();
    var node_neighbors = try tmp_alloc.alloc(std.AutoArrayHashMapUnmanaged(NodeId, void), point_lookup.numPoints());
    @memset(node_neighbors, std.AutoArrayHashMapUnmanaged(NodeId, void){});

    while (it.next()) |idx_buf_range| {
        defer way_id.value += 1;
        const way = Way.fromIndexRange(idx_buf_range, index_buffer);
        try ways.append(way);
        for (way.node_ids, 0..) |node_id, i| {
            if (i > 0) {
                try node_neighbors[node_id.value].put(tmp_alloc, way.node_ids[i - 1], {});
            }

            if (i < way.node_ids.len - 1) {
                try node_neighbors[node_id.value].put(tmp_alloc, way.node_ids[i + 1], {});
            }

            const gps_pos = point_lookup.get(node_id);
            try way_buckets.push(way_id, gps_pos.y, gps_pos.x);
        }
    }

    const node_adjacency_map = try NodeAdjacencyMap.init(alloc, node_neighbors);
    const way_lookup = WayLookup{ .ways = try ways.toOwnedSlice() };
    return .{ way_lookup, way_buckets, node_adjacency_map };
}

const ClosestWayCalculator = struct {
    // Static external references
    points: PointLookup,
    ways: WayLookup,
    potential_ways: []const WayId,
    pos: MapPos,

    // Iteration data
    way_idx: usize,
    segment_idx: usize,

    // Tracking data/output
    min_dist: f32,
    min_dist_loc: MapPos,
    min_way: WayId,
    min_way_segment: usize,

    const DebugInfo = struct {
        dist: f32,
        dist_loc: MapPos,
    };

    fn init(p: MapPos, ways: WayLookup, potential_ways: []const WayId, points: PointLookup) ClosestWayCalculator {
        return ClosestWayCalculator{
            .ways = ways,
            .potential_ways = potential_ways,
            .way_idx = 0,
            .points = points,
            .segment_idx = 0,
            .min_dist = std.math.floatMax(f32),
            .min_dist_loc = undefined,
            .min_way = undefined,
            .min_way_segment = undefined,
            .pos = p,
        };
    }

    fn step(self: *ClosestWayCalculator) ?DebugInfo {
        while (true) {
            if (self.way_idx >= self.potential_ways.len) {
                return null;
            }

            const way_points = self.ways.get(self.potential_ways[self.way_idx]).node_ids;

            if (self.segment_idx >= way_points.len - 1) {
                self.segment_idx = 0;
                self.way_idx += 1;

                continue;
            }

            defer self.segment_idx += 1;

            const a_point_id = way_points[self.segment_idx];
            const b_point_id = way_points[self.segment_idx + 1];

            const a = self.points.get(a_point_id);
            const b = self.points.get(b_point_id);

            const dist_loc = lin.closestPointOnLine(self.pos, a, b);
            const dist = self.pos.sub(dist_loc).length();

            const ret = DebugInfo{
                .dist = dist,
                .dist_loc = dist_loc,
            };

            if (dist < self.min_dist) {
                self.min_dist = dist;
                self.min_way = self.potential_ways[self.way_idx];
                self.min_dist_loc = ret.dist_loc;
                const ab_len = b.sub(a).length();
                const ap_len = self.pos.sub(a).length();
                if (ap_len / ab_len > 0.5) {
                    self.min_way_segment = self.segment_idx + 1;
                } else {
                    self.min_way_segment = self.segment_idx;
                }
            }

            return ret;
        }
    }
};

const WayBuckets = struct {
    const x_buckets = 100;
    const y_buckets = 100;
    const BucketId = struct {
        value: usize,
    };

    const WayIdSet = std.AutoArrayHashMapUnmanaged(WayId, void);
    alloc: Allocator,
    buckets: []WayIdSet,
    width: f32,
    height: f32,

    fn init(alloc: Allocator, width: f32, height: f32) !WayBuckets {
        const buckets = try alloc.alloc(WayIdSet, x_buckets * y_buckets);
        for (buckets) |*bucket| {
            bucket.* = .{};
        }

        return .{
            .alloc = alloc,
            .buckets = buckets,
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: *WayBuckets) void {
        for (self.buckets) |*bucket| {
            bucket.deinit(self.alloc);
        }
        self.alloc.free(self.buckets);
    }

    fn latLongToBucket(self: *WayBuckets, lat: f32, lon: f32) BucketId {
        const row_f = lat / self.height * y_buckets;
        const col_f = lon / self.width * x_buckets;
        var row: usize = @intFromFloat(row_f);
        var col: usize = @intFromFloat(col_f);

        if (row >= x_buckets) {
            row = x_buckets - 1;
        }

        if (col >= y_buckets) {
            col = y_buckets - 1;
        }
        return .{ .value = row * x_buckets + col };
    }

    fn push(self: *WayBuckets, way_id: WayId, lat: f32, long: f32) !void {
        const idx = self.latLongToBucket(lat, long);
        try self.buckets[idx.value].put(self.alloc, way_id, {});
    }

    fn get(self: *WayBuckets, lat: f32, long: f32) []WayId {
        const bucket = self.latLongToBucket(lat, long);
        return self.buckets[bucket.value].keys();
    }
};
