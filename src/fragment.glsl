#version 300 es

precision highp float;
uniform float r;
uniform float g;
uniform float b;
out vec4 out_color;

void main() {
  out_color = vec4(r, g, b, 1.0);
}
