const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const media = b.dependency("media", .{ .target = target, .optimize = optimize });

    const mp4 = b.addModule("mp4", .{
        .root_source_file = b.path("src/mp4/mp4.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "media", .module = media.module("media") },
        },
    });

    const ivf = b.addModule("ivf", .{
        .root_source_file = b.path("src/ivf/ivf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "media", .module = media.module("media") },
        },
    });

    const mod = b.addModule("media-formats", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mp4", .module = mp4 },
            .{ .name = "ivf", .module = ivf },
        },
    });

    {
        const mp4_tests = b.addTest(.{ .root_module = mp4 });
        const run_mp4_tests = b.addRunArtifact(mp4_tests);

        const ivf_tests = b.addTest(.{ .root_module = ivf });
        const run_ivf_tests = b.addRunArtifact(ivf_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mp4_tests.step);
        test_step.dependOn(&run_ivf_tests.step);
    }

    {
        const examples = [_]struct {
            file: []const u8,
            name: []const u8,
        }{
            .{ .file = "examples/mp4/01-mp4-to-annexb.zig", .name = "mp4_to_annexb" },
        };

        for (examples) |ex| {
            const exe = b.addExecutable(.{
                .name = ex.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(ex.file),
                    .target = target,
                    .optimize = .ReleaseSafe,
                    .imports = &.{
                        .{ .name = "formats", .module = mod },
                        .{ .name = "media", .module = media.module("media") },
                    },
                }),
            });

            const run_cmd = b.addRunArtifact(exe);
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }

            const run_step = b.step(ex.name, ex.file);
            run_step.dependOn(&run_cmd.step);
        }
    }
}
