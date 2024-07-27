const std = @import("std");
const App = @import("App.zig");
const Metadata = @import("Metadata.zig");
const Allocator = std.mem.Allocator;

var global_counter: i32 = 0;

fn newId() i32 {
    global_counter += 1;
    return global_counter;
}

pub export fn compileLinkProgram(vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) i32 {
    _ = vs;
    _ = vs_len;
    _ = fs;
    _ = fs_len;
    return newId();
}

pub export fn glCreateVertexArray() i32 {
    return newId();
}

pub export fn glCreateBuffer() i32 {
    return newId();
}

pub export fn glVertexAttribPointer(index: i32, size: i32, typ: i32, normalized: bool, stride: i32, offs: i32) void {
    _ = index;
    _ = size;
    _ = typ;
    _ = normalized;
    _ = stride;
    _ = offs;
}

pub export fn glEnableVertexAttribArray(index: i32) void {
    _ = index;
}

pub export fn glBindBuffer(target: i32, id: i32) void {
    _ = target;
    _ = id;
}

pub export fn glBufferData(target: i32, ptr: [*]const u8, len: usize, usage: i32) void {
    _ = target;
    _ = ptr;
    _ = len;
    _ = usage;
}

pub export fn glBindVertexArray(vao: i32) void {
    _ = vao;
}

pub export fn glClearColor(r: f32, g: f32, b: f32, a: f32) void {
    _ = r;
    _ = g;
    _ = b;
    _ = a;
}

pub export fn glClear(mask: i32) void {
    _ = mask;
}

pub export fn glUseProgram(program: i32) void {
    _ = program;
}

pub export fn glDrawArrays(mode: i32, first: i32, last: i32) void {
    _ = mode;
    _ = first;
    _ = last;
}

pub export fn glDrawElements(mode: i32, count: i32, typ: i32, offs: i32) void {
    _ = mode;
    _ = count;
    _ = typ;
    _ = offs;
}

pub export fn glGetUniformLoc(program: i32, name: [*]const u8, name_len: usize) i32 {
    _ = program;
    _ = name;
    _ = name_len;
    return newId();
}

pub export fn glUniform1f(loc: i32, val: f32) void {
    _ = loc;
    _ = val;
}

pub export fn glUniform2f(loc: i32, a: f32, b: f32) void {
    _ = loc;
    _ = a;
    _ = b;
}

pub export fn glUniform1i(loc: i32, val: i32) void {
    _ = loc;
    _ = val;
}

pub export fn glActiveTexture(val: i32) void {
    _ = val;
}

pub export fn glBindTexture(target: i32, val: i32) void {
    _ = target;
    _ = val;
}

pub export fn clearTags() void {}

pub export fn pushTag(key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void {
    _ = key;
    _ = key_len;
    _ = val;
    _ = val_len;
}

pub export fn setNodeId(id: usize) void {
    _ = id;
}

pub export fn fetchTexture(id: usize, url: [*]const u8, len: usize) void {
    _ = id;
    _ = url;
    _ = len;
}

pub export fn pushMonitoredAttribute(id: usize, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void {
    _ = id;
    _ = key;
    _ = key_len;
    _ = val;
    _ = val_len;
}

fn readFileData(alloc: Allocator, p: []const u8) ![]u8 {
    const cwd = std.fs.cwd();
    var f = try cwd.openFile(p, .{});
    defer f.close();
    return try f.readToEndAlloc(alloc, 1 << 30);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const map_data = try readFileData(alloc, args[1]);
    defer alloc.free(map_data);

    const map_metadata = try readFileData(alloc, args[2]);
    defer alloc.free(map_metadata);

    const parsed = try std.json.parseFromSlice(Metadata, alloc, map_metadata, .{});
    defer parsed.deinit();

    // FIXME: Add image tiles
    var app = try App.init(alloc, 1.0, map_data, &parsed.value, &.{});
    defer app.deinit();

    const monitor_key = app.string_table.findByStringContent("highway");
    const monitor_val = app.string_table.findByStringContent("footway");
    const monitor_key_p = app.string_table.get(monitor_key);
    const monitor_val_p = app.string_table.get(monitor_val);

    try app.monitorWayAttribute(monitor_key_p.ptr, monitor_val_p.ptr);

    app.onMouseDown(0.5, 0.5);
    try app.onMouseMove(0.4, 0.4);
    try app.onMouseMove(0.5, 0.6);
    try app.onMouseMove(0.6, 0.6);
    app.onMouseUp();

    app.zoomIn();
    app.zoomOut();

    app.setAspect(0.5);

    app.debug_way_finding = true;
    app.debug_point_neighbors = true;
    app.render();
}
