pub extern fn compileLinkProgram(vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) i32;
pub extern fn glCreateVertexArray() i32;
pub extern fn glCreateBuffer() i32;
pub extern fn glVertexAttribPointer(index: i32, size: i32, type: i32, normalized: bool, stride: i32, offs: i32) void;
pub extern fn glEnableVertexAttribArray(index: i32) void;
pub extern fn glBindBuffer(target: i32, id: i32) void;
pub extern fn glBufferData(target: i32, ptr: [*]const u8, len: usize, usage: i32) void;
pub extern fn glBindVertexArray(vao: i32) void;
pub extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
pub extern fn glClear(mask: i32) void;
pub extern fn glUseProgram(program: i32) void;
pub extern fn glDrawArrays(mode: i32, first: i32, last: i32) void;
pub extern fn glDrawElements(mode: i32, count: i32, type: i32, offs: i32) void;
pub extern fn glGetUniformLoc(program: i32, name: [*]const u8, name_len: usize) i32;
pub extern fn glUniform1f(loc: i32, val: f32) void;

pub extern fn clearTags() void;
pub extern fn pushTag(key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void;
pub extern fn setNodeId(id: usize) void;
