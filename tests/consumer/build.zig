const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tuiz = b.dependency("tuiz", .{ .target = target, .optimize = optimize });
    const consumer = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{.{ .name = "tuiz", .module = tuiz.module("tuiz") }},
        }),
    });
    b.default_step.dependOn(&b.addRunArtifact(consumer).step);
}
