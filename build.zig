const std = @import("std");

const Builder = struct {
    b: *std.Build,
    opt: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    osm_path: std.Build.LazyPath,
    wasm_target: std.Build.ResolvedTarget,

    fn init(b: *std.Build) Builder {
        const osm_path = b.option([]const u8, "osm_data", "Where to load OSM data from ") orelse {
            std.log.err("Cannot build without osm data, please use -Dosm_data=<...>", .{});
            std.process.exit(1);
        };

        return .{
            .b = b,
            .opt = b.standardOptimizeOption(.{}),
            .target = b.standardTargetOptions(.{}),
            .wasm_target = b.resolveTargetQuery(std.zig.CrossTarget.parse(
                .{ .arch_os_abi = "wasm32-freestanding" },
            ) catch unreachable),
            .osm_path = b.path(osm_path),
        };
    }

    fn generateMapData(self: *Builder) void {
        const exe = self.b.addExecutable(.{
            .name = "preprocess",
            .root_source_file = self.b.path("src/preprocess_data.zig"),
            .target = self.target,
            .optimize = .ReleaseFast,
        });
        exe.linkSystemLibrary("expat");
        exe.linkLibC();

        const run = self.b.addRunArtifact(exe);
        run.addFileArg(self.osm_path);
        const points_data = run.addOutputFileArg("map_data.bin");
        const metadata = run.addOutputFileArg("metadata.json");

        const install_bin = self.b.addInstallFile(points_data, "bin/map_data.bin");
        self.b.getInstallStep().dependOn(&install_bin.step);

        const install_json = self.b.addInstallFile(metadata, "bin/map_data.json");
        self.b.getInstallStep().dependOn(&install_json.step);
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
