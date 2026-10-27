//! The EC2 boxes whose NixOS configs live in this repo: the image build box
//! (infra/buildbox/ec2) and the JuiceFS metadata host for the shared home
//! (infra/meta/ec2).
//!
//! Pure pieces (subnet64) are here from WP1 because the golden vectors pin
//! them; the commands arrive with WP3.

const std = @import("std");
const util = @import("util.zig");
const Ctx = util.Ctx;
const mem = std.mem;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// The i-th /64 of an Amazon /56 block (its fourth group's low byte).
pub const SubnetError = error{BadBlock} || mem.Allocator.Error;

pub fn subnet64(allocator: mem.Allocator, block: []const u8, i: u32) SubnetError![]const u8 {
    const addr = if (mem.indexOfScalar(u8, block, '/')) |s| block[0..s] else block;
    var left: []const u8 = addr;
    var right: []const u8 = "";
    if (mem.indexOf(u8, addr, "::")) |at| {
        left = addr[0..at];
        right = addr[at + 2 ..];
    }
    var groups: std.ArrayList(u16) = .empty;
    if (left.len != 0) {
        var it = mem.splitScalar(u8, left, ':');
        while (it.next()) |g| try groups.append(allocator, try hexGroup(allocator, block, g));
    }
    var right_groups: std.ArrayList(u16) = .empty;
    if (right.len != 0) {
        var it = mem.splitScalar(u8, right, ':');
        while (it.next()) |g| try right_groups.append(allocator, try hexGroup(allocator, block, g));
    }
    const fill = 8 -| (groups.items.len + right_groups.items.len);
    var full: std.ArrayList(u16) = .empty;
    try full.appendSlice(allocator, groups.items);
    try full.appendNTimes(allocator, 0, fill);
    try full.appendSlice(allocator, right_groups.items);
    if (full.items.len != 8 or i > 255) return error.BadBlock;
    const g3: u16 = (full.items[3] & 0xff00) | @as(u16, @intCast(i));
    return std.fmt.allocPrint(allocator, "{x}:{x}:{x}:{x}::/64", .{
        full.items[0], full.items[1], full.items[2], g3,
    });
}

fn hexGroup(allocator: mem.Allocator, block: []const u8, g: []const u8) SubnetError!u16 {
    _ = allocator;
    _ = block;
    if (g.len == 0 or g.len > 4) return error.BadBlock;
    for (g) |c| {
        if (!std.ascii.isHex(c)) return error.BadBlock;
    }
    return std.fmt.parseInt(u16, g, 16) catch error.BadBlock;
}

// ---------------------------------------------------------------------------
// IO boundary — commands come with WP3
// ---------------------------------------------------------------------------

pub fn cmd(ctx: Ctx, root: []const u8, args: []const []const u8) u8 {
    _ = ctx;
    _ = root;
    _ = args;
    util.die("yolo infra is not ported yet (WP3)");
}
