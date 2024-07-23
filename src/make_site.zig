const std = @import("std");
const builtin = @import("builtin");
const Metadata = @import("Metadata.zig");
const XmlParser = @import("XmlParser.zig");
const Allocator = std.mem.Allocator;

const Userdata = struct {
    alloc: Allocator,
    points_out: std.io.AnyWriter,
    metadata: Metadata = .{},
    node_id_idx_map: std.AutoHashMap(i64, usize),
    way_tags: std.ArrayList([]Metadata.Tag),
    in_way: bool = false,
    found_highway: bool = false,
    this_way_tags: std.ArrayList(Metadata.Tag),
    this_way_nodes: std.ArrayList(u32),
    num_nodes: u64 = 0,

    fn deinit(self: *Userdata) void {
        self.node_id_idx_map.deinit();
        self.way_tags.deinit();
        self.this_way_nodes.deinit();
        for (self.this_way_tags.items) |tag| {
            self.alloc.free(tag.key);
            self.alloc.free(tag.val);
        }
        self.this_way_tags.deinit();
    }

    fn handleNode(user_data: *Userdata, attrs: *XmlParser.XmlAttrIter) void {
        defer user_data.num_nodes += 1;

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
        user_data.node_id_idx_map.put(node_id, user_data.num_nodes) catch return;

        user_data.metadata.max_lon = @max(lon, user_data.metadata.max_lon);
        user_data.metadata.min_lon = @min(lon, user_data.metadata.min_lon);
        user_data.metadata.max_lat = @max(lat, user_data.metadata.max_lat);
        user_data.metadata.min_lat = @min(lat, user_data.metadata.min_lat);

        std.debug.assert(builtin.cpu.arch.endian() == .little);
        user_data.points_out.writeAll(std.mem.asBytes(&lon)) catch unreachable;
        user_data.points_out.writeAll(std.mem.asBytes(&lat)) catch unreachable;
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
        user_data.found_highway = false;
        user_data.this_way_nodes.clearRetainingCapacity();
        for (user_data.this_way_tags.items) |tag| {
            user_data.alloc.free(tag.key);
            user_data.alloc.free(tag.val);
        }
        user_data.this_way_tags.clearRetainingCapacity();
    } else if (std.mem.eql(u8, name, "nd")) {
        const node_id_s = findAttributeVal("ref", attrs) orelse return;
        const node_id = std.fmt.parseInt(i64, node_id_s, 10) catch unreachable;
        const node_idx = user_data.node_id_idx_map.get(node_id) orelse return;
        user_data.this_way_nodes.append(@intCast(node_idx)) catch unreachable;
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

            if (std.mem.eql(u8, k, "highway")) {
                user_data.found_highway = true;
            }

            user_data.this_way_tags.append(.{
                .key = user_data.alloc.dupe(u8, k) catch return,
                .val = user_data.alloc.dupe(u8, v) catch return,
            }) catch unreachable;
        }
    }
}

fn endElement(ctx: ?*anyopaque, name: []const u8) void {
    const user_data: *Userdata = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, name, "way")) {
        user_data.in_way = false;
        if (user_data.found_highway) {
            user_data.points_out.writeInt(u32, 0xffffffff, .little) catch unreachable;
            for (user_data.this_way_nodes.items) |node_idx| {
                user_data.points_out.writeInt(u32, node_idx, .little) catch unreachable;
            }
            user_data.way_tags.append(user_data.this_way_tags.toOwnedSlice() catch unreachable) catch unreachable;
            user_data.this_way_tags.clearRetainingCapacity();
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
        .points_out = points_out_writer,
        .node_id_idx_map = std.AutoHashMap(i64, usize).init(alloc),
        .way_tags = std.ArrayList([]Metadata.Tag).init(alloc),
        .this_way_tags = std.ArrayList(Metadata.Tag).init(alloc),
        .this_way_nodes = std.ArrayList(u32).init(alloc),
    };
    defer userdata.deinit();

    try runParser(args.osm_data, .{
        .ctx = &userdata,
        .startElement = startElement,
        .endElement = endElement,
    });

    const metadata_out_f = try std.fs.cwd().createFile(metadata_path, .{});
    userdata.metadata.end_nodes = userdata.num_nodes * 8;
    userdata.metadata.way_tags = try userdata.way_tags.toOwnedSlice();
    try std.json.stringify(userdata.metadata, .{}, metadata_out_f.writer());

    for (userdata.metadata.way_tags) |way_tags| {
        for (way_tags) |tag| {
            alloc.free(tag.key);
            alloc.free(tag.val);
        }
        alloc.free(way_tags);
    }
    alloc.free(userdata.metadata.way_tags);
}
