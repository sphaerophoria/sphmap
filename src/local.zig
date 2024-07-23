const std = @import("std");
const App = @import("App.zig");
const Metadata = @import("Metadata.zig");
const Allocator = std.mem.Allocator;

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

    var app = try App.init(alloc, 1.0, map_data, &parsed.value);
    defer app.deinit();

    app.onMouseDown(0.5, 0.5);
    app.onMouseMove(0.4, 0.4);
    app.onMouseMove(0.5, 0.6);
    app.onMouseMove(0.6, 0.6);
    app.onMouseUp();

    app.zoomIn();
    app.zoomOut();

    app.setAspect(0.5);

    app.debug = true;
    app.render();
}
