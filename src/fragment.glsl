#version 300 es

precision highp float;
uniform float color;
out vec4 out_color;

void main() {
  out_color = vec4(color, 1.0, 1.0, 1.0);
}
