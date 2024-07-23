const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("Metadata.zig");
const lin = @import("lin.zig");
const Point = lin.Point;
const Vec = lin.Vec;
const MapPos = lin.Point;

const App = @This();

const NodeId = struct {
    value: u32,
};

const WayId = struct {
    value: usize,
};

const WayLookup = struct {
    ways: []const Way,

    fn deinit(self: *WayLookup, alloc: Allocator) void {
        alloc.free(self.ways);
    }

    fn get(self: *const WayLookup, id: WayId) Way {
        return self.ways[id.value];
    }
};

const IndexRange = struct {
    start: usize,
    end: usize,
};

const NodeAdjacencyMap = struct {
    // Where in storage this node's neighbors are. Indexed by NodeId
    segment_starts: []usize,
    // All neighbors for all nodes, Each node's neighbors are contiguous
    storage: []const NodeId,

    fn init(alloc: Allocator, node_neighbors: []std.AutoArrayHashMapUnmanaged(NodeId, void)) !NodeAdjacencyMap {
        var storage = std.ArrayList(NodeId).init(alloc);
        defer storage.deinit();

        var segment_starts = std.ArrayList(usize).init(alloc);
        defer segment_starts.deinit();

        for (node_neighbors) |neighbors| {
            try segment_starts.append(storage.items.len);
            try storage.appendSlice(neighbors.keys());
        }

        return .{
            .storage = try storage.toOwnedSlice(),
            .segment_starts = try segment_starts.toOwnedSlice(),
        };
    }

    fn deinit(self: *NodeAdjacencyMap, alloc: Allocator) void {
        alloc.free(self.storage);
        alloc.free(self.segment_starts);
    }

    fn getNeighbors(self: *NodeAdjacencyMap, node: NodeId) []const NodeId {
        const start = self.segment_starts[node.value];
        const end = if (node.value + 1 == self.segment_starts.len)
            self.storage.len
        else
            self.segment_starts[node.value + 1];

        return self.storage[start..end];
    }
};

const Way = struct {
    node_ids: []const NodeId,

    fn fromIndexRange(range: IndexRange, index_buf: []const u32) Way {
        return .{
            .node_ids = @ptrCast(index_buf[range.start..range.end]),
        };
    }

    fn indexRange(self: *const Way, index_buffer: []const u32) IndexRange {
        const node_ids_ptr: usize = @intFromPtr(self.node_ids.ptr);
        const index_buffer_ptr: usize = @intFromPtr(index_buffer.ptr);
        const start = (node_ids_ptr - index_buffer_ptr) / @sizeOf(u32);
        const end = start + self.node_ids.len;
        return .{
            .start = start,
            .end = end,
        };
    }
};

const PointLookup = struct {
    points: []const f32,

    fn numPoints(self: *const PointLookup) usize {
        return self.points.len / 2;
    }

    fn get(self: *const PointLookup, id: NodeId) MapPos {
        return .{
            .x = self.points[id.value * 2],
            .y = self.points[id.value * 2 + 1],
        };
    }
};

const ViewState = struct {
    center: MapPos,
    zoom: f32,
    aspect: f32,
};

alloc: Allocator,
mouse_tracker: MouseTracker = .{},
metadata: *const Metadata,
renderer: Renderer,
view_state: ViewState,
points: PointLookup,
ways: WayLookup,
adjacency_map: NodeAdjacencyMap,
way_buckets: WayBuckets,
debug_way_finding: bool = false,
debug_point_neighbors: bool = false,

