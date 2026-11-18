//! `yolo jump BOX connect [--accept-new] [USER@]HOST[:PORT]`: from the jump box
//! BOX, hold an ssh connection to HOST with the box's agent mux forwarded, in a
//! tmux session on the box named for HOST (the box's `jump connect`), and attach
//! to it. The box reconnects whenever the connection drops (HOST rebooting, the
//! network, the box itself restarting), so HOST keeps an agent without this
//! device.
//!
//! The box is told how to reach HOST first (`jump register`, all public), and
//! records it in its Datum ConfigMap:
//!   - one of this machine's yolo sessions: its iroh ticket and pinned host key,
//!     and USER defaults to the session's user;
//!   - any other host: its address, and the host key this machine already
//!     trusts for it (`ssh-keygen -F` on ~/.ssh/known_hosts), so the box pins
//!     exactly that. Without one, connect refuses unless --accept-new lets the
//!     box trust the key HOST offers now.
//! BOX must be a datum session running the jump image. Uses ssh and ssh-keygen
//! from PATH.

const std = @import("std");
const mem = std.mem;

const util = @import("util.zig");
const session = @import("session.zig");
const datum = @import("datum.zig");

const Ctx = util.Ctx;

pub const usage = "usage: yolo jump BOX connect [--accept-new] [USER@]HOST[:PORT]";

pub const Dest = struct { user: ?[]const u8, host: []const u8 };

/// `user@host` -> user and host; no `@` -> host only. The last `@` splits, as
/// in ssh.
pub fn splitDest(dest: []const u8) Dest {
    if (mem.lastIndexOfScalar(u8, dest, '@')) |i| {
        return .{ .user = if (i == 0) null else dest[0..i], .host = dest[i + 1 ..] };
    }
    return .{ .user = null, .host = dest };
}

/// A destination yolo accepts: non-empty, not an ssh option, and only
/// characters of user names, host names, ports and IP literals. The box checks
/// what it receives again.
pub fn validDest(dest: []const u8) bool {
    if (dest.len == 0 or dest[0] == '-') return false;
    for (dest) |c| {
        const ok = std.ascii.isAlphanumeric(c) or mem.indexOfScalar(u8, "@._:%+-[]", c) != null;
        if (!ok) return false;
    }
    return splitDest(dest).host.len != 0;
}

pub const HostPort = struct { host: []const u8, port: ?[]const u8 };

/// `host`, `host:port`, `[v6]:port`, or a bare IPv6 literal (two or more
/// colons, so no port). Null when malformed (empty host or a non-numeric port).
pub fn splitHostPort(s: []const u8) ?HostPort {
    if (s.len == 0) return null;
    if (s[0] == '[') {
        const close = mem.indexOfScalar(u8, s, ']') orelse return null;
        const host = s[1..close];
        if (host.len == 0) return null;
        const rest = s[close + 1 ..];
        if (rest.len == 0) return .{ .host = host, .port = null };
        if (rest[0] != ':' or !isPort(rest[1..])) return null;
        return .{ .host = host, .port = rest[1..] };
    }
    if (mem.indexOfScalar(u8, s, ']') != null) return null;
    const colons = mem.count(u8, s, ":");
    if (colons == 1) {
        const i = mem.indexOfScalar(u8, s, ':').?;
        if (i == 0 or !isPort(s[i + 1 ..])) return null;
        return .{ .host = s[0..i], .port = s[i + 1 ..] };
    }
    return .{ .host = s, .port = null };
}

fn isPort(s: []const u8) bool {
    if (s.len == 0 or s.len > 5) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    const n = std.fmt.parseInt(u32, s, 10) catch return false;
    return n >= 1 and n <= 65535;
}

/// The box's name for a host: its ssh Host entry, tmux session, ConfigMap key
/// (conn.NAME) and pinned-key alias. Characters outside [A-Za-z0-9.-] become
/// `-`; a port other than 22 is appended.
pub fn hostName(allocator: mem.Allocator, hp: HostPort) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (hp.host) |c| try out.append(allocator, if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-') c else '-');
    if (hp.port) |p| if (!mem.eql(u8, p, "22")) try out.print(allocator, "-{s}", .{p});
    return out.toOwnedSlice(allocator);
}

