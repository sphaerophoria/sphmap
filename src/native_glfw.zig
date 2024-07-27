const std = @import("std");
const App = @import("App.zig");
const Metadata = @import("Metadata.zig");
const image_tile_data = @import("image_tile_data.zig");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "");
    @cDefine("CIMGUI_USE_GLFW", "");
    @cDefine("CIMGUI_USE_OPENGL3", "");
    @cInclude("glad/glad.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl.h");
    @cInclude("stb_image.h");
});

fn glDebugCallback(source: c.GLenum, typ: c.GLenum, id: c.GLuint, severity: c.GLenum, length: c.GLsizei, message: [*c]const c.GLchar, user_param: ?*const anyopaque) callconv(.C) void {
    _ = source;
    _ = typ;
    _ = id;
    _ = severity;
    _ = user_param;
    std.debug.print("{s}", .{message[0..@intCast(length)]});
}

fn errorCallback(err: c_int, desc: [*c]const u8) callconv(.C) void {
    std.debug.print("err: {d} {s}", .{ err, desc });
}

pub export fn compileLinkProgram(vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize) i32 {
    const vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
    const vs_len_i: i32 = @intCast(vs_len);
    c.glShaderSource(vertex_shader, 1, &vs, &vs_len_i);
    c.glCompileShader(vertex_shader);

    const fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
    const fs_len_i: i32 = @intCast(fs_len);
    c.glShaderSource(fragment_shader, 1, &fs, &fs_len_i);
    c.glCompileShader(fragment_shader);

    const program = c.glCreateProgram();
    c.glAttachShader(program, vertex_shader);
    c.glAttachShader(program, fragment_shader);
    c.glLinkProgram(program);
    return @bitCast(program);
}

pub export fn glCreateVertexArray() i32 {
    var ret: u32 = undefined;
    c.glGenVertexArrays(1, &ret);
    return @bitCast(ret);
}

pub export fn glCreateBuffer() i32 {
    var ret: u32 = undefined;
    c.glGenBuffers(1, &ret);
    return @bitCast(ret);
}

pub export fn glDeleteBuffer(id: i32) void {
    const id_c: c_uint = @bitCast(id);
    c.glDeleteBuffers(1, &id_c);
}

pub export fn glVertexAttribPointer(index: i32, size: i32, typ: i32, normalized: bool, stride: i32, offs: i32) void {
    c.glVertexAttribPointer(@intCast(index), @intCast(size), @intCast(typ), @intFromBool(normalized), stride, @ptrFromInt(@as(usize, @intCast(offs))));
}

pub export fn glEnableVertexAttribArray(index: i32) void {
    c.glEnableVertexAttribArray(@bitCast(index));
}

pub export fn glBindBuffer(target: i32, id: i32) void {
    c.glBindBuffer(@intCast(target), @bitCast(id));
}

pub export fn glBufferData(target: i32, ptr: [*]const u8, len: usize, usage: i32) void {
    c.glBufferData(@intCast(target), @intCast(len), ptr, @intCast(usage));
}

pub export fn glBindVertexArray(vao: i32) void {
    c.glBindVertexArray(@bitCast(vao));
}

pub export fn glClearColor(r: f32, g: f32, b: f32, a: f32) void {
    c.glClearColor(r, g, b, a);
}

pub export fn glClear(mask: i32) void {
    c.glClear(@bitCast(mask));
}

pub export fn glUseProgram(program: i32) void {
    c.glUseProgram(@bitCast(program));
}

pub export fn glDrawArrays(mode: i32, first: i32, count: i32) void {
    c.glDrawArrays(@intCast(mode), first, count);
}

pub export fn glDrawElements(mode: i32, count: i32, typ: i32, offs: i32) void {
    c.glDrawElements(@intCast(mode), count, @intCast(typ), @ptrFromInt(@as(usize, @intCast(offs))));
}

pub export fn glGetUniformLoc(program: i32, name: [*]const u8, name_len: usize) i32 {
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..name_len], name);
    buf[name_len] = 0;
    const ret = c.glGetUniformLocation(@bitCast(program), &buf);
    return @bitCast(ret);
}

