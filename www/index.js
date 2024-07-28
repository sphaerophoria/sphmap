class ObjectRegistry {
  constructor() {
    this.objects = [];
  }

  push(obj) {
    this.objects.push(obj);
    return this.objects.length - 1;
  }

  get(id) {
    return this.objects[id];
  }
}

class WasmHandler {
  constructor(gl, tags_div) {
    this.gl = gl;
    this.tags_div = tags_div;
    this.gl_objects = new ObjectRegistry();
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

    return this.gl_objects.push(shaderProgram);
  }

  bind2DFloat32Data(ptr, len) {
    const positions = new Float32Array(this.memory.buffer, ptr, len);
    const positionBuffer = this.gl.createBuffer();
    const vao = this.gl.createVertexArray();
    this.gl.bindVertexArray(vao);
    this.gl.bindBuffer(this.gl.ARRAY_BUFFER, positionBuffer);
    this.gl.bufferData(this.gl.ARRAY_BUFFER, positions, this.gl.STATIC_DRAW);
    this.gl.vertexAttribPointer(0, 2, this.gl.FLOAT, false, 0, 0);
    this.gl.enableVertexAttribArray(0);
    return this.gl_objects.push(vao);
  }

  glCreateVertexArray() {
    return this.gl_objects.push(this.gl.createVertexArray());
  }

  glCreateBuffer() {
    return this.gl_objects.push(this.gl.createBuffer());
  }

  glBindBuffer(target, buffer) {
    this.gl.bindBuffer(target, this.gl_objects.get(buffer));
  }

  glBufferData(target, ptr, len, usage) {
    const data = new Uint8Array(this.memory.buffer, ptr, len);
    this.gl.bufferData(target, data, usage);
  }

  getUniformLocWasm(program, namep, name_len) {
    const name_data = new Uint8Array(this.memory.buffer, namep, name_len);
    const name = new TextDecoder("utf8").decode(name_data);
    return this.gl_objects.push(
      this.gl.getUniformLocation(this.gl_objects.get(program), name),
    );
  }

  glBindVertexArray(vao) {
    this.gl.bindVertexArray(this.gl_objects.get(vao));
  }

  glUseProgram(program) {
    this.gl.useProgram(this.gl_objects.get(program));
  }

  glUniform1f(loc, val) {
    this.gl.uniform1f(this.gl_objects.get(loc), val);
  }

  logWasm(s, len) {
    const buf = new Uint8Array(this.memory.buffer, s, len);
    if (len == 0) {
      return;
    }
    console.log(new TextDecoder("utf8").decode(buf));
  }

  clearTags() {
    this.tags_div.innerHTML = "";
  }

  pushTag(k, k_len, v, v_len) {
    const k_buf = new Uint8Array(this.memory.buffer, k, k_len);
    const v_buf = new Uint8Array(this.memory.buffer, v, v_len);

    const dec = new TextDecoder("utf8");
    const ks = dec.decode(k_buf);
    const vs = dec.decode(v_buf);

    const div = document.createElement("div");
    div.innerHTML = `${ks}: ${vs}`;
    this.tags_div.append(div);
  }

  setNodeId(id) {
    const div = document.getElementById("node_id");
    div.innerHTML = "Closest node: " + id;
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
      glCreateBuffer: wasm_handlers.glCreateBuffer.bind(wasm_handlers),
      glBindBuffer: wasm_handlers.glBindBuffer.bind(wasm_handlers),
      glBufferData: wasm_handlers.glBufferData.bind(wasm_handlers),
      glCreateVertexArray:
        wasm_handlers.glCreateVertexArray.bind(wasm_handlers),
      glVertexAttribPointer: (...args) => {
        console.log(...args);
        wasm_handlers.gl.vertexAttribPointer(...args);
      },
      glEnableVertexAttribArray: (...args) =>
        wasm_handlers.gl.enableVertexAttribArray(...args),
      glClearColor: (...args) => wasm_handlers.gl.clearColor(...args),
      glClear: (...args) => wasm_handlers.gl.clear(...args),
      glUseProgram: wasm_handlers.glUseProgram.bind(wasm_handlers),
      glDrawArrays: (...args) => wasm_handlers.gl.drawArrays(...args),
      glDrawElements: (...args) => wasm_handlers.gl.drawElements(...args),
      glGetUniformLoc: wasm_handlers.getUniformLocWasm.bind(wasm_handlers),
      glUniform1f: wasm_handlers.glUniform1f.bind(wasm_handlers),
      clearTags: wasm_handlers.clearTags.bind(wasm_handlers),
      pushTag: wasm_handlers.pushTag.bind(wasm_handlers),
      setNodeId: wasm_handlers.setNodeId.bind(wasm_handlers),
    },
  };

  const mod = await WebAssembly.instantiateStreaming(
    fetch("index.wasm"),
    wasmEnv,
  );
  wasm_handlers.memory = mod.instance.exports.memory;

  return mod;
}

async function loadDataFromServer(uri, mod, pushFn) {
  const map_data_response = await fetch(uri);
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
    pushFn(value.length);
  }
}
async function loadPointsData(mod) {
  await loadDataFromServer(
    "map_data.bin",
    mod,
    mod.instance.exports.pushMapData,
  );
}

async function loadMetadata(mod) {
  await loadDataFromServer(
    "map_data.json",
    mod,
    mod.instance.exports.pushMetadata,
  );
}

function canvasAspect(canvas) {
  const rect = canvas.getBoundingClientRect();
  return rect.width / rect.height;
}

class CanvasInputHandler {
  constructor(gl, canvas, mod) {
    this.gl = gl;
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
    this.canvas.width = canvas.clientWidth;
    this.canvas.height = canvas.clientHeight;
    this.gl.viewport(0, 0, canvas.width, canvas.height);
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
  const tags_div = document.getElementById("tags");
  const gl = makeGl(canvas);
  const wasm_handlers = new WasmHandler(gl, tags_div);
  const mod = await instantiateWasmModule(wasm_handlers);
  await loadPointsData(mod);
  await loadMetadata(mod);

  mod.instance.exports.init(canvasAspect(canvas));
  mod.instance.exports.render();

  const debug_way_finding = document.getElementById("debug_way_finding");
  debug_way_finding.onchange = (ev) => {
    mod.instance.exports.setDebugWayFinding(ev.target.checked);
  };
  mod.instance.exports.setDebugWayFinding(debug_way_finding.checked);

  const debug_point_neighbors = document.getElementById(
    "debug_point_neighbors",
  );
  debug_point_neighbors.onchange = (ev) => {
    mod.instance.exports.setDebugPointNeighbors(ev.target.checked);
  };
  mod.instance.exports.setDebugPointNeighbors(debug_point_neighbors.checked);

  const debug_path = document.getElementById("debug_path");
  debug_path.onchange = (ev) => {
    mod.instance.exports.setDebugPath(ev.target.checked);
  };
  mod.instance.exports.setDebugPath(debug_path.checked);

  const canvas_callbacks = new CanvasInputHandler(gl, canvas, mod);
  canvas_callbacks.setCanvasCallbacks();
  mod.instance.exports.render();

  const start_path = document.getElementById("start_path");
  start_path.onclick = () => {
    mod.instance.exports.startPath();
  };

  const stop_path = document.getElementById("stop_path");
  stop_path.onclick = () => {
    mod.instance.exports.stopPath();
  };
}

window.onload = init;
