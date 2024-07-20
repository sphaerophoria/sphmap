const std = @import("std");
const builtin = @import("builtin");
const Metadata = @import("Metadata.zig");

const c = @cImport({
    @cInclude("expat.h");
});

const Userdata = struct {
    points_out: std.io.AnyWriter,
    metadata: Metadata = .{},
    node_id_idx_map: std.AutoHashMap(i64, usize),
    num_nodes: u64 = 0,

    fn deinit(self: *Userdata) void {
        self.node_id_idx_map.deinit();
    }

    fn handleNode(user_data: *Userdata, attrs: [*c][*c]const c.XML_Char) void {
        defer user_data.num_nodes += 1;

        var i: usize = 0;
        var lat_opt: ?[]const u8 = null;
        var lon_opt: ?[]const u8 = null;
        var node_id_opt: ?[]const u8 = null;
        while (true) {
            if (attrs[i] == null) {
                break;
            }
            defer i += 2;

            const field_name = std.mem.span(attrs[i]);

            const field_val = std.mem.span(attrs[i + 1]);
            if (std.mem.eql(u8, field_name, "lat")) {
                lat_opt = field_val;
            } else if (std.mem.eql(u8, field_name, "lon")) {
                lon_opt = field_val;
            } else if (std.mem.eql(u8, field_name, "id")) {
                node_id_opt = field_val;
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

fn findAttributeVal(key: []const u8, attrs: [*c][*c]const c.XML_Char) ?[]const u8 {
    var i: usize = 0;
    while (true) {
        if (attrs[i] == null) {
            break;
        }
        defer i += 2;

        const field_name = std.mem.span(attrs[i]);

        const field_val = std.mem.span(attrs[i + 1]);
        if (std.mem.eql(u8, field_name, key)) {
            return field_val;
        }
    }

    return null;
}

fn startElement(ctx: ?*anyopaque, name_c: [*c]const c.XML_Char, attrs: [*c][*c]const c.XML_Char) callconv(.C) void {
    const user_data: *Userdata = @ptrCast(@alignCast(ctx));

    const name = std.mem.span(name_c);
    if (std.mem.eql(u8, name, "node")) {
        user_data.handleNode(attrs);
        return;
    } else if (std.mem.eql(u8, name, "way")) {
        user_data.points_out.writeInt(u32, 0xffffffff, .little) catch unreachable;
    } else if (std.mem.eql(u8, name, "nd")) {
        const node_id_s = findAttributeVal("ref", attrs) orelse return;
        const node_id = std.fmt.parseInt(i64, node_id_s, 10) catch unreachable;
        const node_idx = user_data.node_id_idx_map.get(node_id) orelse return;
        user_data.points_out.writeInt(u32, @intCast(node_idx), .little) catch unreachable;
    }
}

pub fn main() !void {
    const parser = c.XML_ParserCreate(null);
    defer c.XML_ParserFree(parser);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const out_f = try std.fs.cwd().createFile(args[2], .{});
    var points_out_buf_writer = std.io.bufferedWriter(out_f.writer());
    defer points_out_buf_writer.flush() catch unreachable;
    const points_out_writer = points_out_buf_writer.writer().any();

    const metadata_out_f = try std.fs.cwd().createFile(args[3], .{});

    const f = try std.fs.cwd().openFile(args[1], .{});
    defer f.close();

    var buffered_reader = std.io.bufferedReader(f.reader());

    if (parser == null) {
        return error.NoParser;
    }

    var userdata = Userdata{
        .points_out = points_out_writer,
        .node_id_idx_map = std.AutoHashMap(i64, usize).init(alloc),
    };
    defer userdata.deinit();
    c.XML_SetUserData(parser, &userdata);
    c.XML_SetElementHandler(parser, startElement, null);

    while (true) {
        const buf_size = 4096;
        const buf = c.XML_GetBuffer(parser, buf_size);
        if (buf == null) {
            return error.NoBuffer;
        }

        const buf_u8: [*]u8 = @ptrCast(buf);
        const buf_slice = buf_u8[0..buf_size];
        const read_data_len = try buffered_reader.read(buf_slice);
        if (read_data_len == 0) {
            break;
        }

        const parse_ret = c.XML_ParseBuffer(parser, @intCast(read_data_len), 0);
        if (parse_ret == c.XML_STATUS_ERROR) {
            return error.ParseError;
        }
    }

    userdata.metadata.end_nodes = userdata.num_nodes * 8;
    try std.json.stringify(userdata.metadata, .{}, metadata_out_f.writer());
}