pub fn init(alloc: Allocator, aspect_val: f32, map_data: []u8, metadata: *const Metadata) !App {
    const point_data: []f32 = @alignCast(std.mem.bytesAsSlice(f32, map_data[0..@intCast(metadata.end_nodes)]));

    const center_lat = (metadata.min_lat + metadata.max_lat) / 2.0;
    const center_lon = (metadata.min_lon + metadata.max_lon) / 2.0;

    const lat_step = 111132.92 - 559.82 * @cos(2 * center_lat) + 1.175 * @cos(4 * center_lat) - 0.0023 * @cos(6 * center_lat);
    const lon_step = 111412.84 * @cos(center_lon) - 93.5 * @cos(3 * center_lon) + 0.118 * @cos(5 * center_lon);

    const height = lat_step * (metadata.max_lat - metadata.min_lat);
    const width = lon_step * (metadata.max_lon - metadata.min_lon);

    for (0..point_data.len / 2) |i| {
        const lon = &point_data[i * 2];
        const lat = &point_data[i * 2 + 1];

        lat.* = lat_step * (metadata.max_lat - lat.*);
        lon.* = lon_step * (lon.* - metadata.min_lon);
    }

    const index_data: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, map_data[@intCast(metadata.end_nodes)..]));

    const view_state = ViewState{
        .center = .{
            .x = width / 2.0,
            .y = height / 2.0,
        },
        .zoom = 2.0 / width,
        .aspect = aspect_val,
    };

    const point_lookup = PointLookup{ .points = point_data };

    const index_buffer_objs = try parseIndexBuffer(alloc, point_lookup, width, height, index_data);
    var way_lookup = index_buffer_objs[0];
    errdefer way_lookup.deinit(alloc);

    var way_buckets = index_buffer_objs[1];
    errdefer way_buckets.deinit();

    var adjacency_map = index_buffer_objs[2];
    errdefer adjacency_map.deinit(alloc);

    var renderer = Renderer.init(point_data, index_data);
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
    };
}

pub fn deinit(self: *App) void {
    self.adjacency_map.deinit(self.alloc);
    self.ways.deinit(self.alloc);
    self.way_buckets.deinit();
}

pub fn onMouseDown(self: *App, x: f32, y: f32) void {
    self.mouse_tracker.onDown(x, y);
}

pub fn onMouseUp(self: *App) void {
    self.mouse_tracker.onUp();
}

pub fn onMouseMove(self: *App, x: f32, y: f32) void {
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
        bound_renderer.inner.color.set(0.0);
        while (calc.step()) |debug| {
            bound_renderer.inner.point_size.set(std.math.pow(f32, std.math.e, -debug.dist * 0.05) * 50.0);
            bound_renderer.renderCoords(&.{ debug.dist_loc.x, debug.dist_loc.y }, Gl.POINTS);
        }
    } else {
        while (calc.step()) |_| {}
    }

    js.clearTags();
    if (calc.min_way.value < self.metadata.way_tags.len) {
        for (self.metadata.way_tags[calc.min_way.value]) |tag| {
            js.pushTag(tag.key.ptr, tag.key.len, tag.val.ptr, tag.val.len);
        }
    }

    if (calc.min_way.value < self.ways.ways.len) {
        bound_renderer.inner.color.set(0.0);
        const way = self.ways.get(calc.min_way);
        if (calc.min_way_segment > way.node_ids.len) {
            std.log.err("invalid segment", .{});
            unreachable;
        }
        const node_id = way.node_ids[calc.min_way_segment];

        const neighbors = self.adjacency_map.getNeighbors(node_id);
        if (self.debug_point_neighbors) {
            bound_renderer.renderPoints(neighbors, 10.0);
        }
        bound_renderer.renderSelectedWay(self.ways.get(calc.min_way));
        if (self.debug_way_finding) {
            bound_renderer.renderCoords(&.{ self.view_state.center.x, self.view_state.center.y, calc.min_dist_loc.x, calc.min_dist_loc.y }, Gl.LINE_STRIP);
        }
        bound_renderer.inner.color.set(1.0);
        bound_renderer.renderPoints(&.{node_id}, 10.0);
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
    self.renderer.bind().render(self.view_state);
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
    var it = IndexBufferIt.init(index_buffer);
    var way_id: WayId = .{ .value = 0 };

    var node_neighbors = try alloc.alloc(std.AutoArrayHashMapUnmanaged(NodeId, void), point_lookup.numPoints());
    @memset(node_neighbors, std.AutoArrayHashMapUnmanaged(NodeId, void){});
    defer {
        for (node_neighbors) |*item| {
            item.deinit(alloc);
        }
        alloc.free(node_neighbors);
    }

    while (it.next()) |idx_buf_range| {
        defer way_id.value += 1;
        const way = Way.fromIndexRange(idx_buf_range, index_buffer);
        try ways.append(way);
        for (way.node_ids, 0..) |node_id, i| {
            if (i > 0) {
                try node_neighbors[node_id.value].put(alloc, way.node_ids[i - 1], {});
            }

            if (i < way.node_ids.len - 1) {
                try node_neighbors[node_id.value].put(alloc, way.node_ids[i + 1], {});
            }

            const gps_pos = point_lookup.get(node_id);
            try way_buckets.push(way_id, gps_pos.y, gps_pos.x);
        }
    }

    const node_adjacency_map = try NodeAdjacencyMap.init(alloc, node_neighbors);
    const way_lookup = WayLookup{ .ways = try ways.toOwnedSlice() };
    return .{ way_lookup, way_buckets, node_adjacency_map };
}

