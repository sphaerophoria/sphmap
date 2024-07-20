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
};

pub fn build(b: *std.Build) void {
    var builder = Builder.init(b);
    builder.generateMapData();
    builder.buildApp();
}
