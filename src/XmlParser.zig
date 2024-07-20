const std = @import("std");
const c = @import("c.zig");

parser: *c.XML_ParserStruct,

pub const XmlAttrIter = struct {
    attrs: [*c][*c]const c.XML_Char,
    i: usize = 0,

    const Output = struct {
        key: []const u8,
        val: []const u8,
    };

    pub fn next(self: *XmlAttrIter) ?Output {
        if (self.attrs[self.i] == null) {
            return null;
        }

        defer self.i += 2;

        const key = std.mem.span(self.attrs[self.i]);
        const val = std.mem.span(self.attrs[self.i + 1]);

        return .{
            .key = key,
            .val = val,
        };
    }
};

pub const Callbacks = struct {
    ctx: ?*anyopaque,
    startElement: *const fn (ctx: ?*anyopaque, name: []const u8, attrs: *XmlAttrIter) void,
};

const XmlParser = @This();

const Error = error{
    CreateParser,
    ParseError,
};

pub fn init(callbacks: *const Callbacks) Error!XmlParser {
    const parser = c.XML_ParserCreate(null);
    if (parser == null) {
        return Error.CreateParser;
    }
    errdefer c.XML_ParserFree(parser);

    c.XML_SetUserData(parser, @constCast(callbacks));
    c.XML_SetElementHandler(parser, startElement, null);

    return .{
        .parser = parser.?,
    };
}

pub fn deinit(self: *XmlParser) void {
    c.XML_ParserFree(self.parser);
}

pub fn feed(self: *XmlParser, data: []const u8) Error!void {
    try self.feedPriv(data, false);
}

pub fn finish(self: *XmlParser) Error!void {
    try self.feedPriv(&.{}, true);
}

fn feedPriv(self: *XmlParser, data: []const u8, finished: bool) Error!void {
    const parse_ret = c.XML_Parse(self.parser, data.ptr, @intCast(data.len), @intFromBool(finished));
    if (parse_ret == c.XML_STATUS_ERROR) {
        return Error.ParseError;
    }
}

fn startElement(ctx: ?*anyopaque, name_c: [*c]const c.XML_Char, attrs: [*c][*c]const c.XML_Char) callconv(.C) void {
    const callbacks: *const Callbacks = @ptrCast(@alignCast(ctx));
    const name = std.mem.span(name_c);
    var it = XmlAttrIter{
        .attrs = attrs,
    };

    callbacks.startElement(callbacks.ctx, name, &it);
}
