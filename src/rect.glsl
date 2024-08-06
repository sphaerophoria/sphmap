#version 300 es
precision highp float;

uniform vec2 center;
uniform vec2 scale;

out vec2 uv_out;

const vec2 verts[4] = vec2[4](
    vec2(-1.0, -1.0),
    vec2(1.0f, -1.0f),
    vec2(-1.0f, 1.0f),
    vec2(1.0, 1.0)
);

void main() {
  uv_out = verts[gl_VertexID] / 2.0 + 0.5;
  uv_out.y *= -1.0;

  gl_Position = vec4(verts[gl_VertexID] * scale + center, 0, 1);
}
