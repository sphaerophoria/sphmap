const std = @import("std");
const Metadata = @import("Metadata.zig");
const Allocator = std.mem.Allocator;
const lin = @import("lin.zig");
const MapPos = lin.Point;
const builtin = @import("builtin");

pub const NodeId = struct {
    value: u32,
};

pub const WayId = struct {
    value: usize,
};

pub const IndexRange = struct {
    start: usize,
    end: usize,
};

pub const Way = struct {
    node_ids: []const NodeId,

    pub fn fromIndexRange(range: IndexRange, index_buf: []const u32) Way {
        return .{
            .node_ids = @ptrCast(index_buf[range.start..range.end]),
        };
    }

    pub fn indexRange(self: *const Way, index_buffer: []const u32) IndexRange {
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

pub const PointLookup = struct {
    points: []const f32,

    pub fn numPoints(self: *const PointLookup) usize {
        return self.points.len / 2;
    }

    pub fn get(self: *const PointLookup, id: NodeId) MapPos {
        return .{
            .x = self.points[id.value * 2],
            .y = self.points[id.value * 2 + 1],
        };
    }
};

pub const WayLookup = struct {
    ways: []const Way,

    pub const Builder = struct {
        ways: std.ArrayList(Way),
        index_buffer: []const u32,

        pub fn init(alloc: Allocator, index_buffer: []const u32) Builder {
            return .{
                .ways = std.ArrayList(Way).init(alloc),
                .index_buffer = index_buffer,
            };
        }

        pub fn deinit(self: *Builder) void {
            self.ways.deinit();
        }

        pub fn feed(self: *Builder, way: Way) !void {
            try self.ways.append(way);
        }

        pub fn build(self: *Builder) !WayLookup {
            const ways = try self.ways.toOwnedSlice();
            return .{
                .ways = ways,
            };
        }
    };

    pub fn deinit(self: *WayLookup, alloc: Allocator) void {
        alloc.free(self.ways);
    }

    pub fn get(self: *const WayLookup, id: WayId) Way {
        return self.ways[id.value];
    }
};

pub const NodeAdjacencyMap = struct {
    // Where in storage this node's neighbors are. Indexed by NodeId
    segment_starts: []u32,
    // All neighbors for all nodes, Each node's neighbors are contiguous
    storage: []const NodeId,

    pub const Builder = struct {
        arena: *std.heap.ArenaAllocator,
        node_neighbors: []std.AutoArrayHashMapUnmanaged(NodeId, void),

        pub fn init(alloc: Allocator, num_points: usize) !Builder {
            var arena = try alloc.create(std.heap.ArenaAllocator);
            errdefer alloc.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(alloc);

            const arena_alloc = arena.allocator();
            const node_neighbors = try arena_alloc.alloc(std.AutoArrayHashMapUnmanaged(NodeId, void), num_points);
            @memset(node_neighbors, std.AutoArrayHashMapUnmanaged(NodeId, void){});
            return .{
                .arena = arena,
                .node_neighbors = node_neighbors,
            };
        }

        pub fn deinit(self: *Builder) void {
            const alloc = self.arena.child_allocator;
            self.arena.deinit();
            alloc.destroy(self.arena);
        }

        pub fn feed(self: *Builder, way: Way) !void {
            const arena_alloc = self.arena.allocator();
            for (way.node_ids, 0..) |node_id, i| {
                if (i > 0) {
                    try self.node_neighbors[node_id.value].put(arena_alloc, way.node_ids[i - 1], {});
                }

                if (i < way.node_ids.len - 1) {
                    try self.node_neighbors[node_id.value].put(arena_alloc, way.node_ids[i + 1], {});
                }
            }
        }

        pub fn build(self: *Builder) !NodeAdjacencyMap {
            return try NodeAdjacencyMap.init(self.arena.child_allocator, self.node_neighbors);
        }
    };

    pub fn init(alloc: Allocator, node_neighbors: []std.AutoArrayHashMapUnmanaged(NodeId, void)) !NodeAdjacencyMap {
        var storage = std.ArrayList(NodeId).init(alloc);
        defer storage.deinit();

        var segment_starts = std.ArrayList(u32).init(alloc);
        defer segment_starts.deinit();

        for (node_neighbors) |neighbors| {
            try segment_starts.append(@intCast(storage.items.len));
            try storage.appendSlice(neighbors.keys());
        }
        try segment_starts.append(@intCast(storage.items.len));

        return .{
            .storage = try storage.toOwnedSlice(),
            .segment_starts = try segment_starts.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *NodeAdjacencyMap, alloc: Allocator) void {
        alloc.free(self.storage);
        alloc.free(self.segment_starts);
    }

    pub fn getNeighbors(self: *const NodeAdjacencyMap, node: NodeId) []const NodeId {
        const start = self.segment_starts[node.value];
        const end = self.segment_starts[node.value + 1];

        return self.storage[start..end];
    }
};

const NodePair = struct {
    a: NodeId,
    b: NodeId,
};
pub const NodePairCostMultiplierMap = struct {
    costs: std.AutoHashMap(NodePair, f32),

    pub fn init(alloc: Allocator) NodePairCostMultiplierMap {
        return .{
            .costs = std.AutoHashMap(NodePair, f32).init(alloc),
        };
    }

    pub fn deinit(self: *NodePairCostMultiplierMap) void {
        self.costs.deinit();
    }

    pub fn putCost(self: *NodePairCostMultiplierMap, a: NodeId, b: NodeId, cost: f32) !void {
        try self.costs.put(makeNodePair(a, b), cost);
    }

    pub fn getCost(self: *const NodePairCostMultiplierMap, a: NodeId, b: NodeId) f32 {
        return self.costs.get(makeNodePair(a, b)) orelse 1.0;
    }

    fn makeNodePair(a: NodeId, b: NodeId) NodePair {
        const larger = @max(a.value, b.value);
        const smaller = @min(a.value, b.value);
        return .{
            .a = .{ .value = smaller },
            .b = .{ .value = larger },
        };
    }
};

pub const IndexBufferIt = struct {
    data: []const u32,
    i: usize,

    pub fn init(data: []const u32) IndexBufferIt {
        return .{
            .data = data,
            .i = 0,
        };
    }

    pub fn next(self: *IndexBufferIt) ?IndexRange {
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

pub const StringTableId = usize;

pub const StringTable = struct {
    data: []const []const u8,

    pub fn init(alloc: Allocator, buf: []const u8) !StringTable {
        var data = std.ArrayList([]const u8).init(alloc);
        defer data.deinit();

        var it: usize = 0;
        while (it < buf.len) {
            comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
            const len_end = it + 2;
            if (len_end >= buf.len) {
                return error.InvalidData;
            }

            const str_len = std.mem.bytesToValue(u16, buf[it..len_end]);
            const str_end = str_len + len_end;
            defer it = str_end;

            if (str_end > buf.len) {
                return error.InvalidData;
            }

            const s = buf[len_end..str_end];
            try data.append(s);
        }

        return .{ .data = try data.toOwnedSlice() };
    }

    pub fn deinit(self: *StringTable, alloc: Allocator) void {
        alloc.free(self.data);
    }

    pub fn get(self: *const StringTable, id: StringTableId) []const u8 {
        return self.data[id];
    }

    pub fn findByPointerAddress(self: *const StringTable, p: [*]const u8) StringTableId {
        for (self.data, 0..) |item, i| {
            if (item.ptr == p) {
                return i;
            }
        }

        @panic("No id");
    }

    pub fn findByStringContent(self: *const StringTable, s: []const u8) StringTableId {
        for (self.data, 0..) |item, i| {
            if (std.mem.eql(u8, item, s)) {
                return i;
            }
        }

        @panic("No id");
    }
};

pub const MeterMetadata = struct {
    width: f32,
    height: f32,
};

pub fn latLongToMeters(point_data: []f32, metadata: Metadata) MeterMetadata {
    const converter = CoordinateSpaceConverter.init(&metadata);

    for (0..point_data.len / 2) |i| {
        const lon = &point_data[i * 2];
        const lat = &point_data[i * 2 + 1];

        lat.* = converter.latToM(lat.*);
        lon.* = converter.lonToM(lon.*);
    }

    return .{
        .width = converter.widthM(),
        .height = converter.heightM(),
    };
}

pub const CoordinateSpaceConverter = struct {
    metadata: *const Metadata,
    width_deg: f32,
    height_deg: f32,
    lat_step: f32,
    lon_step: f32,

    pub fn init(metadata: *const Metadata) CoordinateSpaceConverter {
        const center_lat = (metadata.min_lat + metadata.max_lat) / 2.0 * std.math.rad_per_deg;

        const lat_step = 111132.92 - 559.82 * @cos(2 * center_lat) + 1.175 * @cos(4 * center_lat) - 0.0023 * @cos(6 * center_lat);
        const lon_step = 111412.84 * @cos(center_lat) - 93.5 * @cos(3 * center_lat) + 0.118 * @cos(5 * center_lat);

        const width_deg = metadata.max_lon - metadata.min_lon;
        const height_deg = metadata.max_lat - metadata.min_lat;
        std.log.debug("max lon: {d}, min lon: {d}, max lat: {d}, min lat: {d}", .{
            metadata.max_lon,
            metadata.min_lon,
            metadata.max_lat,
            metadata.min_lat,
        });

        return .{
            .metadata = metadata,
            .lat_step = lat_step,
            .lon_step = lon_step,
            .width_deg = width_deg,
            .height_deg = height_deg,
        };
    }

    pub fn latToM(self: *const CoordinateSpaceConverter, lat: f32) f32 {
        return self.lat_step * (lat - self.metadata.min_lat);
    }

    pub fn lonToM(self: *const CoordinateSpaceConverter, lon: f32) f32 {
        return self.lon_step * (lon - self.metadata.min_lon);
    }

    pub fn widthM(self: *const CoordinateSpaceConverter) f32 {
        return self.lon_step * self.width_deg;
    }

    pub fn heightM(self: *const CoordinateSpaceConverter) f32 {
        return self.lat_step * self.height_deg;
    }
};

pub const MapDataComponents = struct {
    point_data: []f32,
    index_data: []const u32,
    string_table_data: []const u8,

    pub fn init(data: []u8, metadata: Metadata) MapDataComponents {
        return .{
            .point_data = @alignCast(std.mem.bytesAsSlice(f32, data[0..@intCast(metadata.end_nodes)])),
            .index_data = @alignCast(std.mem.bytesAsSlice(u32, data[@intCast(metadata.end_nodes)..@intCast(metadata.end_ways)])),
            .string_table_data = data[@intCast(metadata.end_ways)..],
        };
    }
};

pub const WaysForTagPair = struct {
    metadata: *const Metadata,
    ways: *const WayLookup,
    k: usize,
    v: usize,
    i: usize = 0,

    pub fn init(metadata: *const Metadata, ways: *const WayLookup, k: usize, v: usize) WaysForTagPair {
        return .{
            .metadata = metadata,
            .ways = ways,
            .k = k,
            .v = v,
        };
    }

    pub fn next(self: *WaysForTagPair) ?Way {
        while (true) {
            if (self.i >= self.metadata.way_tags.len) {
                return null;
            }
            defer self.i += 1;

            const way_tags = self.metadata.way_tags[self.i];
            for (0..way_tags[0].len) |tag_id| {
                const way_k = way_tags[0][tag_id];
                const way_v = way_tags[1][tag_id];
                if (way_k == self.k and way_v == self.v) {
                    return self.ways.ways[self.i];
                }
            }
        }
    }
};