pub export fn glUniform1f(loc: i32, val: f32) void {
    c.glUniform1f(@bitCast(loc), val);
}

pub export fn glUniform2f(loc: i32, a: f32, b: f32) void {
    c.glUniform2f(@bitCast(loc), a, b);
}

pub export fn glUniform1i(loc: i32, val: i32) void {
    c.glUniform1i(@bitCast(loc), val);
}

pub export fn glActiveTexture(val: i32) void {
    c.glActiveTexture(@bitCast(val));
}

pub export fn glBindTexture(target: i32, val: i32) void {
    c.glBindTexture(@bitCast(target), @bitCast(val));
}

pub export fn clearTags() void {
    Ui.globals.displayed_tags.clearRetainingCapacity();
}

pub export fn pushTag(key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void {
    Ui.globals.displayed_tags.append(.{
        .key = key[0..key_len],
        .val = val[0..val_len],
    }) catch {
        @panic("Failed to push displayed tag");
    };
}

pub export fn setNodeId(id: usize) void {
    Ui.globals.node_id = @intCast(id);
}

const TextureQueue = struct {
    const TextureReq = struct {
        id: usize,
        url: []const u8,

        fn deinit(self: *const TextureReq, alloc: Allocator) void {
            alloc.free(self.url);
        }
    };

    alloc: Allocator,
    q: std.fifo.LinearFifo(TextureReq, .Dynamic),

    fn init(alloc: Allocator) TextureQueue {
        const q = std.fifo.LinearFifo(TextureReq, .Dynamic).init(alloc);
        return .{
            .alloc = alloc,
            .q = q,
        };
    }

    fn deinit(self: *TextureQueue) void {
        while (self.q.readItem()) |item| {
            item.deinit(self.alloc);
        }

        self.q.deinit();
    }

    fn push(self: *TextureQueue, req: TextureReq) !void {
        try self.q.writeItem(req);
    }

    fn pop(self: *TextureQueue) ?TextureReq {
        return self.q.readItem();
    }
};

var texture_queue: TextureQueue = undefined;

fn doFetchTexture(alloc: Allocator, output_dir: []const u8, id: usize, url: []const u8, app: *App) !void {
    const d = std.fs.cwd().openDir(output_dir, .{}) catch @panic("cannot open dir");
    const f = d.openFile(url, .{}) catch @panic("Cannot open file");
    const data = f.readToEndAlloc(alloc, 1_000_000_000) catch @panic("Failed to read file");
    defer alloc.free(data);

    var width: c_int = 0;
    var height: c_int = 0;
    const img = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &width, &height, null, 4);
    defer c.stbi_image_free(img);

    var tex: u32 = undefined;
    c.glCreateTextures(c.GL_TEXTURE_2D, 1, &tex);
    c.glBindTexture(c.GL_TEXTURE_2D, tex);
    c.glTexParameteri(
        c.GL_TEXTURE_2D,
        c.GL_TEXTURE_WRAP_S,
        c.GL_REPEAT,
    );
    c.glTexParameteri(
        c.GL_TEXTURE_2D,
        c.GL_TEXTURE_WRAP_T,
        c.GL_REPEAT,
    );
    c.glTexParameteri(
        c.GL_TEXTURE_2D,
        c.GL_TEXTURE_MIN_FILTER,
        c.GL_LINEAR,
    );
    c.glTexParameteri(
        c.GL_TEXTURE_2D,
        c.GL_TEXTURE_MAG_FILTER,
        c.GL_LINEAR,
    );

    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA,
        width,
        height,
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        img,
    );
    c.glGenerateMipmap(c.GL_TEXTURE_2D);
    try app.registerTexture(id, @bitCast(tex));
}

pub export fn fetchTexture(id: usize, url: [*]const u8, url_len: usize) void {
    const duped_url = texture_queue.alloc.dupe(u8, url[0..url_len]) catch return;

    texture_queue.push(.{ .id = id, .url = duped_url }) catch {
        texture_queue.alloc.free(duped_url);
        return;
    };
}

pub export fn clearMonitoredAttributes() void {
    Ui.globals.monitored_tags.clearRetainingCapacity();
}