/// What `ssh-keygen -F` looks a host up as: `host`, or `[host]:port`.
pub fn knownHostsQuery(allocator: mem.Allocator, hp: HostPort) ![]u8 {
    if (hp.port) |p| if (!mem.eql(u8, p, "22")) return std.fmt.allocPrint(allocator, "[{s}]:{s}", .{ hp.host, p });
    return allocator.dupe(u8, hp.host);
}

/// `ssh-keygen -F` output -> `known_hosts=ALIAS TYPE KEY` lines, renamed to the
/// alias the box pins under (the client's names may be hashed). Comments and
/// marker lines (@cert-authority, @revoked) are skipped.
pub fn pinnedKeyLines(allocator: mem.Allocator, keygen_out: []const u8, alias: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = mem.splitScalar(u8, keygen_out, '\n');
    while (lines.next()) |line| {
        var f = mem.tokenizeAny(u8, line, " \t\r");
        const first = f.next() orelse continue;
        if (first[0] == '#' or first[0] == '@') continue;
        const kind = f.next() orelse continue;
        const key = f.next() orelse continue;
        try out.print(allocator, "known_hosts={s} {s} {s}\n", .{ alias, kind, key });
    }
    return out.toOwnedSlice(allocator);
}

/// `jump register` stdin for a yolo session, reached over iroh.
pub fn sessionPayload(allocator: mem.Allocator, dest: []const u8, ticket: []const u8, alias: []const u8, known_hosts: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "dest={s}\nalias={s}\nticket={s}\nknown_hosts={s}\n", .{ dest, alias, ticket, known_hosts });
}

/// `jump register` stdin for a host reached directly. `keys` is pinnedKeyLines
/// output; empty asks the box to accept the host's key on first use.
pub fn hostPayload(allocator: mem.Allocator, dest: []const u8, alias: []const u8, hp: HostPort, keys: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, "dest={s}\nalias={s}\nhostname={s}\n", .{ dest, alias, hp.host });
    if (hp.port) |p| try out.print(allocator, "port={s}\n", .{p});
    if (keys.len == 0) try out.appendSlice(allocator, "accept_new=1\n") else try out.appendSlice(allocator, keys);
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

