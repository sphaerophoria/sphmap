var global_counter: i32 = 0;

fn newId() i32 {
    global_counter += 1;
    return global_counter;
}

pub export fn compileLinkProgram(vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) i32 {
    _ = vs;
    _ = vs_len;
    _ = fs;
    _ = fs_len;
    return newId();
}

pub export fn glCreateVertexArray() i32 {
    return newId();
}

pub export fn glCreateBuffer() i32 {
    return newId();
}

pub export fn glVertexAttribPointer(index: i32, size: i32, typ: i32, normalized: bool, stride: i32, offs: i32) void {
    _ = index;
    _ = size;
    _ = typ;
    _ = normalized;
    _ = stride;
    _ = offs;
}

pub export fn glEnableVertexAttribArray(index: i32) void {
    _ = index;
}

pub export fn glBindBuffer(target: i32, id: i32) void {
    _ = target;
    _ = id;
}

pub export fn glBufferData(target: i32, ptr: [*]const u8, len: usize, usage: i32) void {
    _ = target;
    _ = ptr;
    _ = len;
    _ = usage;
}

pub export fn glBindVertexArray(vao: i32) void {
    _ = vao;
}

pub export fn glClearColor(r: f32, g: f32, b: f32, a: f32) void {
    _ = r;
    _ = g;
    _ = b;
    _ = a;
}

pub export fn glClear(mask: i32) void {
    _ = mask;
}

pub export fn glUseProgram(program: i32) void {
    _ = program;
}

pub export fn glDrawArrays(mode: i32, first: i32, last: i32) void {
    _ = mode;
    _ = first;
    _ = last;
}

pub export fn glDrawElements(mode: i32, count: i32, typ: i32, offs: i32) void {
    _ = mode;
    _ = count;
    _ = typ;
    _ = offs;
}

pub export fn glGetUniformLoc(program: i32, name: [*]const u8, name_len: usize) i32 {
    _ = program;
    _ = name;
    _ = name_len;
    return newId();
}

pub export fn glUniform1f(loc: i32, val: f32) void {
    _ = loc;
    _ = val;
}

pub export fn clearTags() void {}

pub export fn pushTag(key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void {
    _ = key;
    _ = key_len;
    _ = val;
    _ = val_len;
}

pub export fn setNodeId(id: usize) void {
    _ = id;
}