pub export fn pushMonitoredAttribute(id: usize, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void {
    Ui.globals.monitored_tags.append(.{
        .id = id,
        .key = key[0..key_len],
        .val = val[0..val_len],
        .cost_multiplier = 1.0,
        .color = .{ 0, 0, 0 },
    }) catch {
        @panic("Failed to push monitored attribute");
    };
}

fn readFileData(alloc: Allocator, p: []const u8) ![]u8 {
    const cwd = std.fs.cwd();
    var f = try cwd.openFile(p, .{});
    defer f.close();
    return try f.readToEndAlloc(alloc, 1 << 30);
}

const GlfwWrapper = struct {
    window: *c.GLFWwindow,
    mouse_down: bool,

    fn init() !GlfwWrapper {
        _ = c.glfwSetErrorCallback(errorCallback);

        if (c.glfwInit() != c.GLFW_TRUE) {
            return error.GlfwInit;
        }
        errdefer c.glfwTerminate();

        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);

        const window = c.glfwCreateWindow(640, 480, "Simple example", null, null) orelse return error.NoWindow;
        errdefer c.glfwDestroyWindow(window);

        c.glfwMakeContextCurrent(window);
        c.glfwSwapInterval(1);

        _ = c.glfwSetScrollCallback(window, glfwScrollCallback);
        c.glfwWindowHint(c.GLFW_SAMPLES, 4);

        return .{
            .window = window,
            .mouse_down = false,
        };
    }

    fn deinit(self: *GlfwWrapper) void {
        c.glfwDestroyWindow(self.window);
        c.glfwTerminate();
    }

    const globals = struct {
        var scroll: f64 = 0;
    };

    fn glfwScrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.C) void {
        _ = window;
        _ = xoffset;
        globals.scroll += yoffset;
    }

    const MousePos = struct {
        x: f32,
        y: f32,
    };

    const InputAction = union(enum) {
        scroll_out: void,
        scroll_in: void,
        mouse_pressed: MousePos,
        mouse_released: void,
        mouse_moved: MousePos,
    };

    fn getInput(self: *GlfwWrapper, alloc: Allocator) ![]InputAction {
        var ret = std.ArrayList(InputAction).init(alloc);
        defer ret.deinit();

        if (globals.scroll > 0.0) {
            try ret.append(InputAction{ .scroll_in = {} });
            globals.scroll = 0.0;
        } else if (globals.scroll < 0.0) {
            try ret.append(InputAction{ .scroll_out = {} });
            globals.scroll = 0.0;
        }

        const glfw_mouse_down = c.glfwGetMouseButton(self.window, c.GLFW_MOUSE_BUTTON_1) != 0;
        if (glfw_mouse_down != self.mouse_down) {
            if (glfw_mouse_down) {
                try ret.append(InputAction{ .mouse_pressed = self.getCursorPos() });
            } else {
                try ret.append(InputAction{ .mouse_released = {} });
            }
        }
        self.mouse_down = glfw_mouse_down;

        return try ret.toOwnedSlice();
    }

    fn getCursorPos(self: *GlfwWrapper) MousePos {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetWindowSize(self.window, &width, &height);
        var mouse_x: f64 = 0.5;
        var mouse_y: f64 = 0.5;
        c.glfwGetCursorPos(self.window, &mouse_x, &mouse_y);
        mouse_x /= @floatFromInt(width);
        mouse_y /= @floatFromInt(height);

        return .{
            .x = @floatCast(mouse_x),
            .y = @floatCast(mouse_y),
        };
    }
};

fn enableGlDebug() void {
    c.glDebugMessageCallback(glDebugCallback, null);
    c.glEnable(c.GL_DEBUG_OUTPUT_SYNCHRONOUS);
}

fn setGlParams() void {
    // App draws all streets with one drawElements
    c.glEnable(c.GL_PRIMITIVE_RESTART);
    c.glPrimitiveRestartIndex(0xffffffff);

    // App sets point size in shaders
    c.glEnable(c.GL_PROGRAM_POINT_SIZE);

    // We want our lines to be pretty
    c.glEnable(c.GL_MULTISAMPLE);
    c.glEnable(c.GL_LINE_SMOOTH);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glLineWidth(2.0);
}