pub fn cmd(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    if (rest.len < 3 or !mem.eql(u8, rest[1], "connect")) util.die(usage);
    var accept_new = false;
    var dest_arg: ?[]const u8 = null;
    for (rest[2..]) |a| {
        if (mem.eql(u8, a, "--accept-new")) {
            accept_new = true;
        } else if (dest_arg == null) {
            dest_arg = a;
        } else util.die(usage);
    }
    const dest_s = dest_arg orelse util.die(usage);
    const box = rest[0];
    if (!validDest(dest_s)) util.dief("jump: bad destination '{s}'", .{dest_s});
    if (!mem.eql(u8, session.sessionBackend(ctx, box), "datum"))
        util.dief("jump: {s} isn't a datum session", .{box});
    const d = datum.config(ctx, root);
    const bdir = session.dir(ctx, box);
    const bticket = util.readMeta(ctx, util.join(ctx, &.{ bdir, "ticket" }), "");
    if (bticket.len == 0) util.dief("no local state for {s}", .{box});
    const bwl = session.workload(ctx, bdir, box);
    const bident = if (util.readFileMaybe(ctx, util.join(ctx, &.{ bdir, "identity" }))) |i| util.trim(i) else null;

    const dest = splitDest(dest_s);
    var name: []const u8 = undefined;
    var target: []const u8 = undefined;
    var payload: []const u8 = undefined;
    // A session name can't be a host name with dots or a port, so only a valid
    // one is looked up.
    const hdir = if (session.validName(dest.host)) session.dir(ctx, dest.host) else "";
    const hticket = if (hdir.len == 0) "" else util.readMeta(ctx, util.join(ctx, &.{ hdir, "ticket" }), "");
    if (hticket.len != 0) {
        // One of this machine's yolo sessions.
        const hwl = session.workload(ctx, hdir, dest.host);
        const kh = util.trim(util.readFileMaybe(ctx, util.join(ctx, &.{ hdir, "known_hosts" })) orelse "");
        if (kh.len == 0) util.dief("jump: {s} has no known_hosts", .{dest.host});
        name = dest.host;
        target = std.fmt.allocPrint(ctx.arena, "{s}@{s}", .{ dest.user orelse d.user, name }) catch util.die("out of memory");
        payload = sessionPayload(ctx.arena, target, hticket, hwl, kh) catch util.die("out of memory");
    } else {
        // Any other host, reached directly, with the host key this machine trusts.
        const hp = splitHostPort(dest.host) orelse util.dief("jump: bad host '{s}'", .{dest.host});
        name = hostName(ctx.arena, hp) catch util.die("out of memory");
        target = if (dest.user) |u| std.fmt.allocPrint(ctx.arena, "{s}@{s}", .{ u, name }) catch util.die("out of memory") else name;
        const query = knownHostsQuery(ctx.arena, hp) catch util.die("out of memory");
        const kh_file = util.join(ctx, &.{ util.homeDir(ctx), ".ssh", "known_hosts" });
        const r = util.capture(ctx, &.{ "ssh-keygen", "-F", query, "-f", kh_file }, .{}) catch util.die("ssh-keygen isn't in PATH");
        const keys = pinnedKeyLines(ctx.arena, r.stdout, name) catch util.die("out of memory");
        if (keys.len == 0 and !accept_new)
            util.dief("jump: no host key for {s} in {s}; ssh to it once from here first, or pass --accept-new to trust the key it offers the box", .{ query, kh_file });
        payload = hostPayload(ctx.arena, target, name, hp, keys) catch util.die("out of memory");
    }

    const reg = datum.datumSsh(ctx, d, bdir, bwl, bticket, bident, &.{ "-o", "BatchMode=yes", "--", "register", name });
    const r = util.capture(ctx, reg, .{ .stdin = payload }) catch util.die("could not run ssh");
    if (r.term != .exited or r.code != 0)
        util.dief("jump: {s} refused to register {s}: {s}", .{ box, name, util.trim(r.stderr) });
    // What the box said about trust on first use, or about not recording it.
    if (r.stderr.len != 0) util.errPrint("{s}", .{r.stderr});
    const argv = datum.datumSsh(ctx, d, bdir, bwl, bticket, bident, &.{ "-t", "--", "connect", target });
    util.replace(ctx, argv);
}

const testing = std.testing;

test "splitDest takes the user before the last @" {
    const a = splitDest("someone@agent1");
    try testing.expectEqualStrings("someone", a.user.?);
    try testing.expectEqualStrings("agent1", a.host);
    const b = splitDest("agent1");
    try testing.expect(b.user == null);
    try testing.expectEqualStrings("agent1", b.host);
    const c = splitDest("a@b@host");
    try testing.expectEqualStrings("a@b", c.user.?);
    try testing.expectEqualStrings("host", c.host);
}

test "validDest refuses options, whitespace and shell characters" {
    try testing.expect(validDest("someone@agent1"));
    try testing.expect(validDest("host.example.com"));
    try testing.expect(validDest("me@2001:db8::1"));
    try testing.expect(validDest("me@[2001:db8::1]:2222"));
    try testing.expect(!validDest(""));
    try testing.expect(!validDest("-oProxyCommand=x"));
    try testing.expect(!validDest("a b"));
    try testing.expect(!validDest("a;b"));
    try testing.expect(!validDest("$(x)"));
    try testing.expect(!validDest("user@"));
}

