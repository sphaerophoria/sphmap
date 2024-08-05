const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("Metadata.zig");
const MouseTracker = @import("MouseTracker.zig");
const map_data = @import("map_data.zig");
const lin = @import("lin.zig");
const PathPlanner = @import("PathPlanner.zig");
const Renderer = @import("Renderer.zig");
const TextureRenderer = @import("TextureRenderer.zig");
const gl_utils = @import("gl_utils.zig");
const monitored_attributes = @import("monitored_attributes.zig");
const Gl = gl_utils.Gl;
const image_tile_data = @import("image_tile_data.zig");
const ImageTileData = image_tile_data.ImageTileData;
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
const WaysForTagPair = map_data.WaysForTagPair;

const App = @This();
const PointPairToWayMap = map_data.NodePairMap(WayId);

alloc: Allocator,
mouse_tracker: MouseTracker = .{},
metadata: *const Metadata,
image_tile_metadata: ImageTileData,
renderer: Renderer,
texture_renderer: TextureRenderer,
view_state: ViewState,
points: PointLookup,
ways: WayLookup,
string_table: StringTable,
adjacency_map: NodeAdjacencyMap,
way_buckets: WayBuckets,
path_start: ?NodeId = null,
closest_node: NodeId = NodeId{ .value = 0 },
turning_cost: f32 = 0.0,
textures: []i32,
monitored_attributes: monitored_attributes.MonitoredAttributeTracker,
point_pair_to_parent: PointPairToWayMap,
pp_viz: i32,
pp_viz_len: usize,
min_cost_multiplier: f32 = 1.0,
debug_way_finding: bool = false,
debug_point_neighbors: bool = false,
debug_path_finding: bool = false,

pub fn init(alloc: Allocator, aspect_val: f32, map_data_buf: []u8, metadata: *const Metadata, image_tile_metadata: ImageTileData) !*App {
    const split_data = map_data.MapDataComponents.init(map_data_buf, metadata.*);
    const meter_metdata = map_data.latLongToMeters(split_data.point_data, metadata.*);

    const textures = try alloc.alloc(i32, image_tile_metadata.len);
    errdefer alloc.free(textures);
    @memset(textures, -1);

    for (0..image_tile_metadata.len) |i| {
        gui.fetchTexture(i, image_tile_metadata[i].path.ptr, image_tile_metadata[i].path.len);
    }

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

    var point_pair_to_way = index_buffer_objs[3];
    defer point_pair_to_way.deinit();

    var point_pair_to_parent = PointPairToWayMap.init(alloc);
    errdefer point_pair_to_parent.deinit();

    const pp_viz = gui.glCreateBuffer();
    const pp_viz_len = try findSidewalkStreets(alloc, &point_lookup, &way_buckets, &adjacency_map, &point_pair_to_way, &point_pair_to_parent, &string_table, &way_lookup, metadata, pp_viz);

    var renderer = Renderer.init(split_data.point_data, split_data.index_data);
    renderer.bind().render(view_state);

    const texture_renderer = TextureRenderer.init();

    const ret = try alloc.create(App);
    errdefer alloc.destroy(ret);

    ret.* = .{
        .alloc = alloc,
        .adjacency_map = adjacency_map,
        .image_tile_metadata = image_tile_metadata,
        .renderer = renderer,
        .texture_renderer = texture_renderer,
        .metadata = metadata,
        .view_state = view_state,
        .points = point_lookup,
        .ways = way_lookup,
        .way_buckets = way_buckets,
        .point_pair_to_parent = point_pair_to_parent,
        .string_table = string_table,
        .pp_viz = pp_viz,
        .pp_viz_len = pp_viz_len,
        .textures = textures,
        // Sibling reference
        .monitored_attributes = undefined,
    };

    ret.monitored_attributes = monitored_attributes.MonitoredAttributeTracker.init(alloc, metadata, &ret.ways, &ret.point_pair_to_parent, &ret.adjacency_map);

    return ret;
}