const WayTag = struct {
    key: []const u8,
    val: []const u8,
};

const MonitoredWayTag = struct {
    id: usize,
    key: []const u8,
    val: []const u8,
    cost_multiplier: f32,
    color: [3]f32,
};

const Ui = struct {
    const overlay_width = 300;
    io: *c.ImGuiIO,
    debug_path_planning: bool = false,
    debug_point_neighbors: bool = false,
    debug_way_finding: bool = false,
    color_picker_id: ?usize = null,
    turning_cost: f32 = 0,

    const globals = struct {
        var displayed_tags: std.ArrayList(WayTag) = undefined;
        var monitored_tags: std.ArrayList(MonitoredWayTag) = undefined;
        var node_id: u32 = 0;
    };

    fn init(alloc: Allocator, window: *c.GLFWwindow) !Ui {
        _ = c.igCreateContext(null);
        errdefer c.igDestroyContext(null);

        if (!c.ImGui_ImplGlfw_InitForOpenGL(window, true)) {
            return error.InitImGuiGlfw;
        }
        errdefer c.ImGui_ImplGlfw_Shutdown();

        if (!c.ImGui_ImplOpenGL3_Init("#version 130")) {
            return error.InitImGuiOgl;
        }
        errdefer c.ImGui_ImplOpenGL3_Shutdown();

        const io = c.igGetIO();
        io.*.IniFilename = null;
        io.*.LogFilename = null;

        globals.displayed_tags = std.ArrayList(WayTag).init(alloc);
        globals.monitored_tags = std.ArrayList(MonitoredWayTag).init(alloc);

        return .{
            .io = io,
        };
    }

    fn deinit(self: *Ui) void {
        _ = self;
        globals.displayed_tags.deinit();
        globals.monitored_tags.deinit();
        c.ImGui_ImplOpenGL3_Shutdown();
        c.ImGui_ImplGlfw_Shutdown();
        c.igDestroyContext(null);
    }

    fn startFrame() void {
        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();
    }

    fn setOverlayDims(self: *Ui, width: c_int, height: c_int) void {
        _ = self;
        c.igSetNextWindowSize(.{
            .x = overlay_width,
            .y = 0,
        }, 0);
        c.igSetNextWindowPos(
            .{
                .x = @floatFromInt(width - 20),
                .y = @floatFromInt(height - 10),
            },
            0,
            .{
                .x = 1.0,
                .y = 1.0,
            },
        );
    }

    const RequestedActions = struct {
        start_path_planning: bool = false,
        end_path_planning: bool = false,
        debug_path_planning: ?bool = null,
        debug_point_neighbors: ?bool = null,
        debug_way_finding: ?bool = null,
        add_monitored_attribute: ?struct { k: [*]const u8, v: [*]const u8 } = null,
        remove_monitored_attribute: ?usize = null,
        update_cost_multiplier: ?struct { id: usize, value: f32 } = null,
        consumed_mouse_input: bool = false,
        turning_cost: ?f32 = null,
        update_color: ?struct { id: usize, color: [3]f32 } = null,
    };

    fn drawOverlay(self: *Ui) RequestedActions {
        var ret = RequestedActions{};

        _ = c.igBegin("Overlay", null, c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoTitleBar);

        if (c.igBeginTable("tags", 2, c.ImGuiTableFlags_SizingStretchProp, .{ .x = overlay_width, .y = 0 }, 0)) {
            for (globals.displayed_tags.items, 0..) |tag, i| {
                c.igPushID_Int(@intCast(i));
                c.igTableNextRow(0, 0);
                _ = c.igTableNextColumn();
                c.igText("%.*s: %.*s", tag.key.len, tag.key.ptr, tag.val.len, tag.val.ptr);
                _ = c.igTableNextColumn();
                if (c.igButton("add", .{ .x = 0, .y = 0 })) {
                    ret.add_monitored_attribute = .{
                        .k = tag.key.ptr,
                        .v = tag.val.ptr,
                    };
                }
                c.igPopID();
            }
            c.igEndTable();
        }

        c.igText("Closest node: %lu", globals.node_id);

        if (c.igCheckbox("Debug way finding", &self.debug_way_finding)) {
            ret.debug_way_finding = self.debug_way_finding;
        }

        if (c.igCheckbox("Debug point neighbors", &self.debug_point_neighbors)) {
            ret.debug_point_neighbors = self.debug_point_neighbors;
        }

        if (c.igCheckbox("Debug path planning", &self.debug_path_planning)) {
            ret.debug_path_planning = self.debug_path_planning;
        }

        if (c.igBeginTable("tags", 4, 0, .{ .x = overlay_width, .y = 0 }, 0)) {
            c.igTableSetupColumn("", c.ImGuiTableColumnFlags_WidthFixed, overlay_width - 240, 0);
            c.igTableSetupColumn("", c.ImGuiTableColumnFlags_WidthFixed, 100.0, 0);
            c.igTableSetupColumn("", c.ImGuiTableColumnFlags_WidthFixed, 50, 0);
            c.igTableSetupColumn("", c.ImGuiTableColumnFlags_WidthFixed, 50, 0);
            for (globals.monitored_tags.items) |*tag| {
                c.igPushID_Int(@intCast(tag.id));
                c.igTableNextRow(0, 0);

                _ = c.igTableNextColumn();
                c.igText("%.*s: %.*s", tag.key.len, tag.key.ptr, tag.val.len, tag.val.ptr);

                _ = c.igTableNextColumn();
                if (c.igInputFloat("cost", &tag.cost_multiplier, 0.0, 0.0, "%.3f", 0)) {
                    ret.update_cost_multiplier = .{
                        .id = tag.id,
                        .value = tag.cost_multiplier,
                    };
                }

                _ = c.igTableNextColumn();
                if (c.igButton("color", .{ .x = 50, .y = 0 })) {
                    self.color_picker_id = tag.id;
                }

                _ = c.igTableNextColumn();
                if (c.igButton("remove", .{ .x = 50, .y = 0 })) {
                    ret.remove_monitored_attribute = tag.id;
                }

                c.igPopID();
            }
            c.igEndTable();
        }

        if (c.igInputFloat("Turning Cost", &self.turning_cost, 0.0, 0.0, "%.3f", 0)) {
            ret.turning_cost = self.turning_cost;
        }

        ret.start_path_planning = c.igButton("Start path planning", .{ .x = 0, .y = 0 });
        ret.end_path_planning = c.igButton("End path planning", .{ .x = 0, .y = 0 });

        c.igEnd();

        if (self.color_picker_id) |id| {
            var window_open = true;
            _ = c.igBegin("Select color", &window_open, 0);
            if (c.igColorPicker3("Select color", &globals.monitored_tags.items[id].color, 0)) {
                ret.update_color = .{
                    .id = id,
                    .color = globals.monitored_tags.items[id].color,
                };
            }
            c.igEnd();

            if (!window_open) {
                self.color_picker_id = null;
            }
        }

        ret.consumed_mouse_input = self.io.*.WantCaptureMouse;

        return ret;
    }

    fn render(self: *Ui, width: c_int, height: c_int) RequestedActions {
        startFrame();
        self.setOverlayDims(width, height);

        const ret = self.drawOverlay();
        c.igRender();
        c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
        return ret;
    }
};

