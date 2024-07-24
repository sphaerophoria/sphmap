const std = @import("std");
const builtin = @import("builtin");
const Metadata = @import("Metadata.zig");
const XmlParser = @import("XmlParser.zig");
const Allocator = std.mem.Allocator;

const NodeIdIdxMap = std.AutoHashMap(i64, usize);

const WayCache = struct {
    alloc: Allocator,
    found_highway: bool = false,
    tags: std.ArrayList(Metadata.Tag),
    nodes: std.ArrayList(i64),

    fn deinit(self: *WayCache) void {
        self.nodes.deinit();
        for (self.tags.items) |tag| {
            self.alloc.free(tag.key);
            self.alloc.free(tag.val);
        }
        self.tags.deinit();
    }

    fn pushNode(self: *WayCache, node_id: i64) void {
        self.nodes.append(node_id) catch unreachable;
    }

    fn pushTag(self: *WayCache, k: []const u8, v: []const u8) !void {
        if (std.mem.eql(u8, k, "highway")) {
            self.found_highway = true;
        }

        try self.tags.append(.{
            .key = try self.alloc.dupe(u8, k),
            .val = try self.alloc.dupe(u8, v),
        });
    }

    fn reset(self: *WayCache) void {
        self.found_highway = false;
        for (self.tags.items) |tag| {
            self.alloc.free(tag.key);
            self.alloc.free(tag.val);
        }
        self.tags.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
    }
};

const MapDataWriter = struct {
    writer: std.io.AnyWriter,
    node_id_idx_map: NodeIdIdxMap,
    min_lat: f32 = std.math.floatMax(f32),
    max_lat: f32 = -std.math.floatMax(f32),
    min_lon: f32 = std.math.floatMax(f32),
    max_lon: f32 = -std.math.floatMax(f32),

    fn deinit(self: *MapDataWriter) void {
        self.node_id_idx_map.deinit();
    }

    fn pushNode(self: *MapDataWriter, node_id: i64, lon: f32, lat: f32) void {
        self.max_lon = @max(lon, self.max_lon);
        self.min_lon = @min(lon, self.min_lon);
        self.max_lat = @max(lat, self.max_lat);
        self.min_lat = @min(lat, self.min_lat);

        self.node_id_idx_map.put(node_id, self.node_id_idx_map.count()) catch return;

        std.debug.assert(builtin.cpu.arch.endian() == .little);
        self.writer.writeAll(std.mem.asBytes(&lon)) catch unreachable;
        self.writer.writeAll(std.mem.asBytes(&lat)) catch unreachable;
    }

    fn pushWayNodes(self: *MapDataWriter, nodes: []const i64) void {
        self.writer.writeInt(u32, 0xffffffff, .little) catch unreachable;
        for (nodes) |node_id| {
            const node_idx = self.node_id_idx_map.get(node_id) orelse unreachable;
            self.writer.writeInt(u32, @intCast(node_idx), .little) catch unreachable;
        }
    }
};

const NodeData = struct {
    lon: f32,
    lat: f32,
};

const Userdata = struct {
    alloc: Allocator,
    way_tags: std.ArrayList([]Metadata.Tag),
    in_way: bool = false,
    node_storage: std.AutoHashMap(i64, NodeData),
    way_nodes: std.ArrayList([]i64),
    way_cache: WayCache,

    fn deinit(self: *Userdata) void {
        self.way_cache.deinit();
        self.way_tags.deinit();
        self.node_storage.deinit();
        for (self.way_nodes.items) |item| {
            self.alloc.free(item);
        }
        self.way_nodes.deinit();
    }

    fn handleNode(user_data: *Userdata, attrs: *XmlParser.XmlAttrIter) void {
        var lat_opt: ?[]const u8 = null;
        var lon_opt: ?[]const u8 = null;
        var node_id_opt: ?[]const u8 = null;
        while (attrs.next()) |attr| {
            if (std.mem.eql(u8, attr.key, "lat")) {
                lat_opt = attr.val;
            } else if (std.mem.eql(u8, attr.key, "lon")) {
                lon_opt = attr.val;
            } else if (std.mem.eql(u8, attr.key, "id")) {
                node_id_opt = attr.val;
            }
        }

        const lat_s = lat_opt orelse return;
        const lon_s = lon_opt orelse return;
        const node_id_s = node_id_opt orelse return;
        const lat = std.fmt.parseFloat(f32, lat_s) catch return;
        const lon = std.fmt.parseFloat(f32, lon_s) catch return;
        const node_id = std.fmt.parseInt(i64, node_id_s, 10) catch return;
        user_data.node_storage.put(node_id, .{
            .lon = lon,
            .lat = lat,
        }) catch return;
    }
};

