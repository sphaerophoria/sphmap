class WasmHandler {
  constructor(gl) {
    this.gl = gl;
    this.vaos = [];
    this.programs = [];
    this.uniform_locs = [];
    this.memory = null;
  }

  compileLinkProgram(vs, vs_len, fs, fs_len) {
    const dec = new TextDecoder("utf8");
    const vs_source = dec.decode(
      new Uint8Array(this.memory.buffer, vs, vs_len),
    );
    const fs_source = dec.decode(
      new Uint8Array(this.memory.buffer, fs, fs_len),
    );

    const vertexShader = loadShader(this.gl, this.gl.VERTEX_SHADER, vs_source);
    const fragmentShader = loadShader(
      this.gl,
      this.gl.FRAGMENT_SHADER,
      fs_source,
    );

    const shaderProgram = this.gl.createProgram();
    this.gl.attachShader(shaderProgram, vertexShader);
    this.gl.attachShader(shaderProgram, fragmentShader);
    this.gl.linkProgram(shaderProgram);
    if (!this.gl.getProgramParameter(shaderProgram, this.gl.LINK_STATUS)) {
      alert(
        `Unable to initialize the shader program: ${this.gl.getProgramInfoLog(
          shaderProgram,
        )}`,
      );
    }

    this.programs.push(shaderProgram);
    return this.programs.length - 1;
  }

  bind2DFloat32DataWasm(d, len) {
    const arr = new Float32Array(this.memory.buffer, d, len);
    vaos.push(bind2DFloat32Data(arr));
    return vaos.length - 1;
  }

  bind2DFloat32Data(ptr, len) {
    const positions = new Float32Array(this.memory.buffer, ptr, len);
    const positionBuffer = this.gl.createBuffer();
    this.gl.bindBuffer(this.gl.ARRAY_BUFFER, positionBuffer);
    this.gl.bufferData(this.gl.ARRAY_BUFFER, positions, this.gl.STATIC_DRAW);
    this.gl.vertexAttribPointer(0, 2, this.gl.FLOAT, false, 0, 0);
    this.gl.enableVertexAttribArray(0);
  }

  getUniformLocWasm(program, namep, name_len) {
    const name_data = new Uint8Array(this.memory.buffer, namep, name_len);
    const name = new TextDecoder("utf8").decode(name_data);
    this.uniform_locs.push(
      this.gl.getUniformLocation(this.programs[program], name),
    );
    return this.uniform_locs.length - 1;
  }

  glBindVertexArray(vao) {
    this.gl.bindVertexArray(this.vaos[vao]);
  }

  glUseProgram(program) {
    this.gl.useProgram(this.programs[program]);
  }

  glUniform1f(loc, val) {
    this.gl.uniform1f(this.uniform_locs[loc], val);
  }

  logWasm(s, len) {
    const buf = new Uint8Array(this.memory.buffer, s, len);
    console.log(new TextDecoder("utf8").decode(buf));
  }
}

function initCanvas() {
  const canvas = document.getElementById("canvas");
  canvas.width = canvas.clientWidth;
  canvas.height = canvas.clientHeight;
  return canvas;
}

function loadShader(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);

  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    alert(
      `An error occurred compiling the shaders: ${gl.getShaderInfoLog(shader)}`,
    );
    gl.deleteShader(shader);
    return null;
  }

  return shader;
}

