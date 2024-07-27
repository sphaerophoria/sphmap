const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;

const Inner = struct {
    parser: *c.XML_ParserStruct,
    callbacks: Callbacks,
    err: ?anyerror = null,
};

alloc: Allocator,
inner: *Inner,

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
    startElement: *const fn (ctx: ?*anyopaque, name: []const u8, attrs: *XmlAttrIter) anyerror!void,
    endElement: *const fn (ctx: ?*anyopaque, name: []const u8) anyerror!void,
};

const XmlParser = @This();

const Error = error{
    CreateParser,
    ParseError,
} || Allocator.Error;

pub fn init(alloc: Allocator, callbacks: Callbacks) Error!XmlParser {
    const parser = c.XML_ParserCreate(null);
    if (parser == null) {
        return Error.CreateParser;
    }
    errdefer c.XML_ParserFree(parser);

    const inner = try alloc.create(Inner);
    errdefer alloc.destroy(inner);
    inner.* = .{
        .parser = parser.?,
        .callbacks = callbacks,
    };

    c.XML_SetUserData(parser, @constCast(inner));
    c.XML_SetElementHandler(parser, startElement, endElement);

    return .{
        .alloc = alloc,
        .inner = inner,
    };
}

pub fn deinit(self: *XmlParser) void {
    c.XML_ParserFree(self.inner.parser);
    self.alloc.destroy(self.inner);
}

pub fn feed(self: *XmlParser, data: []const u8) !void {
    try self.feedPriv(data, false);
}

pub fn finish(self: *XmlParser) !void {
    try self.feedPriv(&.{}, true);
}

fn feedPriv(self: *XmlParser, data: []const u8, finished: bool) !void {
    const parse_ret = c.XML_Parse(self.inner.parser, data.ptr, @intCast(data.len), @intFromBool(finished));
    if (parse_ret == c.XML_STATUS_ERROR) {
        const code = c.XML_GetErrorCode(self.inner.parser);
        if (code == c.XML_ERROR_ABORTED) {
            if (self.inner.err) |e| {
                return e;
            }
        }
        return Error.ParseError;
    }
}

fn startElement(ctx: ?*anyopaque, name_c: [*c]const c.XML_Char, attrs: [*c][*c]const c.XML_Char) callconv(.C) void {
    const inner: *Inner = @ptrCast(@alignCast(ctx));
    const name = std.mem.span(name_c);
    var it = XmlAttrIter{
        .attrs = attrs,
    };

    inner.callbacks.startElement(inner.callbacks.ctx, name, &it) catch |e| {
        _ = c.XML_StopParser(inner.parser, 0);
        inner.err = e;
    };
}

fn endElement(ctx: ?*anyopaque, name_c: [*c]const c.XML_Char) callconv(.C) void {
    const inner: *Inner = @ptrCast(@alignCast(ctx));
    const name = std.mem.span(name_c);

    inner.callbacks.endElement(inner.callbacks.ctx, name) catch |e| {
        _ = c.XML_StopParser(inner.parser, 0);
        inner.err = e;
    };
}
