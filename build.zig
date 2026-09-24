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
    const example_step = b.step("example", "Build the dashboard example");
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);

    const example_tests = b.addTest(.{ .root_module = example.root_module });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    const run_example = b.addRunArtifact(example);
    if (b.args) |args| run_example.addArgs(args);
    const run_step = b.step("run", "Run the dashboard example (q quits)");
    run_step.dependOn(&run_example.step);
}
