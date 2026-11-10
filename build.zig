const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zvim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // A crash trigger (Ctrl-\) for testing crash recovery by hand.
    const options = b.addOptions();
    options.addOption(bool, "test_crash", b.option(bool, "test-crash", "Make Ctrl-\\ crash zvim, to test crash recovery") orelse false);
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zvim");
    run_step.dependOn(&run_cmd.step);

    // zig build dist: small release binaries for each platform, in zig-out/dist.
    const dist_step = b.step("dist", "Build release binaries for Linux and macOS into zig-out/dist");
    const version = @import("build.zig.zon").version;
    // SHA256SUMS, written once every binary is in place.
    const sums = b.addRunArtifact(b.addExecutable(.{
        .name = "sha256sums",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sha256sums.zig"),
            .target = b.graph.host,
        }),
    }));
    sums.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "dist" } });
    sums.has_side_effects = true;
    dist_step.dependOn(&sums.step);
    for ([_][]const u8{ "x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos" }) |triple| {
        const dist_exe = b.addExecutable(.{
            .name = "zvim",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable),
                .optimize = .ReleaseSmall,
            }),
        });
        const dist_options = b.addOptions();
        dist_options.addOption(bool, "test_crash", false);
        dist_options.addOption([]const u8, "version", version);
        dist_exe.root_module.addOptions("build_options", dist_options);
        const install = b.addInstallArtifact(dist_exe, .{
            .dest_dir = .{ .override = .{ .custom = "dist" } },
            .dest_sub_path = b.fmt("zvim-{s}-{s}", .{ version, triple }),
        });
        sums.addArg(install.dest_sub_path.?);
        sums.step.dependOn(&install.step);
    }

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