fn handleUiActions(app: *App, actions: Ui.RequestedActions) !void {
    if (actions.start_path_planning) {
        app.startPath();
    }

    if (actions.end_path_planning) {
        app.stopPath();
    }

    if (actions.debug_path_planning) |value| {
        app.debug_path_finding = value;
    }

    if (actions.debug_point_neighbors) |value| {
        app.debug_point_neighbors = value;
    }

    if (actions.debug_way_finding) |value| {
        app.debug_way_finding = value;
    }

    if (actions.add_monitored_attribute) |value| {
        try app.monitorWayAttribute(value.k, value.v);
    }

    if (actions.remove_monitored_attribute) |value| {
        try app.removeMonitoredAttribute(value);
    }

    if (actions.update_cost_multiplier) |value| {
        try app.monitored_attributes.cost.update(value.id, value.value);
    }

    if (actions.update_color) |value| {
        app.monitored_attributes.rendering.update(
            value.id,
            value.color[0],
            value.color[1],
            value.color[2],
        );
    }

    if (actions.turning_cost) |cost| {
        app.turning_cost = cost;
    }
}

fn handleGlfwActions(alloc: Allocator, glfw: *GlfwWrapper, app: *App) !void {
    const glfw_actions = try glfw.getInput(alloc);
    defer alloc.free(glfw_actions);

    for (glfw_actions) |action| {
        switch (action) {
            .scroll_out => {
                app.zoomOut();
            },
            .scroll_in => {
                app.zoomIn();
            },
            .mouse_pressed => |pos| {
                app.onMouseDown(pos.x, pos.y);
            },
            .mouse_released => {
                app.onMouseUp();
            },
            .mouse_moved => |pos| {
                // NOTE: This is called every frame anyways so do nothing
                _ = pos;
            },
        }
    }
}

