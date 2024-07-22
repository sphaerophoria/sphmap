const std = @import("std");

const Builder = struct {
    b: *std.Build,
    opt: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    wasm_target: std.Build.ResolvedTarget,

    fn init(b: *std.Build) Builder {
        return .{
            .b = b,
            .opt = b.standardOptimizeOption(.{}),
            .target = b.standardTargetOptions(.{}),
            .wasm_target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
                .{ .arch_os_abi = "wasm32-freestanding" },
            ) catch unreachable),
        };
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
        self.b.installArtifact(exe);
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

        self.b.installArtifact(wasm);
    }

    fn buildLocalApp(self: *Builder, libgui: *std.Build.Step.Compile) void {
        const exe = self.b.addExecutable(.{
            .name = "sphmap",
            .root_source_file = self.b.path("src/local.zig"),
            .target = self.target,
            .optimize = self.opt,
        });
        exe.linkLibrary(libgui);
        self.b.installArtifact(exe);
    }
};

pub fn build(b: *std.Build) void {
    var builder = Builder.init(b);
    const gui_lib = builder.makeGuiLib();
    builder.generateMapData();
    builder.buildApp();
    builder.buildLocalApp(gui_lib);
}
