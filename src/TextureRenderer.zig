const std = @import("std");
const gui = @import("gui_bindings.zig");
const lin = @import("lin.zig");
const Point = lin.Point;
const Vec = lin.Vec;
const gl_utils = @import("gl_utils.zig");
const Gl = gl_utils.Gl;
const FloatUniform = gl_utils.FloatUniform;
const IntUniform = gl_utils.IntUniform;

program: i32,
vao: i32,
texture: IntUniform,
center: FloatUniform,
scale: FloatUniform,

const TextureRenderer = @This();

const rect_source = @embedFile("rect.glsl");
const image_frag = @embedFile("image_fragment.glsl");

pub fn init() TextureRenderer {
    const program = gui.compileLinkProgram(rect_source, rect_source.len, image_frag.ptr, image_frag.len);

    const vao = gui.glCreateVertexArray();
    const texture = IntUniform.init(program, "u_texture");
    const center = FloatUniform.init(program, "center");
    const scale = FloatUniform.init(program, "scale");

    return .{
        .program = program,
        .vao = vao,
        .texture = texture,
        .center = center,
        .scale = scale,
    };
}

pub fn bind(self: *TextureRenderer) BoundRenderer {
    gui.glUseProgram(self.program);
    gui.glBindVertexArray(self.vao);
    return .{
        .inner = self,
    };
}

const BoundRenderer = struct {
    inner: *TextureRenderer,

    pub fn render(self: *BoundRenderer, texture: i32, center: Point, scale: Vec) void {
        gui.glActiveTexture(Gl.TEXTURE0);
        gui.glBindTexture(Gl.TEXTURE_2D, texture);
        self.inner.texture.set(0);
        self.inner.center.set2(center.x, center.y);
        self.inner.scale.set2(scale.x, scale.y);
        gui.glDrawArrays(Gl.TRIANGLE_STRIP, 0, 4);
    }
};
