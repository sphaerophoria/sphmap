const std = @import("std");
const App = @import("App.zig");
const Metadata = @import("Metadata.zig");
const map_data = @import("map_data.zig");
const PathPlanner = @import("PathPlanner.zig");
const monitored_attributes = @import("monitored_attributes.zig");
const Allocator = std.mem.Allocator;
const Way = map_data.Way;
const WayLookup = map_data.WayLookup;

const Args = struct {
    const AttributeCost = struct {
        k: []const u8,
        v: []const u8,
        cost: f32,

        fn parse(it: *std.process.ArgIterator) !AttributeCost {
            const k = it.next() orelse return error.NoKey;
            const v = it.next() orelse return error.NoValue;
            const cost_s = it.next() orelse return error.NoCost;
            const cost = try std.fmt.parseFloat(f32, cost_s);
            return .{
                .k = k,
                .v = v,
                .cost = cost,
            };
        }
    };

    start: map_data.NodeId,
    end: map_data.NodeId,
    map_data_bin: []const u8,
    map_data_json: []const u8,
    num_iters: usize,
    turning_cost: f32,
    attribute_costs: []const AttributeCost,
    it: std.process.ArgIterator,

    const Option = enum {
        @"--map-data-bin",
        @"--map-data-json",
        @"--start-id",
        @"--end-id",
        @"--num-iters",
        @"--turning-cost",
        @"--attribute-cost",
        @"--help",
    };

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        errdefer it.deinit();

        const process_name = it.next() orelse "pp_benchmark";

        var start: ?map_data.NodeId = null;
        var end: ?map_data.NodeId = null;
        var map_data_bin: ?[]const u8 = null;
        var map_data_json: ?[]const u8 = null;
        var turning_cost: ?f32 = null;
        var attribute_costs = std.ArrayList(AttributeCost).init(alloc);
        defer attribute_costs.deinit();
        var num_iters: usize = 5;

        while (it.next()) |s| {
            const opt = std.meta.stringToEnum(Option, s) orelse {
                std.debug.print("Invalid argument {s}\n", .{s});
                help(process_name);
            };

            switch (opt) {
                .@"--map-data-bin" => {
                    map_data_bin = getArg(&it, opt, process_name);
                },
                .@"--map-data-json" => {
                    map_data_json = getArg(&it, opt, process_name);
                },
                .@"--start-id" => {
                    const start_s = getArg(&it, opt, process_name);
                    const start_v = std.fmt.parseInt(u32, start_s, 10) catch {
                        std.debug.print("{s} is not a valid u32\n", .{start_s});
                        help(process_name);
                    };
                    start = .{
                        .value = start_v,
                    };
                },
                .@"--end-id" => {
                    const end_s = getArg(&it, opt, process_name);
                    const end_v = std.fmt.parseInt(u32, end_s, 10) catch {
                        std.debug.print("{s} is not a valid u32\n", .{end_s});
                        help(process_name);
                    };
                    end = .{
                        .value = end_v,
                    };
                },
                .@"--num-iters" => {
                    const num_iters_s = getArg(&it, opt, process_name);
                    num_iters = std.fmt.parseInt(usize, num_iters_s, 10) catch {
                        std.debug.print("{s} is not a valid usize\n", .{num_iters_s});
                        help(process_name);
                    };
                },
                .@"--turning-cost" => {
                    const turning_cost_s = getArg(&it, opt, process_name);
                    turning_cost = std.fmt.parseFloat(f32, turning_cost_s) catch {
                        std.debug.print("{s} is not a valid f32\n", .{turning_cost_s});
                        help(process_name);
                    };
                },
                .@"--attribute-cost" => {
                    const attribute_cost = AttributeCost.parse(&it) catch |e| {
                        std.debug.print("Failed to parse attribute cost args {s}\n", .{@errorName(e)});
                        help(process_name);
                    };
                    try attribute_costs.append(attribute_cost);
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        return .{
            .start = unwrapArg(start, Option.@"--start-id", process_name),
            .end = unwrapArg(end, Option.@"--end-id", process_name),
            .map_data_bin = unwrapArg(map_data_bin, Option.@"--map-data-bin", process_name),
            .map_data_json = unwrapArg(map_data_json, Option.@"--map-data-json", process_name),
            .num_iters = num_iters,
            .turning_cost = unwrapArg(turning_cost, Option.@"--turning-cost", process_name),
            .attribute_costs = try attribute_costs.toOwnedSlice(),
            .it = it,
        };
    }

    pub fn deinit(self: *Args, alloc: Allocator) void {
        alloc.free(self.attribute_costs);
        self.it.deinit();
    }

    fn getArg(it: *std.process.ArgIterator, opt: Option, process_name: []const u8) []const u8 {
        return it.next() orelse {
            std.debug.print("{s} provided with no argument\n", .{@tagName(opt)});
            help(process_name);
        };
    }

    fn unwrapArg(arg: anytype, opt: Option, process_name: []const u8) @typeInfo(@TypeOf(arg)).Optional.child {
        return arg orelse {
            std.debug.print("{s} not provided\n", .{@tagName(opt)});
            help(process_name);
        };
    }

    fn help(process_name: []const u8) noreturn {
        std.debug.print("Usage: {s} [ARGS]\n\nARGS\n", .{process_name});

        inline for (std.meta.fields(Option)) |info| {
            const opt: Option = @enumFromInt(info.value);
            std.debug.print("{s} ", .{info.name});
            switch (opt) {
                .@"--map-data-bin" => {
                    std.debug.print("[bin path]", .{});
                },
                .@"--map-data-json" => {
                    std.debug.print("[metadata path]", .{});
                },
                .@"--start-id" => {
                    std.debug.print("[path planner start node id]", .{});
                },
                .@"--end-id" => {
                    std.debug.print("[path planner start node id]", .{});
                },
                .@"--num-iters" => {
                    std.debug.print("[number of times to run planner] OPTIONAL", .{});
                },
                .@"--turning-cost" => {
                    std.debug.print("[turning cost]", .{});
                },
                .@"--attribute-cost" => {
                    std.debug.print("[attr_key] [attr_value] [cost]", .{});
                },
                .@"--help" => {
                    std.debug.print("Show this help", .{});
                },
            }
            std.debug.print("\n", .{});
        }
        std.process.exit(1);
    }
};
fn readFileData(alloc: Allocator, p: []const u8) ![]u8 {
    const cwd = std.fs.cwd();
    var f = try cwd.openFile(p, .{});
    defer f.close();
    return try f.readToEndAlloc(alloc, 1 << 30);
}

fn parseIndexBuffer(alloc: Allocator, point_lookup: *const map_data.PointLookup, index_buffer: []const u32) !struct { WayLookup, map_data.NodeAdjacencyMap } {
    var ways = WayLookup.Builder.init(alloc, index_buffer);
    defer ways.deinit();

    var node_neighbors = try map_data.NodeAdjacencyMap.Builder.init(alloc, point_lookup.numPoints());
    defer node_neighbors.deinit();

    var it = map_data.IndexBufferIt.init(index_buffer);

    while (it.next()) |idx_buf_range| {
        const way = map_data.Way.fromIndexRange(idx_buf_range, index_buffer);
        try ways.feed(way);
        try node_neighbors.feed(way);
    }

    const way_lookup = try ways.build();
    const adjacency_map = try node_neighbors.build();

    return .{ way_lookup, adjacency_map };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit(alloc);

    const map_data_buf = try readFileData(alloc, args.map_data_bin);
    defer alloc.free(map_data_buf);

    const map_metadata = try readFileData(alloc, args.map_data_json);
    defer alloc.free(map_metadata);

    const parsed = try std.json.parseFromSlice(Metadata, alloc, map_metadata, .{});
    defer parsed.deinit();

    const split_data = map_data.MapDataComponents.init(map_data_buf, parsed.value);

    _ = map_data.latLongToMeters(split_data.point_data, parsed.value);

    const point_lookup = map_data.PointLookup{ .points = split_data.point_data };
    const elems = try parseIndexBuffer(alloc, &point_lookup, split_data.index_data);
    var way_lookup = elems[0];
    defer way_lookup.deinit(alloc);

    var adjacency_map = elems[1];
    defer adjacency_map.deinit(alloc);

    var cost_tracker = monitored_attributes.CostTracker.init(alloc, &parsed.value, &way_lookup);
    defer cost_tracker.deinit();

    var string_table = try map_data.StringTable.init(alloc, split_data.string_table_data);
    defer string_table.deinit(alloc);

    for (args.attribute_costs) |cost| {
        const k_id = string_table.findByStringContent(cost.k);
        const v_id = string_table.findByStringContent(cost.v);
        const id = try cost_tracker.push(k_id, v_id);
        try cost_tracker.update(id, cost.cost);
    }

    var node_costs = map_data.NodePairCostMultiplierMap.init(alloc);
    defer node_costs.deinit();

    const start = try std.time.Instant.now();
    for (0..args.num_iters) |_| {
        var pp = try PathPlanner.init(alloc, &point_lookup, &adjacency_map, &node_costs, args.start, args.end, args.turning_cost, 1.0);
        defer pp.deinit();

        const path = try pp.run();
        alloc.free(path);
    }
    const end = try std.time.Instant.now();

    std.debug.print("average pp time: {d}\n", .{end.since(start) / 1000 / 1000 / args.num_iters});
}
