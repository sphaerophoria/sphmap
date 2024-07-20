const std = @import("std");
const Metadata = @import("Metadata.zig");
const App = @import("App.zig");
const Allocator = std.mem.Allocator;

pub extern fn logWasm(s: [*]const u8, len: usize) void;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    logWasm(slice.ptr, slice.len);
}

pub export var global_chunk: [16384]u8 = undefined;

pub export fn pushMapData(len: usize) void {
    global.map_data.appendSlice(global_chunk[0..len]) catch unreachable;
}

pub export fn setMetadata(len: usize) void {
    const alloc = std.heap.wasm_allocator;
    const parsed = std.json.parseFromSlice(Metadata, alloc, global_chunk[0..len], .{}) catch unreachable;
    global.metadata = parsed.value;
}

const GlobalState = struct {
    app: App = undefined,
    map_data: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
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
    global.app.renderer.setAspect(aspect);
}

pub export fn init(aspect: f32) void {
    global.app = App.init(aspect, global.map_data.items, global.metadata);
}

pub export fn render() void {
    global.app.renderer.render();
}
