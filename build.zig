const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const quickjs = b.dependency("quickjs", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const jsz = b.addModule("jsz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "quickjs", .module = quickjs.module("quickjs") },
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "jsz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "jsz", .module = jsz },
            },
        }),
    });
    exe.root_module.linkLibrary(quickjs.artifact("quickjs-ng"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the jsz CLI");
    run_step.dependOn(&run_cmd.step);

    const test_options = b.addOptions();
    test_options.addOption([]const u8, "fixtures_dir", "tests/fixtures");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/zig/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "jsz", .module = jsz },
        },
    });
    test_mod.addOptions("test_options", test_options);
    test_mod.linkLibrary(quickjs.artifact("quickjs-ng"));

    const tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = true,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.addPassthruArgs();
    const test_step = b.step("test", "Run unit and fixture tests");
    test_step.dependOn(&run_tests.step);
}
