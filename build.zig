const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ALPM module (from https://github.com/zig-pkgs/alpm-zig)
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/lib/alpm/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_mod = translate_c.createModule();

    const alpm_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/alpm/alpm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });

    // CLI frontend
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "alpm", .module = alpm_mod },
        },
    });
    exe_mod.linkSystemLibrary("alpm", .{});

    const exe = b.addExecutable(.{
        .name = "parchprobe",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run parchprobe");
    run_step.dependOn(&run_cmd.step);

    // Test module — includes lib/ imports.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "alpm", .module = alpm_mod },
        },
    });
    test_mod.linkSystemLibrary("alpm", .{});
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
