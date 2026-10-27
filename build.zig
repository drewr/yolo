const std = @import("std");

/// Build options compiled into `yolo version`: the commit (with -dirty for
/// uncommitted changes) and its date, empty when built from a plain checkout.
const default_version = "";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The flake passes -Dversion/-Ddate; a bare `zig build` looks the commit up
    // in the checkout it builds from.
    const version = b.option([]const u8, "version", "Commit yolo was built from") orelse
        buildVersion(b, default_version);
    const date = b.option([]const u8, "date", "Date of the commit yolo was built from") orelse "";
    // `zig build run` needs a repository for image/ (docker images, datum
    // pins); the flake's wrapper sets YOLO_ROOT to its read-only source.
    const root_option = b.option([]const u8, "root", "Repository yolo uses when YOLO_ROOT is unset");
    const root = root_option orelse (std.fmt.allocPrint(b.allocator, "{f}", .{b.root}) catch ".");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "date", date);
    options.addOption([]const u8, "root", root);

    const yolo = b.addExecutable(.{
        .name = "yolo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    yolo.root_module.addOptions("options", options);
    b.installArtifact(yolo);

    const run_yolo = b.step("run", "Run yolo");
    const run_yolo_exe = b.addRunArtifact(yolo);
    run_yolo_exe.addPassthruArgs();
    run_yolo.dependOn(&run_yolo_exe.step);

    // Tests: the unit tests (main.zig imports them all).
    const test_step = b.step("test", "Run tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    unit_tests.root_module.addOptions("options", options);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

/// `git describe --always --dirty --abbrev=7 --match=^` in the build root, like
/// versionLine of the Haskell script; empty when there's no git.
fn buildVersion(b: *std.Build, fallback: []const u8) []const u8 {
    const root = std.fmt.allocPrint(b.allocator, "{f}", .{b.root}) catch return fallback;
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "-C", root, "describe", "--always", "--dirty", "--abbrev=7", "--match=^" },
    }) catch return fallback;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return fallback;
    // The module keeps this for the whole build, so it can't point into
    // `result`, which is freed above.
    return b.dupe(std.mem.trim(u8, result.stdout, " \t\r\n"));
}
