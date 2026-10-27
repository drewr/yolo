//! Golden vectors produced by the Haskell yolo (8ec99da) before it was
//! deleted: the iroh ticket and z-base-32 label from 20 random secrets,
//! shortImage, age, subnet64 and the table renderer. Byte-identical output is
//! a compatibility invariant (docs/zig-port-plan.md).

const std = @import("std");
const testing = std.testing;

const keys = @import("keys.zig");
const util = @import("util.zig");
const infra = @import("infra.zig");

const vectors = @embedFile("golden/vectors.txt");

/// Split the file into sections keyed by their "# name" line.
fn section(comptime name: []const u8) []const u8 {
    const header = "# " ++ name;
    const start = std.mem.indexOf(u8, vectors, header) orelse @panic("missing section " ++ name);
    const after = start + header.len;
    // Skip the newline that ends the header.
    var body = after;
    if (body < vectors.len and vectors[body] == '\n') body += 1;
    const end = std.mem.indexOf(u8, vectors[body..], "\n# ") orelse (vectors.len - body);
    // A section is followed by exactly one blank line (before the next header,
    // or at EOF); everything before it, its own trailing newline included, is
    // the vector.
    var out = vectors[body .. body + end];
    if (std.mem.endsWith(u8, out, "\n")) out = out[0 .. out.len - 1];
    return out;
}

fn linesOf(allocator: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (line.len != 0) try out.append(allocator, line);
    }
    return out.items;
}

test "golden: iroh ticket and z-base-32 label from the Haskell" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lines = try linesOf(a, section("secrets"));
    try testing.expect(lines.len >= 20);
    for (lines) |line| {
        var it = std.mem.tokenizeAny(u8, line, " ");
        const hex = it.next().?;
        const ticket = it.next().?;
        const label = it.next().?;
        const got_ticket = try keys.endpointTicket(a, "https://use1-1.relay.n0.iroh.link./", hex);
        try testing.expectEqualStrings(ticket, got_ticket);
        const pubkey = try keys.pubFromSecretHex(hex);
        const got_label = try keys.zbase32(a, &pubkey);
        try testing.expectEqualStrings(label, got_label);
    }
}

test "golden: shortImage" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (try linesOf(a, section("shortImage"))) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        try testing.expectEqualStrings(
            line[tab + 1 ..],
            try util.shortImage(a, line[0..tab]),
        );
    }
}

test "golden: age" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (try linesOf(a, section("age"))) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        const secs = try std.fmt.parseInt(i64, line[0..tab], 10);
        try testing.expectEqualStrings(line[tab + 1 ..], try util.ageSeconds(a, secs));
    }
}

test "golden: subnet64" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (try linesOf(a, section("subnet64"))) |line| {
        var it = std.mem.splitScalar(u8, line, '\t');
        const block = it.next().?;
        const i = try std.fmt.parseInt(u32, it.next().?, 10);
        const want = it.next().?;
        if (std.mem.startsWith(u8, want, "ERR ")) {
            try testing.expectError(error.BadBlock, infra.subnet64(a, block, i));
        } else {
            try testing.expectEqualStrings(want, try infra.subnet64(a, block, i));
        }
    }
}

test "golden: table" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = [_][]const []const u8{
        &.{ "NAME", "HEALTH" },
        &.{ "a", "Available" },
        &.{ "bbbbbbbbbbbbbbbbbbbbbbbb", "Unavailable" },
    };
    try testing.expectEqualStrings(section("table"), try util.renderTable(a, &rows));
}

// ---------------------------------------------------------------------------
// known_hosts: HostKeyAlias, key type, key material (the Haskell's
// `unwords (wl : take 2 (words pub))`).
// ---------------------------------------------------------------------------

test "known_hosts line takes the key type and material" {
    const pub_line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEYb2mRCeLVrTfGBhk5YgQvcIIfh+FNsftv8wp+erR2m drewr@agent-foo\n";
    const line = try keys.knownHostsLine(testing.allocator, "agent-foo", pub_line);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings(
        "agent-foo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEYb2mRCeLVrTfGBhk5YgQvcIIfh+FNsftv8wp+erR2m",
        line,
    );
}

// ---------------------------------------------------------------------------
// The `yolo ls` session table: fixed-width columns, one space apart.
// ---------------------------------------------------------------------------

test "datum table rows keep their own values" {
    // Regression: rows appended with `&row` aliased one stack slot, so every
    // session showed the last one's values.
    const r1 = [_][]const u8{ "NAME", "HEALTH", "READY" };
    const r2 = [_][]const u8{ "bar", "Available", "1/1" };
    const r3 = [_][]const u8{ "foo", "Available", "1/1" };
    const rows = [_][]const []const u8{ &r1, &r2, &r3 };
    const rendered = try util.renderTable(testing.allocator, &rows);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        "NAME   HEALTH      READY\nbar    Available   1/1\nfoo    Available   1/1\n",
        rendered,
    );
}

// ---------------------------------------------------------------------------
// Session names and workloads.
// ---------------------------------------------------------------------------

test "session name rule" {
    const session = @import("session.zig");
    try testing.expect(session.validName("foo"));
    try testing.expect(session.validName("a-1"));
    try testing.expect(!session.validName(""));
    try testing.expect(!session.validName("-foo"));
    try testing.expect(!session.validName("foo-"));
    try testing.expect(!session.validName("Foo"));
    try testing.expect(!session.validName("foo_bar"));
    const forty = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const forty_one = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try testing.expect(session.validName(forty));
    try testing.expect(!session.validName(forty_one));
}

// ---------------------------------------------------------------------------
// ssh argument split (datum attach): options first, then the command.
// ---------------------------------------------------------------------------

test "ssh args: value options stay options" {
    const datum = @import("datum.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = [_][]const u8{ "-o", "IdentitiesOnly=yes", "-L", "1:2", "echo", "-o", "x" };
    const split = datum.splitSshArgs(a, &args);
    try testing.expectEqual(@as(usize, 4), split.opts.len);
    try testing.expectEqualStrings("-o", split.opts[0]);
    try testing.expectEqualStrings("IdentitiesOnly=yes", split.opts[1]);
    try testing.expectEqualStrings("-L", split.opts[2]);
    try testing.expectEqualStrings("1:2", split.opts[3]);
    try testing.expectEqual(@as(usize, 3), split.cmd.len);
    try testing.expectEqualStrings("echo", split.cmd[0]);
}

test "ssh args: -- starts the command" {
    const datum = @import("datum.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = [_][]const u8{ "-q", "--", "-o", "true" };
    const split = datum.splitSshArgs(a, &args);
    try testing.expectEqual(@as(usize, 1), split.opts.len);
    try testing.expectEqualStrings("-q", split.opts[0]);
    try testing.expectEqual(@as(usize, 2), split.cmd.len);
    try testing.expectEqualStrings("-o", split.cmd[0]);
    try testing.expectEqualStrings("true", split.cmd[1]);
}

test "ssh args: no arguments leaves the command empty" {
    const datum = @import("datum.zig");
    const split = datum.splitSshArgs(testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), split.opts.len);
    try testing.expectEqual(@as(usize, 0), split.cmd.len);
}
