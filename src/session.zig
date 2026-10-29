//! Sessions: directories under $YOLO_STATE (~/.local/state/yolo/sessions),
//! each at least a `backend` and a `harness`, plus each backend's own files
//! (keys, tickets, the runtime it was made with).

const std = @import("std");
const util = @import("util.zig");
const Ctx = util.Ctx;

pub const harnesses = [_][]const u8{ "claude", "gemini", "codex", "opencode", "pi" };

pub const classes = [_][]const u8{ "unikernel", "general-purpose" };

/// Datum names a session's Workload and Secret PREFIX-NAME. New sessions are
/// yolo-NAME; agent-NAME is how they were named before, and still works.
pub const workload_prefixes = [_][]const u8{ "yolo-", "agent-" };

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// A session name: lowercase letters, digits and '-', at most 40 chars, and
/// it must start and end with a letter or digit.
pub fn validName(name: []const u8) bool {
    const ok = struct {
        fn f(c: u8) bool {
            return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        }
    }.f;
    if (name.len == 0 or name.len > 40) return false;
    if (!ok(name[0]) or !ok(name[name.len - 1])) return false;
    for (name) |c| {
        if (!ok(c) and c != '-') return false;
    }
    return true;
}

pub fn checkHarness(h: []const u8) void {
    if (!isHarness(h)) util.dief("unknown harness '{s}' (have: claude gemini codex opencode pi)", .{h});
}

pub fn isHarness(h: []const u8) bool {
    for (harnesses) |x| {
        if (std.mem.eql(u8, x, h)) return true;
    }
    return false;
}

pub fn isClass(c: []const u8) bool {
    for (classes) |x| {
        if (std.mem.eql(u8, x, c)) return true;
    }
    return false;
}

/// NAME for a session's Workload name, if it is one (`sessionOfWorkload`).
pub fn sessionOfWorkload(w: []const u8) ?[]const u8 {
    for (workload_prefixes) |p| {
        if (std.mem.startsWith(u8, w, p) and w.len > p.len) return w[p.len..];
    }
    return null;
}

/// The session's workload (and Secret) name for NAME, before a record exists.
pub fn defaultWorkload(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "agent-{s}", .{name});
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// $YOLO_STATE, else $XDG_STATE_HOME/yolo/sessions
/// (~/.local/state/yolo/sessions).
pub fn state(ctx: Ctx) []const u8 {
    return ctx.envNonEmpty("YOLO_STATE") orelse util.join(ctx, &.{ util.stateHome(ctx), "yolo/sessions" });
}

/// The directory of the default state (before $YOLO_STATE is applied).
pub fn defaultState(ctx: Ctx) []const u8 {
    return util.join(ctx, &.{ util.stateHome(ctx), "yolo/sessions" });
}

/// The session's directory, after checking its name (`sessionDir`).
pub fn dir(ctx: Ctx, name: []const u8) []const u8 {
    if (!validName(name)) util.die("name must be lowercase letters, digits and '-', at most 40 chars");
    return util.join(ctx, &.{ state(ctx), name });
}

/// Sessions of one backend that have local state (`localSessions`).
pub fn localSessions(ctx: Ctx, backend: []const u8) []const []const u8 {
    const st = state(ctx);
    const names = util.listDir(ctx, st);
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| {
        const p = util.join(ctx, &.{ st, n, "backend" });
        if (std.mem.eql(u8, util.readMeta(ctx, p, ""), backend)) out.append(ctx.arena, n) catch {};
    }
    return out.items;
}

/// The session's directory, mode 700, with its backend and harness recorded
/// (`sessionCreate`). Dies when the session already exists.
pub fn create(ctx: Ctx, name: []const u8, backend: []const u8, harness: []const u8) []const u8 {
    const d = dir(ctx, name);
    if (util.exists(ctx, d)) util.dief("session {s} exists ({s}); yolo rm {s} first", .{ name, d, name });
    util.createDirPath(ctx, d) catch |e| util.dief("can't create {s}: {t}", .{ d, e });
    std.Io.Dir.cwd().setFilePermissions(ctx.io, d, @fromBackingInt(@intCast(0o700)), .{}) catch {};
    const backendFile = util.join(ctx, &.{ d, "backend" });
    util.writeFileOrDie(ctx, backendFile, std.fmt.allocPrint(ctx.arena, "{s}\n", .{backend}) catch "");
    const harnessFile = util.join(ctx, &.{ d, "harness" });
    util.writeFileOrDie(ctx, harnessFile, std.fmt.allocPrint(ctx.arena, "{s}\n", .{harness}) catch "");
    return d;
}

