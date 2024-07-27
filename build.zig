const std = @import("std");

const Builder = struct {
    b: *std.Build,
    opt: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    wasm_target: std.Build.ResolvedTarget,
    check_step: *std.Build.Step,
    wasm_step: *std.Build.Step,

    fn init(b: *std.Build) Builder {
        const check_step = b.step("check", "check");
        const wasm_step = b.step("wasm", "wasm");
        return .{
            .b = b,
            .opt = b.standardOptimizeOption(.{}),
            .target = b.standardTargetOptions(.{}),
            .wasm_target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
                .{ .arch_os_abi = "wasm32-freestanding" },
            ) catch unreachable),
            .check_step = check_step,
            .wasm_step = wasm_step,
        };
    }

    fn installAndCheck(self: *Builder, elem: *std.Build.Step.Compile) *std.Build.Step.InstallArtifact {
        const duped = self.b.allocator.create(std.Build.Step.Compile) catch unreachable;
        duped.* = elem.*;
        self.b.installArtifact(elem);
        const install_artifact = self.b.addInstallArtifact(elem, .{});
        self.b.getInstallStep().dependOn(&install_artifact.step);
        self.check_step.dependOn(&duped.step);
        return install_artifact;
    }

    fn generateMapData(self: *Builder) void {
        const exe = self.b.addExecutable(.{
            .name = "make_site",
            .root_source_file = self.b.path("src/make_site.zig"),
            .target = self.target,
            .optimize = self.opt,
        });
        exe.linkSystemLibrary("expat");
        exe.linkLibC();
        _ = self.installAndCheck(exe);
    }

    fn buildApp(self: *Builder) void {
        const wasm = self.b.addExecutable(.{
            .name = "index",
            .root_source_file = self.b.path("src/index.zig"),
            .target = self.wasm_target,
            .optimize = self.opt,
        });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        const installed = self.installAndCheck(wasm);
        self.wasm_step.dependOn(&installed.step);
    }

    fn buildLinterApp(self: *Builder) void {
        const exe = self.b.addExecutable(.{
            .name = "sphmap_nogui",
            .root_source_file = self.b.path("src/native_nogui.zig"),
            .target = self.target,
            .optimize = self.opt,
        });
        _ = self.installAndCheck(exe);
    }

    fn buildLocalApp(self: *Builder) void {
        const exe = self.b.addExecutable(.{
            .name = "sphmap",
            .root_source_file = self.b.path("src/native_glfw.zig"),
            .target = self.target,
            .optimize = self.opt,
        });
        exe.addCSourceFiles(.{
            .files = &.{
                "cimgui/cimgui.cpp",
                "cimgui/imgui/imgui.cpp",
                "cimgui/imgui/imgui_draw.cpp",
                "cimgui/imgui/imgui_demo.cpp",
                "cimgui/imgui/imgui_tables.cpp",
                "cimgui/imgui/imgui_widgets.cpp",
                "cimgui/imgui/backends/imgui_impl_glfw.cpp",
                "cimgui/imgui/backends/imgui_impl_opengl3.cpp",
                "glad/src/glad.c",
                "src/stb_image.c",
            },
        });
        exe.addIncludePath(self.b.path("cimgui"));
        exe.addIncludePath(self.b.path("cimgui/generator/output"));
        exe.addIncludePath(self.b.path("cimgui/imgui/backends"));
        exe.addIncludePath(self.b.path("cimgui/imgui"));
        exe.addIncludePath(self.b.path("stb_image"));
        exe.addIncludePath(self.b.path("glad/include"));
        exe.defineCMacro("IMGUI_IMPL_API", "extern \"C\"");
        exe.linkSystemLibrary("glfw");
        exe.linkLibC();
        exe.linkLibCpp();
        _ = self.installAndCheck(exe);
    }

    fn buildPathPlannerBenchmark(self: *Builder) void {
        const exe = self.b.addExecutable(.{
            .name = "pp_benchmark",
            .root_source_file = self.b.path("src/pp_benchmark.zig"),
            .target = self.target,
            .optimize = self.opt,
        });
        _ = self.installAndCheck(exe);
    }
};

pub fn build(b: *std.Build) void {
    var builder = Builder.init(b);
    builder.generateMapData();
    builder.buildApp();
    builder.buildPathPlannerBenchmark();
    builder.buildLinterApp();
    builder.buildLocalApp();
}
