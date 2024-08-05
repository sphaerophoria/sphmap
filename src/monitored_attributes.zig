const std = @import("std");
const map_data = @import("map_data.zig");
const Metadata = @import("Metadata.zig");
const gui = @import("gui_bindings.zig");
const Gl = @import("gl_utils.zig").Gl;
const Allocator = std.mem.Allocator;

pub const CostAttributes = struct {
    k: map_data.StringTableId,
    v: map_data.StringTableId,
    multiplier: f32,
};

pub const CostTracker = struct {
    alloc: Allocator,
    attributes: std.ArrayListUnmanaged(CostAttributes) = .{},
    node_costs: map_data.NodePairCostMultiplierMap,
    metadata: *const Metadata,
    ways: *const map_data.WayLookup,
    point_pair_to_parents: *const map_data.NodePairMap(map_data.WayId),
    adjacency_map: *const map_data.NodeAdjacencyMap,
    min_cost_multiplier: f32 = 1.0,

    pub fn init(
        alloc: Allocator,
        metadata: *const Metadata,
        ways: *const map_data.WayLookup,
        point_pair_to_parents: *const map_data.NodePairMap(map_data.WayId),
        adjacency_map: *const map_data.NodeAdjacencyMap,
    ) CostTracker {
        return .{
            .alloc = alloc,
            .node_costs = map_data.NodePairCostMultiplierMap.init(alloc),
            .metadata = metadata,
            .ways = ways,
            .point_pair_to_parents = point_pair_to_parents,
            .adjacency_map = adjacency_map,
        };
    }

    pub fn deinit(self: *CostTracker) void {
        self.attributes.deinit(self.alloc);
        self.node_costs.deinit();
    }

    pub fn push(self: *CostTracker, k: map_data.StringTableId, v: map_data.StringTableId) !usize {
        try self.attributes.append(self.alloc, .{ .k = k, .v = v, .multiplier = 1.0 });
        const id = self.attributes.items.len - 1;
        return id;
    }

    pub fn update(self: *CostTracker, id: usize, multiplier: f32) !void {
        const monitored_attribute = &self.attributes.items[id];
        monitored_attribute.multiplier = multiplier;
        try self.recalculateNodeCosts();
        //var it = map_data.WaysForTagPair.init(self.metadata, self.ways, monitored_attribute.k, monitored_attribute.v);
        //while (it.next()) |way| {
        //    for (0..way.node_ids.len - 1) |i| {
        //        const a = way.node_ids[i];
        //        const b = way.node_ids[i + 1];
        //        try self.node_costs.put(a, b, multiplier);
        //    }
        //}

        //var min: f32 = 1.0;
        //for (self.attributes.items) |attr| {
        //    min = @min(min, attr.multiplier);
        //}
        //self.min_cost_multiplier = min;
    }

    pub fn remove(self: *CostTracker, id: usize) !void {
        _ = self.attributes.orderedRemove(id);
        try self.recalculateNodeCosts();
    }

    fn recalculateNodeCosts(self: *CostTracker) !void {
        self.min_cost_multiplier = 1.0;
        self.node_costs.inner.clearRetainingCapacity();

        for (self.attributes.items) |monitored_attribute| {
            var it = map_data.WaysForTagPair.init(self.metadata, self.ways, monitored_attribute.k, monitored_attribute.v);
            while (it.next()) |way| {
                for (0..way.node_ids.len - 1) |i| {
                    const a = way.node_ids[i];
                    const b = way.node_ids[i + 1];
                    const cost = self.node_costs.get(a, b) orelse 1.0;
                    try self.node_costs.put(a, b, cost * monitored_attribute.multiplier);
                }
            }

            var parent_it = map_data.NodePairsForParentTagPair.init(monitored_attribute.k, monitored_attribute.v, self.metadata, self.point_pair_to_parents, self.adjacency_map);
            while (parent_it.next()) |node_pair| {
                const cost = self.node_costs.get(node_pair.a, node_pair.b) orelse 1.0;
                try self.node_costs.put(node_pair.a, node_pair.b, cost * monitored_attribute.multiplier);
            }
            self.min_cost_multiplier = @min(self.min_cost_multiplier, monitored_attribute.multiplier);
        }
    }
};

const RenderingAttributes = struct {
    index_buffer: i32,
    index_buffer_len: usize,
    color: struct {
        r: f32,
        g: f32,
        b: f32,
    },
};

const RenderingTracker = struct {
    attributes: std.ArrayList(RenderingAttributes),
    metadata: *const Metadata,
    ways: *const map_data.WayLookup,

    pub fn init(
        alloc: Allocator,
        metadata: *const Metadata,
        ways: *const map_data.WayLookup,
    ) RenderingTracker {
        return .{
            .attributes = std.ArrayList(RenderingAttributes).init(alloc),
            .metadata = metadata,
            .ways = ways,
        };
    }

    pub fn deinit(self: *RenderingTracker) void {
        self.attributes.deinit();
    }

    pub fn push(self: *RenderingTracker, k: map_data.StringTableId, v: map_data.StringTableId) !void {
        var point_ids = std.ArrayList(u32).init(self.attributes.allocator);
        defer point_ids.deinit();

        var it = map_data.WaysForTagPair.init(self.metadata, self.ways, k, v);
        while (it.next()) |way| {
            try point_ids.appendSlice(@ptrCast(way.node_ids));
            try point_ids.append(0xffffffff);
        }

        const ebo = gui.glCreateBuffer();
        gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, ebo);
        gui.glBufferData(
            Gl.ELEMENT_ARRAY_BUFFER,
            @ptrCast(point_ids.items.ptr),
            point_ids.items.len * 4,
            Gl.STATIC_DRAW,
        );

        try self.attributes.append(.{
            .index_buffer = ebo,
            .index_buffer_len = point_ids.items.len,
            .color = undefined,
        });
    }

    pub fn update(self: *RenderingTracker, id: usize, r: f32, g: f32, b: f32) void {
        self.attributes.items[id].color.r = r;
        self.attributes.items[id].color.g = g;
        self.attributes.items[id].color.b = b;
    }

    pub fn remove(self: *RenderingTracker, id: usize) !void {
        const removed = self.attributes.orderedRemove(id);
        gui.glDeleteBuffer(removed.index_buffer);
    }
};

pub const MonitoredAttributeTracker = struct {
    cost: CostTracker,
    rendering: RenderingTracker,

    pub fn init(
        alloc: Allocator,
        metadata: *const Metadata,
        ways: *const map_data.WayLookup,
        point_pair_to_parents: *const map_data.NodePairMap(map_data.WayId),
        adjacency_map: *const map_data.NodeAdjacencyMap,
    ) MonitoredAttributeTracker {
        const cost = CostTracker.init(alloc, metadata, ways, point_pair_to_parents, adjacency_map);
        const rendering = RenderingTracker.init(alloc, metadata, ways);

        return .{
            .cost = cost,
            .rendering = rendering,
        };
    }

    pub fn deinit(self: *MonitoredAttributeTracker) void {
        self.cost.deinit();
        self.rendering.deinit();
    }

    pub fn push(self: *MonitoredAttributeTracker, k: map_data.StringTableId, v: map_data.StringTableId) !usize {
        const id = try self.cost.push(k, v);
        errdefer {
            _ = self.cost.attributes.pop();
        }
        try self.rendering.push(k, v);

        std.debug.assert(self.cost.attributes.items.len == self.rendering.attributes.items.len);
        return id;
    }

    pub fn remove(self: *MonitoredAttributeTracker, id: usize) !void {
        try self.cost.remove(id);
        try self.rendering.remove(id);
    }
};
