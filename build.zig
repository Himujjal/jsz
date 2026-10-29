const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const quickjs = b.dependency("quickjs", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const dusty = b.dependency("dusty", .{ .target = target, .optimize = optimize });
    const webui = b.dependency("zig_webui", .{ .target = target, .optimize = optimize });
    const dusty_mod = dusty.module("dusty");
    // Dusty's default zio import is a stub; the runtime uses the real one.
    dusty_mod.addImport("zio", zio.module("zio"));

    const jsz = b.addModule("jsz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "quickjs", .module = quickjs.module("quickjs") },
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "dusty", .module = dusty_mod },
            .{ .name = "webui", .module = webui.module("webui") },
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

    // `jszc` embeds the runtime it just built, so it can emit standalone
    // executables without a sibling `jsz` or a Zig toolchain at run time.
    // `@embedFile` resolves relative to the importing source, so the runtime is
    // copied next to a generated import instead of embedding a build-relative
    // path from `src/`.
    const runtime_files = b.addWriteFiles();
    const runtime_embed_src = runtime_files.add(
        "runtime_embed.zig",
        "pub const bytes: []const u8 = @embedFile(\"jsz-runtime\");\n",
    );
    _ = runtime_files.addCopyFile(exe.getEmittedBin(), "jsz-runtime");

    const runtime_embed = b.createModule(.{
        .root_source_file = runtime_embed_src,
        .target = target,
        .optimize = optimize,
    });

    const jszc = b.addExecutable(.{
        .name = "jszc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jszc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "jsz", .module = jsz },
                .{ .name = "runtime_embed", .module = runtime_embed },
            },
        }),
    });
    b.installArtifact(jszc);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the jsz CLI");
    run_step.dependOn(&run_cmd.step);

    const test_options = b.addOptions();
    test_options.addOption([]const u8, "fixtures_dir", "tests/fixtures");
    test_options.addOption([]const u8, "path_expected", @embedFile("tests/fixtures/path.expected"));
    // `zig build` installs to zig-out by default; run steps execute with the
    // build root as cwd, so a relative path is stable. A custom --prefix is not
    // carried over (Build has no configure-time install-path accessor in 0.17).
    test_options.addOption([]const u8, "jsz_exe", "zig-out/bin/jsz");
    test_options.addOption([]const u8, "jszc_exe", "zig-out/bin/jszc");

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
    // cli_test spawns the installed binary.
    run_tests.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit and fixture tests");
    test_step.dependOn(&run_tests.step);
}
