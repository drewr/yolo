//! The docker backend: long-lived local containers (podman, colima or docker).
//! Stub: bodies die "not ported yet"; real implementation in WP2.

const std = @import("std");
const util = @import("util.zig");
const Ctx = util.Ctx;

pub const Docker = struct {
    rt: []const u8,
    vm: bool,
    home: []const u8,
    providers_env: []const u8,
    forward_agent: bool,
    user: []const u8,
};

pub fn config(ctx: Ctx) Docker {
    _ = ctx;
    return Docker{
        .rt = "docker",
        .vm = false,
        .home = "~/.local/share/yolo/home",
        .providers_env = "~/.config/yolo/providers.env",
        .forward_agent = true,
        .user = "drewr",
    };
}

pub fn dockerNew(ctx: Ctx, d: Docker, name: []const u8, harness: []const u8, opts: []const []const u8) u8 {
    _ = ctx; _ = d; _ = name; _ = harness; _ = opts;
    util.die("docker new not ported yet");
}

pub fn dockerAttach(ctx: Ctx, d: Docker, name: []const u8, args: []const []const u8) u8 {
    _ = ctx; _ = d; _ = name; _ = args;
    util.die("docker attach not ported yet");
}

pub fn dockerLs(ctx: Ctx) u8 {
    _ = ctx;
    util.die("docker ls not ported yet");
}

pub fn dockerLogs(ctx: Ctx, d: Docker, name: []const u8, args: []const []const u8) u8 {
    _ = ctx; _ = d; _ = name; _ = args;
    util.die("docker logs not ported yet");
}

pub fn dockerRm(ctx: Ctx, d: Docker, name: []const u8) u8 {
    _ = ctx; _ = d; _ = name;
    util.die("docker rm not ported yet");
}

pub fn dockerBuild(ctx: Ctx, root: []const u8, d: Docker, harness: []const u8) u8 {
    _ = ctx; _ = root; _ = d; _ = harness;
    util.die("docker build not ported yet");
}
