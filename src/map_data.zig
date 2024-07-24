const std = @import("std");
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
};