const NormalizedPosition = Point;
const NormalizedOffset = Vec;

const MouseTracker = struct {
    down: bool = false,
    pos: NormalizedPosition = undefined,

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
};

const FloatUniform = struct {
    loc: i32,

    fn init(program: i32, key: []const u8) FloatUniform {
        const loc = js.glGetUniformLoc(program, key.ptr, key.len);
        return .{
            .loc = loc,
        };
    }

    fn set(self: *const FloatUniform, val: f32) void {
        js.glUniform1f(self.loc, val);
    }
};

const js = struct {
    extern fn compileLinkProgram(vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) i32;
    extern fn glCreateVertexArray() i32;
    extern fn glCreateBuffer() i32;
    extern fn glVertexAttribPointer(index: i32, size: i32, type: i32, normalized: bool, stride: i32, offs: i32) void;
    extern fn glEnableVertexAttribArray(index: i32) void;
    extern fn glBindBuffer(target: i32, id: i32) void;
    extern fn glBufferData(target: i32, ptr: [*]const u8, len: usize, usage: i32) void;
    extern fn glBindVertexArray(vao: i32) void;
    extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
    extern fn glClear(mask: i32) void;
    extern fn glUseProgram(program: i32) void;
    extern fn glDrawArrays(mode: i32, first: i32, last: i32) void;
    extern fn glDrawElements(mode: i32, count: i32, type: i32, offs: i32) void;
    extern fn glGetUniformLoc(program: i32, name: [*]const u8, name_len: usize) i32;
    extern fn glUniform1f(loc: i32, val: f32) void;

    extern fn clearTags() void;
    extern fn pushTag(key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void;
};

const Gl = struct {
    // https://registry.khronos.org/webgl/specs/latest/1.0/
    const COLOR_BUFFER_BIT = 0x00004000;
    const POINTS = 0x0000;
    const LINE_STRIP = 0x0003;
    const UNSIGNED_INT = 0x1405;
    const ARRAY_BUFFER = 0x8892;
    const ELEMENT_ARRAY_BUFFER = 0x8893;
    const STATIC_DRAW = 0x88E4;
    const FLOAT = 0x1406;
};

const vs_source = @embedFile("vertex.glsl");
const fs_source = @embedFile("fragment.glsl");

fn uploadMapPoints(data: []const f32) i32 {
    const vao = js.glCreateVertexArray();
    js.glBindVertexArray(vao);

    const vbo = js.glCreateBuffer();
    js.glBindBuffer(Gl.ARRAY_BUFFER, vbo);
    if (data.len > 0) {
        js.glBufferData(Gl.ARRAY_BUFFER, @ptrCast(data.ptr), data.len * 4, Gl.STATIC_DRAW);
    }
    js.glVertexAttribPointer(0, 2, Gl.FLOAT, false, 0, 0);
    js.glEnableVertexAttribArray(0);
    return vao;
}

fn setupMapIndices(indices: []const u32) i32 {
    const ebo = js.glCreateBuffer();
    js.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, ebo);
    js.glBufferData(
        Gl.ELEMENT_ARRAY_BUFFER,
        @ptrCast(indices.ptr),
        indices.len * 4,
        Gl.STATIC_DRAW,
    );
    return ebo;
}

