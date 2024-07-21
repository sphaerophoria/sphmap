#version 300 es
precision highp float;

in vec4 aVertexPosition;
uniform float lat_center;
uniform float lon_center;
uniform float zoom;
uniform float aspect;
uniform float point_size;

void main() {
  gl_Position = aVertexPosition;
  // 0, 0 == lat_center, lon_center
  gl_Position.y -= lat_center; //49.10902;
  gl_Position.y *= aspect * zoom;
  gl_Position.x -= lon_center; //123.50649;
  gl_Position.x *= zoom;
  gl_PointSize = point_size;
}