const MapData = struct {
    bin: []u8,
    metadata_buf: []const u8,
    image_tile_buf: []const u8,
    metadata: std.json.Parsed(Metadata),
    image_tiles: std.json.Parsed(image_tile_data.ImageTileData),

    fn init(alloc: Allocator, output_path: []const u8) !MapData {
        const map_data_path = try std.fs.path.join(alloc, &.{ output_path, "map_data.bin" });
        defer alloc.free(map_data_path);

        const map_metadata_path = try std.fs.path.join(alloc, &.{ output_path, "map_data.json" });
        defer alloc.free(map_metadata_path);

        const image_tile_path = try std.fs.path.join(alloc, &.{ output_path, "image_tile_data.json" });
        defer alloc.free(image_tile_path);

        const bin = try readFileData(alloc, map_data_path);
        errdefer alloc.free(bin);

        const metadata_buf = try readFileData(alloc, map_metadata_path);
        errdefer alloc.free(metadata_buf);

        const metadata = try std.json.parseFromSlice(Metadata, alloc, metadata_buf, .{});
        errdefer metadata.deinit();

        const image_tiles_buf = try readFileData(alloc, image_tile_path);
        errdefer alloc.free(image_tiles_buf);

        const image_tiles = try std.json.parseFromSlice(image_tile_data.ImageTileData, alloc, image_tiles_buf, .{});
        errdefer image_tiles.deinit();

        return .{
            .bin = bin,
            .metadata_buf = metadata_buf,
            .image_tile_buf = image_tiles_buf,
            .metadata = metadata,
            .image_tiles = image_tiles,
        };
    }

    fn deinit(self: *MapData, alloc: Allocator) void {
        alloc.free(self.bin);
        alloc.free(self.metadata_buf);
        alloc.free(self.image_tile_buf);
        self.metadata.deinit();
        self.image_tiles.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var map_data = try MapData.init(alloc, args[1]);
    defer map_data.deinit(alloc);

    var glfw = try GlfwWrapper.init();
    defer glfw.deinit();

    _ = c.gladLoadGL();
    enableGlDebug();
    setGlParams();

    var ui = try Ui.init(alloc, glfw.window);
    defer ui.deinit();

    texture_queue = TextureQueue.init(alloc);
    defer texture_queue.deinit();

    // FIXME: Add image tiles
    const app = try App.init(alloc, 1.0, map_data.bin, &map_data.metadata.value, map_data.image_tiles.value);
    defer app.deinit();

    while (texture_queue.pop()) |item| {
        defer item.deinit(alloc);
        try doFetchTexture(alloc, args[1], item.id, item.url, app);
    }

    var width: c_int = 0;
    var height: c_int = 0;
    while (c.glfwWindowShouldClose(glfw.window) == 0) {
        c.glfwPollEvents();

        c.glfwGetWindowSize(glfw.window, &width, &height);
        c.glViewport(0, 0, width, height);
        app.setAspect(@as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)));

        const mouse_pos = glfw.getCursorPos();
        // NOTE: This also renders
        try app.onMouseMove(mouse_pos.x, mouse_pos.y);

        const ui_actions = ui.render(width, height);

        try handleUiActions(app, ui_actions);

        if (!ui_actions.consumed_mouse_input) {
            try handleGlfwActions(alloc, &glfw, app);
        }

        c.glfwSwapBuffers(glfw.window);
    }
}
