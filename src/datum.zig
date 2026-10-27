//! The datum backend: sessions on Datum Compute, reached by SSH over iroh.
//! Stub: bodies die "not ported yet"; real implementation in WP1.

const std = @import("std");
const util = @import("util.zig");
const json = @import("json.zig");
const Ctx = util.Ctx;

pub const Datum = struct {
    images: []const u8,
    gp_images: []const u8,
    user: []const u8,
    forward_agent: bool,
    pull_secret: []const u8,
    location: []const u8,
    network: []const u8,
    instance_type: []const u8,
    cls: []const u8,
    relay: []const u8,
    home_secret: []const u8,
    providers_secret: []const u8,
    jfs_opts: []const u8,
};

pub fn config(ctx: Ctx, root: []const u8) Datum {
    return Datum{
        .images = std.fmt.allocPrint(ctx.arena, "{s}/image/images", .{root}) catch "",
        .gp_images = std.fmt.allocPrint(ctx.arena, "{s}/image/images-general-purpose", .{root}) catch "",
        .user = "drewr",
        .forward_agent = true,
        .pull_secret = "ghcr-drewr",
        .location = "us-east-1",
        .network = "default",
        .instance_type = "datumcloud/d1-standard-2",
        .cls = "unikernel",
        .relay = "https://use1-1.relay.n0.iroh.link./",
        .home_secret = "agent-home",
        .providers_secret = "agent-providers",
        .jfs_opts = "",
    };
}

pub fn datumNew(ctx: Ctx, d: Datum, name: []const u8, harness: []const u8, opts: []const []const u8) u8 {
    _ = ctx; _ = d; _ = name; _ = harness; _ = opts;
    util.die("datum new not ported yet");
}

pub fn datumAttach(ctx: Ctx, d: Datum, name: []const u8, args: []const []const u8) u8 {
    _ = ctx; _ = d; _ = name; _ = args;
    util.die("datum attach not ported yet");
}

pub fn datumLs(ctx: Ctx, d: Datum, full: bool) u8 {
    _ = ctx; _ = d; _ = full;
    util.die("datum ls not ported yet");
}

pub fn datumLogs(ctx: Ctx, d: Datum, name: []const u8, args: []const []const u8) u8 {
    _ = ctx; _ = d; _ = name; _ = args;
    util.die("datum logs not ported yet");
}

pub fn datumRm(ctx: Ctx, d: Datum, name: []const u8) u8 {
    _ = ctx; _ = d; _ = name;
    util.die("datum rm not ported yet");
}

pub fn datumSync(ctx: Ctx) ?[]const json.Value {
    _ = ctx;
    return null;
}

pub fn datumTable(ctx: Ctx, full: bool, items: []const json.Value) void {
    _ = ctx; _ = full; _ = items;
}

pub fn adopt(ctx: Ctx, check_keys: bool, name: []const u8) bool {
    _ = ctx; _ = check_keys; _ = name;
    util.die("datum adopt not ported yet");
}

pub fn buildDatum(ctx: Ctx, root: []const u8, cls: []const u8, hs: []const []const u8) u8 {
    _ = ctx; _ = root; _ = cls; _ = hs;
    util.die("datum build not ported yet");
}