pub fn deinit(self: *App) void {
    self.adjacency_map.deinit(self.alloc);
    self.ways.deinit(self.alloc);
    self.way_buckets.deinit();
    self.string_table.deinit(self.alloc);
    self.monitored_attributes.deinit();
    self.point_pair_to_parent.deinit();
    self.alloc.destroy(self);
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

    self.render();

    const bound_renderer = self.renderer.bind();

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
            bound_renderer.renderCoords(&.{ debug.dist_loc.x, debug.dist_loc.y }, Gl.POINTS);
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
        const neighbor_id = way.node_ids[calc.neighbor_segment];

        if (self.point_pair_to_parent.get(node_id, neighbor_id)) |parent| {
            std.log.debug("yes parent", .{});
            bound_renderer.inner.r.set(0);
            bound_renderer.inner.g.set(0);
            bound_renderer.inner.b.set(1);
            bound_renderer.renderSelectedWay(self.ways.get(parent));
        } else {
            std.log.debug("no parent", .{});
        }

        self.closest_node = node_id;
        gui.setNodeId(node_id.value);

        const neighbors = self.adjacency_map.getNeighbors(node_id);
        if (self.debug_point_neighbors) {
            bound_renderer.inner.point_size.set(10.0);
            bound_renderer.renderPoints(neighbors, Gl.POINTS);
        }
        bound_renderer.inner.r.set(0);
        bound_renderer.inner.g.set(1);
        bound_renderer.inner.b.set(1);
        bound_renderer.renderSelectedWay(self.ways.get(calc.min_way));
        if (self.debug_way_finding) {
            bound_renderer.renderCoords(&.{ self.view_state.center.x, self.view_state.center.y, calc.min_dist_loc.x, calc.min_dist_loc.y }, Gl.LINE_STRIP);
        }
        bound_renderer.inner.point_size.set(10.0);
        bound_renderer.renderPoints(&.{node_id}, Gl.POINTS);

        if (self.path_start) |path_start| {
            var pp = try PathPlanner.init(self.alloc, &self.points, &self.adjacency_map, &self.monitored_attributes.cost.node_costs, path_start, node_id, self.turning_cost, self.monitored_attributes.cost.min_cost_multiplier);
            defer pp.deinit();

            if (pp.run()) |new_path| {
                defer self.alloc.free(new_path);

                var seen_gscores = std.ArrayList(NodeId).init(self.alloc);
                defer seen_gscores.deinit();

                for (0..pp.gscores.segment_starts.len - 1) |i| {
                    const start = pp.gscores.segment_starts[i];
                    const end = pp.gscores.segment_starts[i + 1];
                    for (pp.gscores.storage[start..end]) |score| {
                        if (score != std.math.inf(f32)) {
                            try seen_gscores.append(.{ .value = @intCast(i) });
                            break;
                        }
                    }
                }

                bound_renderer.inner.r.set(1.0);
                bound_renderer.inner.g.set(0.0);
                bound_renderer.inner.b.set(0.0);
                bound_renderer.renderPoints(new_path, Gl.LINE_STRIP);
                if (self.debug_path_finding) {
                    bound_renderer.renderPoints(seen_gscores.items, Gl.POINTS);
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
    gui.glClearColor(0.0, 0.0, 0.0, 1.0);
    gui.glClear(Gl.COLOR_BUFFER_BIT);

    for (self.textures, 0..) |tex, i| {
        var bound_texture_renderer = self.texture_renderer.bind();
        const screen_space = tileLocScreenSpace(self.image_tile_metadata[i], self.view_state, self.metadata.*);
        bound_texture_renderer.render(
            tex,
            screen_space.center,
            screen_space.scale,
        );
    }

    const bound_renderer = self.renderer.bind();
    bound_renderer.render(self.view_state);

    for (self.monitored_attributes.rendering.attributes.items) |monitored| {
        bound_renderer.inner.r.set(monitored.color.r);
        bound_renderer.inner.g.set(monitored.color.g);
        bound_renderer.inner.b.set(monitored.color.b);
        bound_renderer.renderIndexBuffer(monitored.index_buffer, monitored.index_buffer_len, Gl.LINE_STRIP);
    }
}

pub fn startPath(self: *App) void {
    self.path_start = self.closest_node;
}

pub fn stopPath(self: *App) void {
    self.path_start = null;
}

pub fn registerTexture(self: *App, id: usize, tex: i32) !void {
    self.textures[id] = tex;
    self.render();
}

pub fn monitorWayAttribute(self: *App, k: [*]const u8, v: [*]const u8) !void {
    const k_id = self.string_table.findByPointerAddress(k);
    const v_id = self.string_table.findByPointerAddress(v);

    const attribute_id = try self.monitored_attributes.push(k_id, v_id);
    const k_full = self.string_table.get(k_id);
    const v_full = self.string_table.get(v_id);

    gui.pushMonitoredAttribute(attribute_id, k_full.ptr, k_full.len, v_full.ptr, v_full.len);
}

pub fn removeMonitoredAttribute(self: *App, id: usize) !void {
    try self.monitored_attributes.remove(id);
}

pub fn setMonitoredCostMultiplier(self: *App, id: usize, multiplier: f32) !void {
    self.monitored_attributes.cost.update(id, multiplier);
}

fn wayParentScore(way: Way, point_lookup: *const PointLookup, a: Point, b: Point) f32 {
    var min_score = std.math.inf(f32);

    const ab = a.sub(b).normalized();

    for (0..way.node_ids.len - 1) |i| {
        const way_a = way.node_ids[i];
        const way_b = way.node_ids[i + 1];
        const way_point_a = point_lookup.get(way_a);
        const way_point_b = point_lookup.get(way_b);

        const way_ab = way_point_a.sub(way_point_b).normalized();
        const dot = ab.dot(way_ab);
        var parallel_score: f32 = undefined;
        if (dot == 0) {
            parallel_score = std.math.inf(f32);
        } else {
            // [0, 1]
            // [inf, 0]
            parallel_score = (@abs(1 / dot) - 1) * 5;
        }

        // Maybe we should sum min distances to way
        var dist_score = lin.closestPointOnLine(a, way_point_a, way_point_b).sub(a).length();
        dist_score += lin.closestPointOnLine(b, way_point_a, way_point_b).sub(b).length();

        min_score = @min(dist_score + parallel_score, min_score);
    }

    return min_score;
}

// FIXME: I odn't like the idea of hardcoding k/v pairs in app, but whatever
// FIXME: WTF is going on here
// FIXME: Awful API
fn findSidewalkStreets(alloc: Allocator, point_lookup: *const PointLookup, way_buckets: *const WayBuckets, adjacency_map: *const NodeAdjacencyMap, point_pair_to_way: *const PointPairToWayMap, point_pair_to_parent: *PointPairToWayMap, string_table: *const StringTable, ways: *const WayLookup, metadata: *const Metadata, ebo: i32) !usize {
    var index_buffer = std.ArrayList(u32).init(alloc);
    defer index_buffer.deinit();

    const sidewalk_k = string_table.findByStringContent("highway");
    const sidewalk_v = string_table.findByStringContent("footway");

    for (0..point_lookup.numPoints()) |node_id_usize| {
        const node_id = NodeId{ .value = @intCast(node_id_usize) };
        const point = point_lookup.get(node_id);
        const bucket = way_buckets.get(point.y, point.x);
        for (adjacency_map.getNeighbors(node_id)) |neighbor_id| {
            const way_id = point_pair_to_way.get(node_id, neighbor_id) orelse @panic("no way for point pair");
            const way_tags = metadata.way_tags[way_id.value];
            if (!map_data.wayTagsContains(way_tags, sidewalk_k, sidewalk_v)) {
                continue;
            }
            try index_buffer.appendSlice(&.{ node_id.value, neighbor_id.value, 0xffffffff });
            const neighbor_point = point_lookup.get(neighbor_id);

            var min_way_id: WayId = undefined;
            var min_way_score = std.math.inf(f32);
            for (bucket) |other_way_id| {
                const other_way_tags = metadata.way_tags[other_way_id.value];
                if (map_data.wayTagsContains(other_way_tags, sidewalk_k, sidewalk_v)) {
                    continue;
                }

                const score = wayParentScore(ways.get(other_way_id), point_lookup, point, neighbor_point);
                if (score < min_way_score) {
                    min_way_score = score;
                    min_way_id = other_way_id;
                }
            }

            if (min_way_score != std.math.inf(f32)) {
                try point_pair_to_parent.put(node_id, neighbor_id, min_way_id);
            }
        }
    }

    gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, ebo);
    gui.glBufferData(
        Gl.ELEMENT_ARRAY_BUFFER,
        @ptrCast(index_buffer.items.ptr),
        index_buffer.items.len * 4,
        Gl.STATIC_DRAW,
    );

    return index_buffer.items.len;
}

fn parseIndexBuffer(
    alloc: Allocator,
    point_lookup: PointLookup,
    width: f32,
    height: f32,
    index_buffer: []const u32,
) !struct { WayLookup, WayBuckets, NodeAdjacencyMap, PointPairToWayMap } {
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

    var point_pair_to_way = map_data.NodePairMap(WayId).init(alloc);
    errdefer point_pair_to_way.deinit();

    while (it.next()) |idx_buf_range| {
        defer way_id.value += 1;
        const way = Way.fromIndexRange(idx_buf_range, index_buffer);
        try ways.append(way);
        for (way.node_ids, 0..) |node_id, i| {
            if (i > 0) {
                try node_neighbors[node_id.value].put(tmp_alloc, way.node_ids[i - 1], {});
            }

            if (i < way.node_ids.len - 1) {
                const neighbor = way.node_ids[i + 1];
                try node_neighbors[node_id.value].put(tmp_alloc, neighbor, {});

                try point_pair_to_way.put(node_id, neighbor, way_id);
            }

            const gps_pos = point_lookup.get(node_id);
            try way_buckets.push(way_id, gps_pos.y, gps_pos.x);
        }
    }

    const node_adjacency_map = try NodeAdjacencyMap.init(alloc, node_neighbors);
    const way_lookup = WayLookup{ .ways = try ways.toOwnedSlice() };
    return .{ way_lookup, way_buckets, node_adjacency_map, point_pair_to_way };
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
    neighbor_segment: usize,

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
            .neighbor_segment = undefined,
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
                    self.neighbor_segment = self.segment_idx;
                } else {
                    self.min_way_segment = self.segment_idx;
                    self.neighbor_segment = self.segment_idx + 1;
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

    fn latLongToBucket(self: *const WayBuckets, lat: f32, lon: f32) BucketId {
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

    fn get(self: *const WayBuckets, lat: f32, long: f32) []WayId {
        const bucket = self.latLongToBucket(lat, long);
        return self.buckets[bucket.value].keys();
    }
};

const TileLocation = struct {
    center: Point,
    scale: Vec,
};

fn tileLocScreenSpace(item_metadata: image_tile_data.Item, view_state: ViewState, metadata: Metadata) TileLocation {
    const converter = map_data.CoordinateSpaceConverter.init(&metadata);
    const x_m = converter.lonToM(item_metadata.center[0]);
    const y_m = converter.latToM(item_metadata.center[1]);
    const x_s = (x_m - view_state.center.x) * view_state.zoom;
    const y_s = (y_m - view_state.center.y) * view_state.zoom * view_state.aspect;

    const w = item_metadata.size[0] / converter.width_deg * converter.widthM() * view_state.zoom / 2;
    const h = item_metadata.size[1] / converter.height_deg * converter.heightM() * view_state.zoom / 2 * view_state.aspect;

    return .{
        .center = .{
            .x = x_s,
            .y = y_s,
        },
        .scale = .{
            .x = w,
            .y = h,
        },
    };
}
