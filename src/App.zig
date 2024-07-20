const std = @import("std");
const Metadata = @import("Metadata.zig");

const App = @This();

mouse_tracker: MouseTracker = .{},
renderer: Renderer,

pub fn init(aspect_val: f32, map_data: []const u8, metadata: Metadata) App {
    var ret = .{ .renderer = Renderer.init(aspect_val, map_data, metadata) };

    ret.renderer.render();

    return ret;
}

pub fn onMouseDown(self: *App, x: f32, y: f32) void {
    self.mouse_tracker.onDown(x, y);
}

pub fn onMouseUp(self: *App) void {
    self.mouse_tracker.onUp();
}

pub fn onMouseMove(self: *App, x: f32, y: f32) void {
    if (self.mouse_tracker.down) {
        const movement = self.mouse_tracker.getMovement(x, y);
        self.mouse_tracker.onDown(x, y);
        self.renderer.lon_center.val -= movement.x / self.renderer.zoom.val * 2;
        self.renderer.lat_center.val += movement.y / self.renderer.zoom.val * 2;
        self.renderer.render();
    }
}

pub fn zoomIn(self: *App) void {
    self.renderer.zoom.val *= 2.0;
    self.renderer.render();
}

pub fn zoomOut(self: *App) void {
    self.renderer.zoom.val *= 0.5;
    self.renderer.render();
}

const NormalizedPosition = struct {
    x: f32,
    y: f32,
};

const NormalizedOffset = struct {
    x: f32,
    y: f32,
};

const MouseTracker = struct {
    down: bool = false,
    pos: NormalizedPosition = undefined,

    pub fn onDown(self: *MouseTracker, x: f32, y: f32) void {
        self.down = true;
        self.pos.x = x;
        self.pos.y = y;
    }

    pub fn onUp(self: *MouseTracker) void {
        self.down = false;
    }

    pub fn getMovement(self: *MouseTracker, x: f32, y: f32) NormalizedOffset {
        return .{
            .x = x - self.pos.x,
            .y = y - self.pos.y,
        };
    }
};

const FloatUniform = struct {
    loc: i32,
    val: f32 = 0.0,

    fn init(program: i32, key: []const u8, val: f32) FloatUniform {
        const loc = js.glGetUniformLoc(program, key.ptr, key.len);
        return .{
            .loc = loc,
            .val = val,
        };
    }
};

fn setUniforms(uniforms: []const FloatUniform) void {
    for (uniforms) |uniform| {
        js.glUniform1f(uniform.loc, uniform.val);
    }
}

const js = struct {
    extern fn compileLinkProgram(vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) i32;
    extern fn bind2DFloat32Data(data: [*]const f32, data_len: usize) i32;
    extern fn bindEbo(data: [*]const u32, data_len: usize) i32;
    extern fn glBindVertexArray(vao: i32) void;
    extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
    extern fn glClear(mask: i32) void;
    extern fn glUseProgram(program: i32) void;
    extern fn glDrawArrays(mode: i32, first: i32, last: i32) void;
    extern fn glDrawElements(mode: i32, count: i32, type: i32, offs: i32) void;
    extern fn glGetUniformLoc(program: i32, name: [*]const u8, name_len: usize) i32;
    extern fn glUniform1f(loc: i32, val: f32) void;
};

const Gl = struct {
    // https://registry.khronos.org/webgl/specs/latest/1.0/
    const COLOR_BUFFER_BIT = 0x00004000;
    const POINTS = 0x0000;
    const LINE_STRIP = 0x0003;
    const UNSIGNED_INT = 0x1405;
};

const vs_source = @embedFile("vertex.glsl");
const fs_source = @embedFile("fragment.glsl");

const Renderer = struct {
    program: i32,
    vao: i32,
    ebo: i32,
    lat_center: FloatUniform,
    lon_center: FloatUniform,
    aspect: FloatUniform,
    zoom: FloatUniform,
    num_line_segments: usize,

    pub fn init(aspect_val: f32, map_data: []const u8, metadata: Metadata) Renderer {
        // Now create an array of positions for the square.
        const program = js.compileLinkProgram(vs_source, vs_source.len, fs_source, fs_source.len);

        const point_data: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, map_data[0..@intCast(metadata.end_nodes)]));
        const vao = js.bind2DFloat32Data(point_data.ptr, point_data.len);

        const lat_center = FloatUniform.init(program, "lat_center", (metadata.max_lat + metadata.min_lat) / 2.0);

        const lon_center = FloatUniform.init(program, "lon_center", (metadata.max_lon + metadata.min_lon) / 2.0);

        const zoom = FloatUniform.init(program, "zoom", 2.0 / (metadata.max_lon - metadata.min_lon));

        const aspect = FloatUniform.init(program, "aspect", aspect_val);

        const index_data: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, map_data[@intCast(metadata.end_nodes)..]));
        const ebo = js.bindEbo(index_data.ptr, index_data.len);

        return .{
            .program = program,
            .vao = vao,
            .ebo = ebo,
            .lat_center = lat_center,
            .lon_center = lon_center,
            .aspect = aspect,
            .zoom = zoom,
            .num_line_segments = index_data.len,
        };
    }

    pub fn setAspect(self: *Renderer, aspect: f32) void {
        self.aspect.val = aspect;
        self.render();
    }

    pub fn render(self: *Renderer) void {
        js.glBindVertexArray(self.vao);
        js.glClearColor(0.0, 0.0, 0.0, 1.0);
        js.glClear(Gl.COLOR_BUFFER_BIT);

        js.glUseProgram(self.program);
        setUniforms(&.{ self.lat_center, self.lon_center, self.zoom, self.aspect });
        {
            js.glDrawElements(Gl.LINE_STRIP, @intCast(self.num_line_segments), Gl.UNSIGNED_INT, 0);
        }
    }
};
