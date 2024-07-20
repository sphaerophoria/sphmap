const std = @import("std");
const Metadata = @import("Metadata.zig");
const Allocator = std.mem.Allocator;

pub extern fn compileLinkProgram(vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) i32;
pub extern fn bind2DFloat32Data(data: [*]const f32, data_len: usize) i32;
pub extern fn bindEbo(data: [*]const u32, data_len: usize) i32;
pub extern fn glBindVertexArray(vao: i32) void;
pub extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
pub extern fn glClear(mask: i32) void;
pub extern fn glUseProgram(program: i32) void;
pub extern fn glDrawArrays(mode: i32, first: i32, last: i32) void;
pub extern fn glDrawElements(mode: i32, count: i32, type: i32, offs: i32) void;
pub extern fn glGetUniformLoc(program: i32, name: [*]const u8, name_len: usize) i32;
pub extern fn glUniform1f(loc: i32, val: f32) void;

const Gl = struct {
    // https://registry.khronos.org/webgl/specs/latest/1.0/
    const COLOR_BUFFER_BIT = 0x00004000;
    const POINTS = 0x0000;
    const LINE_STRIP = 0x0003;
    const UNSIGNED_INT = 0x1405;
};

const vs_source = @embedFile("vertex.glsl");
const fs_source = @embedFile("fragment.glsl");
const lat_center_key = "lat_center";
const lon_center_key = "lon_center";
const zoom_loc_key = "zoom";
const aspect_key = "aspect";

pub extern fn logWasm(s: [*]const u8, len: usize) void;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    logWasm(slice.ptr, slice.len);
}

pub export var global_chunk: [16384]u8 = undefined;

pub export fn pushData(len: usize) void {
    global.map_data.appendSlice(global_chunk[0..len]) catch unreachable;
}

pub export fn setMetadata(len: usize) void {
    const alloc = std.heap.wasm_allocator;
    const parsed = std.json.parseFromSlice(Metadata, alloc, global_chunk[0..len], .{}) catch unreachable;
    global.metadata = parsed.value;
}

const GlobalState = struct {
    mouse_down: bool = false,
    mouse_down_x: f32 = 0.0,
    mouse_down_y: f32 = 0.0,
    lat_center: f32 = 49.2,
    lon_center: f32 = -123,
    lat_center_loc: i32 = 0,
    lon_center_loc: i32 = 0,
    aspect: f32 = 1.0,
    aspect_loc: i32 = 0,
    zoom_loc: i32 = 0,
    program: i32 = 0,
    vao: i32 = 0,
    ebo: i32 = 0,
    zoom: f32 = 1.0,
    map_data: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
    metadata: Metadata = .{},
};

var global = GlobalState{};

pub export fn mouseDown(x_norm: f32, y_norm: f32) void {
    global.mouse_down = true;
    global.mouse_down_x = x_norm;
    global.mouse_down_y = y_norm;
}

pub export fn mouseMove(x_norm: f32, y_norm: f32) void {
    if (!global.mouse_down) {
        return;
    }
    global.lon_center -= (x_norm - global.mouse_down_x) / global.zoom * 2;
    global.lat_center += (y_norm - global.mouse_down_y) / global.zoom * 2;
    global.mouse_down_x = x_norm;
    global.mouse_down_y = y_norm;
    render();
}

pub export fn mouseUp() void {
    global.mouse_down = false;
}

pub export fn zoom(delta_y: f32) void {
    // [- num, +num]
    if (delta_y > 0) {
        global.zoom *= 0.5;
    } else if (delta_y < 0) {
        global.zoom *= 2.0;
    }
    render();
}

pub export fn setAspect(aspect: f32) void {
    global.aspect = aspect;
    render();
}

pub export fn init(aspect: f32) void {
    // Now create an array of positions for the square.
    global.program = compileLinkProgram(vs_source, vs_source.len, fs_source, fs_source.len);
    global.aspect = aspect;

    global.zoom = 2.0 / (global.metadata.max_lon - global.metadata.min_lon);
    global.lat_center = (global.metadata.max_lat + global.metadata.min_lat) / 2.0;
    global.lon_center = (global.metadata.max_lon + global.metadata.min_lon) / 2.0;
    const map_data_f32: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, global.map_data.items[0..@intCast(global.metadata.end_nodes)]));
    global.vao = bind2DFloat32Data(map_data_f32.ptr, map_data_f32.len);
    global.lat_center_loc = glGetUniformLoc(global.program, lat_center_key.ptr, lat_center_key.len);
    global.lon_center_loc = glGetUniformLoc(global.program, lon_center_key.ptr, lon_center_key.len);
    global.zoom_loc = glGetUniformLoc(global.program, zoom_loc_key.ptr, zoom_loc_key.len);
    global.aspect_loc = glGetUniformLoc(global.program, aspect_key.ptr, aspect_key.len);

    const index_data: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, global.map_data.items[@intCast(global.metadata.end_nodes)..]));
    global.ebo = bindEbo(index_data.ptr, index_data.len);
}

pub export fn render() void {
    glBindVertexArray(global.vao);
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(Gl.COLOR_BUFFER_BIT);

    glUseProgram(global.program);
    glUniform1f(global.lat_center_loc, global.lat_center);
    glUniform1f(global.lon_center_loc, global.lon_center);
    glUniform1f(global.zoom_loc, global.zoom);
    glUniform1f(global.aspect_loc, global.aspect);
    {
        const num_elems = (global.map_data.items.len - global.metadata.end_nodes) / 4;
        glDrawElements(Gl.LINE_STRIP, @intCast(num_elems), Gl.UNSIGNED_INT, 0);
    }
}