test "splitHostPort: names, IPv4, IPv6 literals, ports" {
    const a = splitHostPort("metal1.example.com").?;
    try testing.expectEqualStrings("metal1.example.com", a.host);
    try testing.expect(a.port == null);
    const b = splitHostPort("metal1:2222").?;
    try testing.expectEqualStrings("metal1", b.host);
    try testing.expectEqualStrings("2222", b.port.?);
    const c = splitHostPort("192.0.2.7:22").?;
    try testing.expectEqualStrings("192.0.2.7", c.host);
    const v6 = splitHostPort("2001:db8::7").?;
    try testing.expectEqualStrings("2001:db8::7", v6.host);
    try testing.expect(v6.port == null);
    const v6p = splitHostPort("[2001:db8::7]:2222").?;
    try testing.expectEqualStrings("2001:db8::7", v6p.host);
    try testing.expectEqualStrings("2222", v6p.port.?);
    try testing.expect(splitHostPort("[2001:db8::7]").?.port == null);
    try testing.expect(splitHostPort("") == null);
    try testing.expect(splitHostPort(":22") == null);
    try testing.expect(splitHostPort("host:") == null);
    try testing.expect(splitHostPort("host:99999") == null);
    try testing.expect(splitHostPort("host:x") == null);
    try testing.expect(splitHostPort("[]:22") == null);
    try testing.expect(splitHostPort("[::1]x") == null);
}

test "hostName is safe for ssh, tmux and ConfigMap keys" {
    const a = testing.allocator;
    const n1 = try hostName(a, .{ .host = "metal1.example.com", .port = null });
    defer a.free(n1);
    try testing.expectEqualStrings("metal1.example.com", n1);
    const n2 = try hostName(a, .{ .host = "2001:db8::7", .port = "2222" });
    defer a.free(n2);
    try testing.expectEqualStrings("2001-db8--7-2222", n2);
    const n3 = try hostName(a, .{ .host = "metal1", .port = "22" });
    defer a.free(n3);
    try testing.expectEqualStrings("metal1", n3);
}

test "knownHostsQuery brackets a non-default port" {
    const a = testing.allocator;
    const q1 = try knownHostsQuery(a, .{ .host = "metal1", .port = null });
    defer a.free(q1);
    try testing.expectEqualStrings("metal1", q1);
    const q2 = try knownHostsQuery(a, .{ .host = "2001:db8::7", .port = "2222" });
    defer a.free(q2);
    try testing.expectEqualStrings("[2001:db8::7]:2222", q2);
}

test "pinnedKeyLines renames (hashed) hosts to the alias and skips the rest" {
    const out =
        \\# Host metal1 found: line 12
        \\|1|c2FsdA==|aGFzaA== ssh-ed25519 AAAAC3Nza
        \\metal1 ecdsa-sha2-nistp256 AAAAE2Vj
        \\@cert-authority *.example.com ssh-ed25519 AAAAca
        \\
    ;
    const got = try pinnedKeyLines(testing.allocator, out, "metal1");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("known_hosts=metal1 ssh-ed25519 AAAAC3Nza\nknown_hosts=metal1 ecdsa-sha2-nistp256 AAAAE2Vj\n", got);
}

test "payloads are one key per line" {
    const a = testing.allocator;
    const p = try sessionPayload(a, "someone@agent1", "endpointabc", "yolo-agent1", "yolo-agent1 ssh-ed25519 AAAA");
    defer a.free(p);
    try testing.expectEqualStrings("dest=someone@agent1\nalias=yolo-agent1\nticket=endpointabc\nknown_hosts=yolo-agent1 ssh-ed25519 AAAA\n", p);
    const h = try hostPayload(a, "root@metal1-2222", "metal1-2222", .{ .host = "metal1", .port = "2222" }, "known_hosts=metal1-2222 ssh-ed25519 AAAA\n");
    defer a.free(h);
    try testing.expectEqualStrings("dest=root@metal1-2222\nalias=metal1-2222\nhostname=metal1\nport=2222\nknown_hosts=metal1-2222 ssh-ed25519 AAAA\n", h);
    const t = try hostPayload(a, "metal1", "metal1", .{ .host = "metal1", .port = null }, "");
    defer a.free(t);
    try testing.expectEqualStrings("dest=metal1\nalias=metal1\nhostname=metal1\naccept_new=1\n", t);
}
