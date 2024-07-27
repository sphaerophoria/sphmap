const std = @import("std");
const Metadata = @import("Metadata.zig");
const App = @import("App.zig");

pub const std_options = std.Options{
    .logFn = wasmLog,
    .log_level = .debug,
};

pub extern fn logWasm(s: [*]const u8, len: usize) void;
fn wasmLog(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = message_level;
    _ = scope;
    print(format, args);
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
        logWasm(&buf, buf.len);
        return;
    };
    logWasm(slice.ptr, slice.len);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    _ = error_return_trace;
    logWasm(msg.ptr, msg.len);
    asm volatile ("unreachable");
    unreachable;
}

pub export var global_chunk: [16384]u8 = undefined;

pub export fn pushMapData(len: usize) void {
    global.map_data.appendSlice(global_chunk[0..len]) catch unreachable;
}

pub export fn pushMetadata(len: usize) void {
    global.metadata_buf.appendSlice(global_chunk[0..len]) catch unreachable;
}

const GlobalState = struct {
    app: App = undefined,
    map_data: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
    metadata_buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
    metadata: Metadata = .{},
};

var global = GlobalState{};

pub export fn mouseDown(x_norm: f32, y_norm: f32) void {
    global.app.onMouseDown(x_norm, y_norm);
}

pub export fn mouseMove(x_norm: f32, y_norm: f32) void {
    global.app.onMouseMove(x_norm, y_norm) catch |e| {
        print("e: {any}", .{e});
        unreachable;
    };
}

pub export fn mouseUp() void {
    global.app.onMouseUp();
}

pub export fn zoom(delta_y: f32) void {
    // [- num, +num]
    if (delta_y > 0) {
        global.app.zoomOut();
    } else if (delta_y < 0) {
        global.app.zoomIn();
    }
}

pub export fn setAspect(aspect: f32) void {
    global.app.setAspect(aspect);
}

pub export fn init(aspect: f32) void {
    const parsed = std.json.parseFromSlice(Metadata, std.heap.wasm_allocator, global.metadata_buf.items, .{}) catch unreachable;
    global.metadata = parsed.value;

    global.app = App.init(std.heap.wasm_allocator, aspect, global.map_data.items, &global.metadata) catch |e| {
        std.log.err("app init failed: {any}", .{e});
        return;
    };
}

pub export fn render() void {
    global.app.render();
}

pub export fn setDebugWayFinding(val: bool) void {
    global.app.debug_way_finding = val;
    global.app.render();
}

pub export fn setDebugPointNeighbors(val: bool) void {
    global.app.debug_point_neighbors = val;
    global.app.render();
}

pub export fn setDebugPath(val: bool) void {
    global.app.debug_path_finding = val;
    global.app.render();
}

pub export fn startPath() void {
    global.app.startPath();
}

pub export fn stopPath() void {
    global.app.stopPath();
}