/// The backend recorded for the session. Adopts it from Datum, if it's a
/// session made on another machine, and dies when it's neither.
pub fn sessionBackend(ctx: Ctx, name: []const u8) []const u8 {
    const d = dir(ctx, name);
    const backendFile = util.join(ctx, &.{ d, "backend" });
    if (util.fileExists(ctx, backendFile)) return util.readMeta(ctx, backendFile, "?");
    const datum = @import("datum.zig");
    const adopted = datum.adopt(ctx, true, name) catch |e| switch (e) {
        error.NotOnDatum => util.dief("no session {s} (yolo ls)", .{name}),
        error.CanNotAdopt => util.die(datum.adopt_message),
    };
    if (adopted) return "datum";
    util.dief("no session {s} (yolo ls)", .{name});
}

/// Sessions created by agent-sandbox (Datum only) move here once; the old
/// directory becomes a symlink to the new one. Skipped when YOLO_STATE is
/// overridden.
pub fn migrateAgentSandboxState(ctx: Ctx) void {
    const st = state(ctx);
    if (!std.mem.eql(u8, st, defaultState(ctx))) return;
    const old = util.join(ctx, &.{ util.stateHome(ctx), "agent-sandbox" });
    if (!util.dirExists(ctx, old) or util.isSymlink(ctx, old)) return;
    util.createDirPath(ctx, st) catch |e| util.dief("can't create {s}: {t}", .{ st, e });
    for (util.listDir(ctx, old)) |n| {
        if (!util.dirExists(ctx, util.join(ctx, &.{ old, n }))) continue;
        const target = util.join(ctx, &.{ st, n });
        if (util.exists(ctx, target)) util.dief("can't migrate {s}: {s} exists", .{ n, target });
        util.rename(ctx, util.join(ctx, &.{ old, n }), target) catch |e|
            util.dief("can't migrate {s}: {t}", .{ n, e });
        util.writeFileOrDie(ctx, util.join(ctx, &.{ target, "backend" }), "datum\n");
        util.warn("moved agent-sandbox session {s} to {s}", .{ n, st });
    }
    util.removeTree(ctx, old);
    util.symlink(ctx, st, old) catch |e| util.dief("can't link {s} to {s}: {t}", .{ old, st, e });
}

/// The Datum login a session belongs to, so syncing under another login
/// leaves it alone (`recordDatumSession`).
pub fn recordDatumSession(ctx: Ctx, d: []const u8) void {
    const login = ctx.envNonEmpty("DATUM_SESSION") orelse return;
    util.writeFileOrDie(ctx, util.join(ctx, &.{ d, "datum_session" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{login}) catch "");
}

/// The session's workload (and Secret) name, as recorded in its local state;
/// sessions from before the record are agent-NAME (`sessionWorkload`).
pub fn workload(ctx: Ctx, d: []const u8, name: []const u8) []const u8 {
    const fallback = defaultWorkload(ctx.arena, name) catch util.die("out of memory");
    return util.readMeta(ctx, util.join(ctx, &.{ d, "workload" }), fallback);
}

/// Backend dispatch: what a backend implements. A new backend is a new arm
/// here plus its name in loadBackend (main.zig).

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validName accepts lowercase names that start and end with a letter or digit" {
    try testing.expect(validName("foo"));
    try testing.expect(validName("foo-bar-2"));
    try testing.expect(validName("a"));
    try testing.expect(validName("0123456789012345678901234567890123456789")); // 40
    try testing.expect(!validName(""));
    try testing.expect(!validName("-foo"));
    try testing.expect(!validName("foo-"));
    try testing.expect(!validName("Foo"));
    try testing.expect(!validName("foo_bar"));
    try testing.expect(!validName("01234567890123456789012345678901234567890")); // 41
    try testing.expect(!validName("a b"));
}

test "sessionOfWorkload strips yolo- and agent-, and nothing else" {
    try testing.expectEqualStrings("pi", sessionOfWorkload("yolo-pi").?);
    try testing.expectEqualStrings("pi", sessionOfWorkload("agent-pi").?);
    try testing.expectEqualStrings("agent-pi", sessionOfWorkload("yolo-agent-pi").?);
    try testing.expect(sessionOfWorkload("yolo-") == null);
    try testing.expect(sessionOfWorkload("agent-") == null);
    try testing.expect(sessionOfWorkload("other-pi") == null);
    try testing.expect(sessionOfWorkload("") == null);
}
