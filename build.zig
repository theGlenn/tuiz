const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public module. It does not set `link_libc`: only `terminal.zig`
    // needs libc (isatty, tcgetattr, the TIOCGWINSZ ioctl), and a consumer
    // that renders into a buffer without touching the tty should not be
    // forced to link it. Consumers that use `terminal` link libc themselves.
    const tuiz = b.addModule("tuiz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests reference every declaration, `terminal` included, so they
    // link libc.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run the toolkit unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // PTY checks run in subprocesses so raw mode and signal handlers
    // cannot leak into the test runner. Python is only needed for this step.
    const terminal_probe = b.addExecutable(.{
        .name = "terminal-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/terminal_probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "tuiz", .module = tuiz }},
        }),
    });
    const terminal_tests = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tests/terminal_test.py") });
    terminal_tests.addArtifactArg(terminal_probe);
    b.step("test-terminal", "Test EOF, raw mode, resize, and restoration with PTYs")
        .dependOn(&terminal_tests.step);

    const example = b.addExecutable(.{
        .name = "tuiz-dashboard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dashboard.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "tuiz", .module = tuiz }},
        }),
    });
    const example_step = b.step("example", "Build the examples");
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);

    const example_tests = b.addTest(.{ .root_module = example.root_module });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    const demo = b.addExecutable(.{
        .name = "tuiz-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "tuiz", .module = tuiz }},
        }),
    });
    example_step.dependOn(&b.addInstallArtifact(demo, .{}).step);
    const demo_tests = b.addTest(.{ .root_module = demo.root_module });
    test_step.dependOn(&b.addRunArtifact(demo_tests).step);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |args| run_demo.addArgs(args);
    const demo_step = b.step("demo", "Run the ARGO-7 showcase (space pauses, q quits)");
    demo_step.dependOn(&run_demo.step);

    const run_example = b.addRunArtifact(example);
    if (b.args) |args| run_example.addArgs(args);
    const run_step = b.step("run", "Run the dashboard example (q quits)");
    run_step.dependOn(&run_example.step);
}
