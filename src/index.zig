const std = @import("std");
const Metadata = @import("Metadata.zig");
const App = @import("App.zig");
const ImageTileData = @import("image_tile_data.zig").ImageTileData;

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

pub export fn pushImageTileData(len: usize) void {
    global.image_tile_metadata_buf.appendSlice(global_chunk[0..len]) catch unreachable;
}

pub export fn pushConfigPreset(len: usize) void {
    global.config_preset_buf.appendSlice(global_chunk[0..len]) catch unreachable;
}

const GlobalState = struct {
    app: *App = undefined,
    map_data: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
    metadata_buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
    image_tile_metadata_buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
    config_preset_buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.heap.wasm_allocator),
    metadata: Metadata = .{},
    image_tile_metadata: ImageTileData = &.{},
};

var global = GlobalState{};

pub export fn mouseDown(x_norm: f32, y_norm: f32) void {
    global.app.onMouseDown(x_norm, y_norm);
}

pub export fn mouseMove(x_norm: f32, y_norm: f32) void {
    global.app.onMouseMove(x_norm, y_norm) catch |e| {
        print("e: {any}", .{e});
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

    const parsed_image_tile = std.json.parseFromSlice(ImageTileData, std.heap.wasm_allocator, global.image_tile_metadata_buf.items, .{}) catch unreachable;
    global.image_tile_metadata = parsed_image_tile.value;

    global.app = App.init(std.heap.wasm_allocator, aspect, global.map_data.items, &global.metadata, global.image_tile_metadata) catch |e| {
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

pub export fn setTurningCost(cost: f32) void {
    global.app.turning_cost = cost;
}

pub export fn registerTexture(id: usize, tex: i32) void {
    global.app.registerTexture(id, tex) catch |e| {
        std.log.err("Failed to register texture: {any}", .{e});
    };
}

pub export fn monitorWayAttribute(k: [*]u8, v: [*]u8) void {
    global.app.monitorWayAttribute(k, v) catch |e| {
        std.log.err("Failed to monitor way: {any}", .{e});
    };
}

pub export fn removeMonitoredAttribute(id: usize) void {
    global.app.removeMonitoredAttribute(id) catch |e| {
        std.log.err("Failed to remove monitored attribute: {s}", .{@errorName(e)});
    };
}

fn colorf32(c: u8) f32 {
    return @as(f32, @floatFromInt(c)) / 255.0;
}

pub export fn setMonitoredColor(id: usize, r: u8, g: u8, b: u8) void {
    global.app.monitored_attributes.rendering.update(id, colorf32(r), colorf32(g), colorf32(b));
}

pub export fn setMonitoredCostMultiplier(id: usize, multiplier: f32) void {
    global.app.monitored_attributes.cost.update(id, multiplier) catch |e| {
        std.log.err("Failed to set cost multiplier: {s}", .{@errorName(e)});
    };
}
