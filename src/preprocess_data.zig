const std = @import("std");
const builtin = @import("builtin");
const Metadata = @import("Metadata.zig");

const c = @cImport({
    @cInclude("expat.h");
});

const Userdata = struct {
    points_out: std.io.AnyWriter,
    metadata: Metadata = .{},
    num_nodes: u64 = 0,
};

fn startElement(ctx: ?*anyopaque, name_c: [*c]const c.XML_Char, attrs: [*c][*c]const c.XML_Char) callconv(.C) void {
    const user_data: *Userdata = @ptrCast(@alignCast(ctx));

    const name = std.mem.span(name_c);
    if (!std.mem.eql(u8, name, "node")) {
        return;
    }

    var i: usize = 0;
    var lat_opt: ?[]const u8 = null;
    var lon_opt: ?[]const u8 = null;
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
        }
    }

    const lat_s = lat_opt orelse return;
    const lon_s = lon_opt orelse return;
    const lat = std.fmt.parseFloat(f32, lat_s) catch return;
    const lon = std.fmt.parseFloat(f32, lon_s) catch return;

    user_data.metadata.max_lon = @max(lon, user_data.metadata.max_lon);
    user_data.metadata.min_lon = @min(lon, user_data.metadata.min_lon);
    user_data.metadata.max_lat = @max(lat, user_data.metadata.max_lat);
    user_data.metadata.min_lat = @min(lat, user_data.metadata.min_lat);

    std.debug.assert(builtin.cpu.arch.endian() == .little);
    user_data.points_out.writeAll(std.mem.asBytes(&lon)) catch unreachable;
    user_data.points_out.writeAll(std.mem.asBytes(&lat)) catch unreachable;
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
    };
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

    try std.json.stringify(userdata.metadata, .{}, metadata_out_f.writer());
}