const BoundRenderer = struct {
    inner: *Renderer,

    pub fn render(self: *const BoundRenderer, view_state: ViewState) void {
        js.glBindVertexArray(self.inner.vao);

        js.glClearColor(0.0, 0.0, 0.0, 1.0);
        js.glClear(Gl.COLOR_BUFFER_BIT);

        self.inner.lat_center.set(view_state.center.y);
        self.inner.lon_center.set(view_state.center.x);
        self.inner.aspect.set(view_state.aspect);
        self.inner.zoom.set(view_state.zoom);
        self.inner.color.set(1.0);
        js.glDrawElements(Gl.LINE_STRIP, @intCast(self.inner.num_line_segments), Gl.UNSIGNED_INT, 0);

        self.inner.point_size.set(10.0);
        self.renderCoords(&.{ view_state.center.x, view_state.center.y }, Gl.POINTS);
    }

    pub fn renderPoints(self: *const BoundRenderer, point_ids: []const NodeId, size: f32) void {
        js.glBindVertexArray(self.inner.vao);

        self.inner.point_size.set(size);

        for (point_ids) |point| {
            js.glDrawArrays(Gl.POINTS, @intCast(point.value), 1);
        }
    }

    pub fn renderSelectedWay(self: *const BoundRenderer, way: Way) void {
        const point_ids = way.indexRange(self.inner.index_buffer);
        js.glBindVertexArray(self.inner.vao);
        self.inner.color.set(0.0);
        js.glDrawElements(Gl.LINE_STRIP, @intCast(point_ids.end - point_ids.start), Gl.UNSIGNED_INT, @intCast(point_ids.start * 4));
    }

    pub fn renderCoords(self: *const BoundRenderer, coords: []const f32, mode: i32) void {
        js.glBindVertexArray(self.inner.custom_vao);
        js.glBufferData(Gl.ARRAY_BUFFER, @ptrCast(coords.ptr), @intCast(coords.len * 4), Gl.STATIC_DRAW);
        js.glDrawArrays(mode, 0, @intCast(coords.len / 2));
    }
};

const Renderer = struct {
    index_buffer: []const u32,
    program: i32,
    vao: i32,
    custom_vao: i32,
    ebo: i32,
    lat_center: FloatUniform,
    lon_center: FloatUniform,
    aspect: FloatUniform,
    zoom: FloatUniform,
    color: FloatUniform,
    point_size: FloatUniform,
    num_line_segments: usize,

    pub fn init(point_data: []const f32, index_data: []const u32) Renderer {
        // Now create an array of positions for the square.
        const program = js.compileLinkProgram(vs_source, vs_source.len, fs_source, fs_source.len);

        const vao = uploadMapPoints(point_data);
        const custom_vao = uploadMapPoints(&.{});

        const lat_center = FloatUniform.init(program, "lat_center");

        const lon_center = FloatUniform.init(program, "lon_center");

        const zoom = FloatUniform.init(program, "zoom");

        const aspect = FloatUniform.init(program, "aspect");
        const color = FloatUniform.init(program, "color");
        const point_size = FloatUniform.init(program, "point_size");

        const ebo = setupMapIndices(index_data);

        return .{
            .index_buffer = index_data,
            .program = program,
            .vao = vao,
            .custom_vao = custom_vao,
            .ebo = ebo,
            .lat_center = lat_center,
            .lon_center = lon_center,
            .aspect = aspect,
            .zoom = zoom,
            .point_size = point_size,
            .color = color,
            .num_line_segments = index_data.len,
        };
    }

    pub fn bind(self: *Renderer) BoundRenderer {
        js.glBindVertexArray(self.vao);
        js.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, self.ebo);
        js.glUseProgram(self.program);
        return .{
            .inner = self,
        };
    }
};

const IndexBufferIt = struct {
    data: []const u32,
    i: usize,

    fn init(data: []const u32) IndexBufferIt {
        return .{
            .data = data,
            .i = 0,
        };
    }

    fn next(self: *IndexBufferIt) ?IndexRange {
        self.i += 1;
        if (self.i >= self.data.len) {
            return null;
        }

        const start = self.i;
        const slice_rel_start: []const u32 = self.data[self.i..];
        const end_rel_start = std.mem.indexOfScalar(u32, slice_rel_start, 0xffffffff);
        const end = if (end_rel_start) |v| start + v else self.data.len;
        self.i = end;
        return .{
            .start = start,
            .end = end,
        };
    }
};

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
