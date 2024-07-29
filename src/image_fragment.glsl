#version 300 es

precision highp float;
uniform sampler2D u_texture;
in vec2 uv_out;
out vec4 out_color;

void main() {
  out_color = texture(u_texture, uv_out);
}