async function instantiateWasmModule(wasm_handlers) {
  const wasmEnv = {
    env: {
      logWasm: wasm_handlers.logWasm.bind(wasm_handlers),
      compileLinkProgram: wasm_handlers.compileLinkProgram.bind(wasm_handlers),
      bind2DFloat32Data: wasm_handlers.bind2DFloat32Data.bind(wasm_handlers),
      glBindVertexArray: wasm_handlers.glBindVertexArray.bind(wasm_handlers),
      glClearColor: (...args) => wasm_handlers.gl.clearColor(...args),
      glClear: (...args) => wasm_handlers.gl.clear(...args),
      glUseProgram: wasm_handlers.glUseProgram.bind(wasm_handlers),
      glDrawArrays: (...args) => wasm_handlers.gl.drawArrays(...args),
      glGetUniformLoc: wasm_handlers.getUniformLocWasm.bind(wasm_handlers),
      glUniform1f: wasm_handlers.glUniform1f.bind(wasm_handlers),
    },
  };

  const mod = await WebAssembly.instantiateStreaming(
    fetch("index.wasm"),
    wasmEnv,
  );
  wasm_handlers.memory = mod.instance.exports.memory;

  return mod;
}

async function loadPointsData(mod) {
  const map_data_response = await fetch("map_data.bin");
  const data_reader = map_data_response.body.getReader({
    mode: "byob",
  });
  let array_buf = new ArrayBuffer(16384);
  while (true) {
    const { value, done } = await data_reader.read(new Uint8Array(array_buf));
    if (done) break;

    array_buf = value.buffer;
    const chunk_buf = new Uint8Array(
      mod.instance.exports.memory.buffer,
      mod.instance.exports.global_chunk.value,
      16384,
    );
    chunk_buf.set(value);
    mod.instance.exports.pushData(value.length);
  }
}

async function loadMetadata(mod) {
  const map_data_response = await fetch("map_data.json");
  const data = await map_data_response.arrayBuffer();

  const chunk_buf = new Uint8Array(
    mod.instance.exports.memory.buffer,
    mod.instance.exports.global_chunk.value,
    data.byteLength,
  );

  chunk_buf.set(new Uint8Array(data));

  mod.instance.exports.setMetadata(data.byteLength);
}

function canvasAspect(canvas) {
  const rect = canvas.getBoundingClientRect();
  return rect.width / rect.height;
}

class CanvasInputHandler {
  constructor(canvas, mod) {
    this.canvas = canvas;
    this.mod = mod;
  }

  normX(client_x) {
    const rect = this.canvas.getBoundingClientRect();
    return (client_x - rect.left) / rect.width;
  }

  normY(client_y) {
    const rect = this.canvas.getBoundingClientRect();
    return (client_y - rect.top) / rect.height;
  }

  onMouseDown(ev) {
    this.mod.instance.exports.mouseDown(
      this.normX(ev.clientX),
      this.normY(ev.clientY),
    );
  }

  onMouseMove(ev) {
    this.mod.instance.exports.mouseMove(
      this.normX(ev.clientX),
      this.normY(ev.clientY),
    );
  }

  onMouseUp() {
    this.mod.instance.exports.mouseUp();
  }

  onWheel(ev) {
    this.mod.instance.exports.zoom(ev.deltaY);
  }

  onResize() {
    this.mod.instance.exports.setAspect(canvasAspect(this.canvas));
  }

  setCanvasCallbacks() {
    this.canvas.onmousedown = this.onMouseDown.bind(this);
    window.onmouseup = this.onMouseUp.bind(this);
    this.canvas.onmousemove = this.onMouseMove.bind(this);
    this.canvas.onwheel = this.onWheel.bind(this);
    window.onresize = this.onResize.bind(this);
  }
}

function makeGl(canvas) {
  const gl = canvas.getContext("webgl2");

  if (gl === null) {
    throw new Error("Failed to initialize gl context");
  }

  return gl;
}

async function init() {
  const canvas = initCanvas();
  const wasm_handlers = new WasmHandler(makeGl(canvas));
  const mod = await instantiateWasmModule(wasm_handlers);
  await loadPointsData(mod);
  await loadMetadata(mod);

  mod.instance.exports.init(canvasAspect(canvas));
  mod.instance.exports.render();

  const canvas_callbacks = new CanvasInputHandler(canvas, mod);
  canvas_callbacks.setCanvasCallbacks();
  mod.instance.exports.render();
}

window.onload = init;
