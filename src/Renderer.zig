const std = @import("std");
const gui = @import("gui_bindings.zig");
const lin = @import("lin.zig");
const gl_utils = @import("gl_utils.zig");
const FloatUniform = gl_utils.FloatUniform;
const Gl = gl_utils.Gl;
const map_data = @import("map_data.zig");
const MapPos = lin.Point;
const NodeId = map_data.NodeId;
const Way = map_data.Way;

index_buffer: []const u32,
program: i32,
vao: i32,
custom_vao: i32,
ebo: i32,
custom_ebo: i32,
lat_center: FloatUniform,
lon_center: FloatUniform,
aspect: FloatUniform,
zoom: FloatUniform,
r: FloatUniform,
g: FloatUniform,
b: FloatUniform,
point_size: FloatUniform,
num_line_segments: usize,

const Renderer = @This();

pub fn init(point_data: []const f32, index_data: []const u32) Renderer {
    // Now create an array of positions for the square.
    const program = gui.compileLinkProgram(vs_source, vs_source.len, fs_source, fs_source.len);

    const vao = uploadMapPoints(point_data);
    const custom_vao = uploadMapPoints(&.{});

    const lat_center = FloatUniform.init(program, "lat_center");

    const lon_center = FloatUniform.init(program, "lon_center");

    const zoom = FloatUniform.init(program, "zoom");

    const aspect = FloatUniform.init(program, "aspect");
    const r = FloatUniform.init(program, "r");
    const g = FloatUniform.init(program, "g");
    const b = FloatUniform.init(program, "b");
    const point_size = FloatUniform.init(program, "point_size");

    const ebo = setupMapIndices(index_data);

    const custom_ebo = gui.glCreateBuffer();

    return .{
        .index_buffer = index_data,
        .program = program,
        .vao = vao,
        .custom_vao = custom_vao,
        .ebo = ebo,
        .custom_ebo = custom_ebo,
        .lat_center = lat_center,
        .lon_center = lon_center,
        .aspect = aspect,
        .zoom = zoom,
        .point_size = point_size,
        .r = r,
        .g = g,
        .b = b,
        .num_line_segments = index_data.len,
    };
}

pub fn bind(self: *Renderer) BoundRenderer {
    gui.glBindVertexArray(self.vao);
    gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, self.ebo);
    gui.glUseProgram(self.program);
    return .{
        .inner = self,
    };
}

pub const ViewState = struct {
    center: MapPos,
    zoom: f32,
    aspect: f32,
};

const vs_source = @embedFile("vertex.glsl");
const fs_source = @embedFile("fragment.glsl");

fn uploadMapPoints(data: []const f32) i32 {
    const vao = gui.glCreateVertexArray();
    gui.glBindVertexArray(vao);

    const vbo = gui.glCreateBuffer();
    gui.glBindBuffer(Gl.ARRAY_BUFFER, vbo);
    if (data.len > 0) {
        gui.glBufferData(Gl.ARRAY_BUFFER, @ptrCast(data.ptr), data.len * 4, Gl.STATIC_DRAW);
    }
    gui.glVertexAttribPointer(0, 2, Gl.FLOAT, false, 0, 0);
    gui.glEnableVertexAttribArray(0);
    return vao;
}

fn setupMapIndices(indices: []const u32) i32 {
    const ebo = gui.glCreateBuffer();
    gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, ebo);
    gui.glBufferData(
        Gl.ELEMENT_ARRAY_BUFFER,
        @ptrCast(indices.ptr),
        indices.len * 4,
        Gl.STATIC_DRAW,
    );
    return ebo;
}

const BoundRenderer = struct {
    inner: *Renderer,

    pub fn render(self: *const BoundRenderer, view_state: ViewState) void {
        gui.glBindVertexArray(self.inner.vao);
        gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, self.inner.ebo);

        self.inner.lat_center.set(view_state.center.y);
        self.inner.lon_center.set(view_state.center.x);
        self.inner.aspect.set(view_state.aspect);
        self.inner.zoom.set(view_state.zoom);
        self.inner.r.set(1.0);
        self.inner.g.set(1.0);
        self.inner.b.set(1.0);
        gui.glDrawElements(Gl.LINE_STRIP, @intCast(self.inner.num_line_segments), Gl.UNSIGNED_INT, 0);

        self.inner.point_size.set(10.0);
        self.renderCoords(&.{ view_state.center.x, view_state.center.y }, Gl.POINTS);
    }

    pub fn renderPoints(self: *const BoundRenderer, point_ids: []const NodeId, mode: i32) void {
        if (point_ids.len == 0) {
            return;
        }

        gui.glBindVertexArray(self.inner.vao);

        gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, self.inner.custom_ebo);
        gui.glBufferData(
            Gl.ELEMENT_ARRAY_BUFFER,
            @ptrCast(point_ids.ptr),
            point_ids.len * 4,
            Gl.STATIC_DRAW,
        );
        gui.glDrawElements(mode, @intCast(point_ids.len), Gl.UNSIGNED_INT, 0);
    }

    pub fn renderSelectedWay(self: *const BoundRenderer, way: Way) void {
        gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, self.inner.ebo);
        const point_ids = way.indexRange(self.inner.index_buffer);
        gui.glBindVertexArray(self.inner.vao);
        self.inner.r.set(0.0);
        self.inner.g.set(1.0);
        self.inner.b.set(1.0);
        gui.glDrawElements(Gl.LINE_STRIP, @intCast(point_ids.end - point_ids.start), Gl.UNSIGNED_INT, @intCast(point_ids.start * 4));
    }

    pub fn renderCoords(self: *const BoundRenderer, coords: []const f32, mode: i32) void {
        gui.glBindVertexArray(self.inner.custom_vao);
        gui.glBindBuffer(Gl.ELEMENT_ARRAY_BUFFER, self.inner.ebo);
        gui.glBufferData(Gl.ARRAY_BUFFER, @ptrCast(coords.ptr), @intCast(coords.len * 4), Gl.STATIC_DRAW);
        gui.glDrawArrays(mode, 0, @intCast(coords.len / 2));
    }
};
