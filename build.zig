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
        exe.linkSystemLibrary("sqlite3");
        exe.linkSystemLibrary("expat");
        exe.linkLibC();
        _ = self.installAndCheck(exe);
    }

    fn makeGuiLib(self: *Builder) *std.Build.Step.Compile {
        return self.b.addStaticLibrary(.{
            .name = "gui",
            .root_source_file = self.b.path("src/gui.zig"),
            .target = self.target,
            .optimize = self.opt,
        });
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

    fn buildLocalApp(self: *Builder, libgui: *std.Build.Step.Compile) void {
        const exe = self.b.addExecutable(.{
            .name = "sphmap",
            .root_source_file = self.b.path("src/local.zig"),
            .target = self.target,
            .optimize = self.opt,
        });
        exe.linkLibrary(libgui);
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
    const gui_lib = builder.makeGuiLib();
    builder.generateMapData();
    builder.buildApp();
    builder.buildLocalApp(gui_lib);
    builder.buildPathPlannerBenchmark();
}