fn findAttributeVal(key: []const u8, attrs: *XmlParser.XmlAttrIter) ?[]const u8 {
    while (attrs.next()) |attr| {
        if (std.mem.eql(u8, attr.key, key)) {
            return attr.val;
        }
    }

    return null;
}

fn startElement(ctx: ?*anyopaque, name: []const u8, attrs: *XmlParser.XmlAttrIter) void {
    const user_data: *Userdata = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, name, "node")) {
        user_data.handleNode(attrs);
        return;
    } else if (std.mem.eql(u8, name, "way")) {
        user_data.in_way = true;
        user_data.way_cache.reset();
    } else if (std.mem.eql(u8, name, "nd")) {
        if (user_data.in_way) {
            const node_id_s = findAttributeVal("ref", attrs) orelse return;
            const node_id = std.fmt.parseInt(i64, node_id_s, 10) catch unreachable;
            user_data.way_cache.pushNode(node_id);
        }
    } else if (std.mem.eql(u8, name, "tag")) {
        if (user_data.in_way) {
            var k_opt: ?[]const u8 = null;
            var v_opt: ?[]const u8 = null;
            while (attrs.next()) |attr| {
                if (std.mem.eql(u8, attr.key, "k")) {
                    k_opt = attr.val;
                } else if (std.mem.eql(u8, attr.key, "v")) {
                    v_opt = attr.val;
                }
            }

            const k = k_opt orelse return;
            const v = v_opt orelse return;

            user_data.way_cache.pushTag(k, v) catch unreachable;
        }
    }
}

fn endElement(ctx: ?*anyopaque, name: []const u8) void {
    const user_data: *Userdata = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, name, "way")) {
        user_data.in_way = false;
        if (user_data.way_cache.found_highway) {
            user_data.way_nodes.append(user_data.way_cache.nodes.toOwnedSlice() catch unreachable) catch unreachable;
            user_data.way_tags.append(user_data.way_cache.tags.toOwnedSlice() catch unreachable) catch unreachable;
            user_data.way_cache.reset();
        }
    }
}

fn runParser(xml_path: []const u8, callbacks: XmlParser.Callbacks) !void {
    const f = try std.fs.cwd().openFile(xml_path, .{});
    defer f.close();

    var buffered_reader = std.io.bufferedReader(f.reader());

    var parser = try XmlParser.init(&callbacks);
    defer parser.deinit();

    while (true) {
        var buf: [4096]u8 = undefined;
        const read_data_len = try buffered_reader.read(&buf);
        if (read_data_len == 0) {
            try parser.finish();
            break;
        }

        try parser.feed(buf[0..read_data_len]);
    }
}

const Args = struct {
    osm_data: []const u8,
    input_www: []const u8,
    index_wasm: []const u8,
    output: []const u8,
    it: std.process.ArgIterator,

    const Option = enum {
        @"--osm-data",
        @"--input-www",
        @"--index-wasm",
        @"--output",
    };
    fn deinit(self: *Args) void {
        self.it.deinit();
    }

    fn parse(alloc: Allocator) !Args {
        var it = try std.process.ArgIterator.initWithAllocator(alloc);
        _ = it.next();

        var osm_data_opt: ?[]const u8 = null;
        var input_www_opt: ?[]const u8 = null;
        var index_wasm_opt: ?[]const u8 = null;
        var output_opt: ?[]const u8 = null;

        while (it.next()) |arg| {
            const opt = std.meta.stringToEnum(Option, arg) orelse {
                std.debug.print("{s}", .{arg});
                return error.InvalidOption;
            };

            switch (opt) {
                .@"--osm-data" => osm_data_opt = it.next(),
                .@"--input-www" => input_www_opt = it.next(),
                .@"--index-wasm" => index_wasm_opt = it.next(),
                .@"--output" => output_opt = it.next(),
            }
        }

        return .{
            .osm_data = osm_data_opt orelse return error.NoOsmData,
            .input_www = input_www_opt orelse return error.NoWww,
            .index_wasm = index_wasm_opt orelse return error.NoWasm,
            .output = output_opt orelse return error.NoOutput,
            .it = it,
        };
    }
};

