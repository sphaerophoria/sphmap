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
    global.app.onMouseMove(x_norm, y_norm);
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

    global.app = App.init(std.heap.wasm_allocator, aspect, global.map_data.items, &global.metadata) catch unreachable;
}

pub export fn render() void {
    global.app.render();
}

pub export fn setDebug(val: bool) void {
    global.app.debug = val;
    global.app.render();
}