fn linkFile(alloc: Allocator, in: []const u8, out_dir: []const u8) !void {
    const name = std.fs.path.basename(in);
    const link_path = try std.fs.path.relative(alloc, out_dir, in);
    defer alloc.free(link_path);

    const out = try std.fs.cwd().openDir(out_dir, .{});
    out.deleteFile(name) catch {};
    try out.symLink(link_path, name, std.fs.Dir.SymLinkFlags{});
}

fn linkWww(alloc: Allocator, in: []const u8, out_dir: []const u8) !void {
    const in_dir = try std.fs.cwd().openDir(in, .{
        .iterate = true,
    });

    var it = in_dir.iterate();
    while (try it.next()) |entry| {
        const p = try std.fs.path.join(alloc, &.{ in, entry.name });
        defer alloc.free(p);

        try linkFile(alloc, p, out_dir);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit();

    try std.fs.cwd().makePath(args.output);

    try linkFile(alloc, args.index_wasm, args.output);
    try linkWww(alloc, args.input_www, args.output);

    const map_data_path = try std.fs.path.join(alloc, &.{ args.output, "map_data.bin" });
    defer alloc.free(map_data_path);

    const metadata_path = try std.fs.path.join(alloc, &.{ args.output, "map_data.json" });
    defer alloc.free(metadata_path);

    const out_f = try std.fs.cwd().createFile(map_data_path, .{});
    var points_out_buf_writer = std.io.bufferedWriter(out_f.writer());
    defer points_out_buf_writer.flush() catch unreachable;
    const points_out_writer = points_out_buf_writer.writer().any();

    var userdata = Userdata{
        .alloc = alloc,
        .way_cache = .{
            .alloc = alloc,
            .tags = std.ArrayList(Metadata.Tag).init(alloc),
            .nodes = std.ArrayList(i64).init(alloc),
        },
        .way_tags = std.ArrayList([]Metadata.Tag).init(alloc),
        .node_storage = std.AutoHashMap(i64, NodeData).init(alloc),
        .way_nodes = std.ArrayList([]i64).init(alloc),
    };
    defer userdata.deinit();

    try runParser(args.osm_data, .{
        .ctx = &userdata,
        .startElement = startElement,
        .endElement = endElement,
    });

    var data_writer = MapDataWriter{
        .node_id_idx_map = NodeIdIdxMap.init(alloc),
        .writer = points_out_writer,
    };
    defer data_writer.deinit();

    var seen_node_ids = std.AutoHashMap(i64, void).init(alloc);
    defer seen_node_ids.deinit();

    for (userdata.way_nodes.items) |way_nodes| {
        for (way_nodes) |node_id| {
            const seen = try seen_node_ids.getOrPut(node_id);
            if (!seen.found_existing) {
                const node: NodeData = userdata.node_storage.get(node_id) orelse return error.NoNode;
                data_writer.pushNode(node_id, node.lon, node.lat);
            }
        }
    }

    for (userdata.way_nodes.items) |way_nodes| {
        data_writer.pushWayNodes(way_nodes);
    }

    const metadata_out_f = try std.fs.cwd().createFile(metadata_path, .{});
    const metadata = Metadata{
        .min_lat = data_writer.min_lat,
        .max_lat = data_writer.max_lat,
        .min_lon = data_writer.min_lon,
        .max_lon = data_writer.max_lon,
        .end_nodes = data_writer.node_id_idx_map.count() * 8,
        .way_tags = try userdata.way_tags.toOwnedSlice(),
    };
    try std.json.stringify(metadata, .{}, metadata_out_f.writer());

    for (metadata.way_tags) |way_tags| {
        for (way_tags) |tag| {
            alloc.free(tag.key);
            alloc.free(tag.val);
        }
        alloc.free(way_tags);
    }
    alloc.free(metadata.way_tags);
}
