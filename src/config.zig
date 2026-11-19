//! Config: a deployment's small key/value settings, secret and plain, kept by
//! its backend (docs/jump-host-plan.md). A box finds its Config through
//! YOLO_CONFIG_URL:
//!
//!   datum://PROJECT/NAME   in Datum project PROJECT: secret entries in Secret
//!                          NAME, plain entries in ConfigMap NAME
//!   file:///DIR            DIR/secret/KEY (0600) and DIR/plain/KEY (0644)
//!
//! Keys follow the Kubernetes rule for Secret and ConfigMap keys on every
//! backend, so an entry moves between backends unchanged and a key is always a
//! safe file name.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const util = @import("util.zig");
const datumapi = @import("datumapi.zig");

const Ctx = util.Ctx;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// Whether an entry is a secret (keys, credentials) or plain (connections,
/// session records, the deployment generation).
pub const Kind = enum {
    secret,
    plain,

    /// The directory of a file:// Config that holds entries of this kind.
    pub fn dirName(k: Kind) []const u8 {
        return @tagName(k);
    }

    /// The Datum resource that holds entries of this kind.
    pub fn datumResource(k: Kind) []const u8 {
        return switch (k) {
            .secret => "secrets",
            .plain => "configmaps",
        };
    }

    /// The mode of a file:// entry: a secret is readable by its owner only.
    pub fn fileMode(k: Kind) u32 {
        return switch (k) {
            .secret => 0o600,
            .plain => 0o644,
        };
    }

    /// The mode of a file:// Config's directory for entries of this kind.
    pub fn dirMode(k: Kind) u32 {
        return switch (k) {
            .secret => 0o700,
            .plain => 0o755,
        };
    }
};

pub const Entry = struct {
    kind: Kind,
    key: []const u8,
    value: []const u8,
};

/// Where a Config lives: a parsed YOLO_CONFIG_URL. Slices point into the URL.
pub const Location = union(enum) {
    datum: struct { project: []const u8, name: []const u8 },
    file: struct { dir: []const u8 },
};

/// YOLO_CONFIG_URL -> its Location; null when malformed. A file:// URL must
/// have an empty host and an absolute path; a trailing `/` is dropped. Neither
/// scheme takes a query or fragment.
pub fn parseUrl(url: []const u8) ?Location {
    if (mem.indexOfAny(u8, url, "?#") != null) return null;
    if (mem.startsWith(u8, url, "datum://")) {
        const rest = url["datum://".len..];
        const slash = mem.indexOfScalar(u8, rest, '/') orelse return null;
        const project = rest[0..slash];
        const name = rest[slash + 1 ..];
        if (!validObjectName(project) or !validObjectName(name)) return null;
        return .{ .datum = .{ .project = project, .name = name } };
    }
    if (mem.startsWith(u8, url, "file://")) {
        const path = url["file://".len..];
        if (path.len == 0 or path[0] != '/') return null;
        const dir = mem.trimEnd(u8, path, "/");
        if (dir.len == 0) return null;
        return .{ .file = .{ .dir = dir } };
    }
    return null;
}

/// A Kubernetes object name (DNS-1123 subdomain), which Datum uses for
/// projects, Secrets and ConfigMaps: 1 to 253 lowercase letters, digits, `-`
/// and `.`, starting and ending with a letter or digit.
pub fn validObjectName(name: []const u8) bool {
    if (name.len == 0 or name.len > 253) return false;
    if (!isLowerAlnum(name[0]) or !isLowerAlnum(name[name.len - 1])) return false;
    for (name) |c| {
        if (!isLowerAlnum(c) and c != '-' and c != '.') return false;
    }
    return true;
}

fn isLowerAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// A Config key: 1 to 253 of `[-._a-zA-Z0-9]`, and not `.` or `..` (the
/// Kubernetes rule for Secret and ConfigMap keys).
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 253) return false;
    if (mem.eql(u8, key, ".") or mem.eql(u8, key, "..")) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and mem.indexOfScalar(u8, "-._", c) == null) return false;
    }
    return true;
}

/// The file of an entry in a file:// Config. `key` must be validKey.
pub fn filePath(allocator: mem.Allocator, dir: []const u8, kind: Kind, key: []const u8) ![]u8 {
    std.debug.assert(validKey(key));
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ dir, kind.dirName(), key });
}

/// What `yolo cfg` does with an entry.
pub const Op = enum { get, put, list };

/// A parsed `yolo cfg` command. `key` is empty for `list`.
pub const Cmd = struct {
    op: Op,
    kind: Kind,
    key: []const u8,
};

pub const usage = "usage: yolo cfg get [--secret] KEY | put [--secret] KEY | list [--secret]";

/// The arguments after `cfg`: `get KEY`, `put KEY` or `list`, each with an
/// optional `--secret` in any position (at most once). Null when malformed. The
/// key's syntax is left to `validKey`, so the caller can name the bad key.
pub fn parseArgs(args: []const []const u8) ?Cmd {
    if (args.len == 0) return null;
    const op: Op = if (mem.eql(u8, args[0], "get"))
        .get
    else if (mem.eql(u8, args[0], "put"))
        .put
    else if (mem.eql(u8, args[0], "list"))
        .list
    else
        return null;
    var secret = false;
    var key: ?[]const u8 = null;
    for (args[1..]) |a| {
        if (mem.eql(u8, a, "--secret")) {
            if (secret) return null;
            secret = true;
        } else if (mem.startsWith(u8, a, "--")) {
            return null;
        } else {
            if (key != null) return null;
            key = a;
        }
    }
    if (op == .list) {
        if (key != null) return null;
    } else if (key == null) {
        return null;
    }
    return .{
        .op = op,
        .kind = if (secret) .secret else .plain,
        .key = key orelse "",
    };
}

test "parseUrl reads datum:// and file:// locations" {
    const d = parseUrl("datum://proj-1/yolo-box1-config").?;
    try testing.expectEqualStrings("proj-1", d.datum.project);
    try testing.expectEqualStrings("yolo-box1-config", d.datum.name);
    const f = parseUrl("file:///var/lib/yolo/config").?;
    try testing.expectEqualStrings("/var/lib/yolo/config", f.file.dir);
    try testing.expectEqualStrings("/srv/cfg", parseUrl("file:///srv/cfg/").?.file.dir);
}

test "parseUrl refuses malformed URLs" {
    const bad = [_][]const u8{
        "",
        "proj-1/box",
        "s3://bucket/prefix",
        "datum://",
        "datum://proj-1",
        "datum://proj-1/",
        "datum:///box",
        "datum://Proj/box",
        "datum://proj-1/box/extra",
        "datum://proj-1/box?x=1",
        "datum://proj-1/box#x",
        "datum://proj-1/-box",
        "file://",
        "file://host/dir",
        "file://relative",
        "file:///",
        "file:///dir?x=1",
    };
    for (bad) |u| {
        if (parseUrl(u) != null) {
            std.debug.print("accepted: {s}\n", .{u});
            return error.TestUnexpectedResult;
        }
    }
}

const len253: [253]u8 = @splat('a');
const len254: [254]u8 = @splat('a');

test "validObjectName is the DNS-1123 subdomain rule" {
    try testing.expect(validObjectName("a"));
    try testing.expect(validObjectName("yolo-box1.config"));
    try testing.expect(validObjectName(&len253));
    try testing.expect(!validObjectName(""));
    try testing.expect(!validObjectName(&len254));
    try testing.expect(!validObjectName("Box"));
    try testing.expect(!validObjectName("box_1"));
    try testing.expect(!validObjectName("-box"));
    try testing.expect(!validObjectName("box."));
}

test "validKey is the Secret and ConfigMap key rule" {
    try testing.expect(validKey("ssh-key-abc"));
    try testing.expect(validKey("conn.metal1"));
    try testing.expect(validKey("datum-credentials.json"));
    try testing.expect(validKey("A_b"));
    try testing.expect(validKey(".hidden"));
    try testing.expect(validKey(&len253));
    try testing.expect(!validKey(""));
    try testing.expect(!validKey("."));
    try testing.expect(!validKey(".."));
    try testing.expect(!validKey("a/b"));
    try testing.expect(!validKey("a b"));
    try testing.expect(!validKey("a:b"));
    try testing.expect(!validKey(&len254));
}

test "Kind maps to each backend's place and mode" {
    try testing.expectEqualStrings("secrets", Kind.secret.datumResource());
    try testing.expectEqualStrings("configmaps", Kind.plain.datumResource());
    try testing.expectEqual(@as(u32, 0o600), Kind.secret.fileMode());
    try testing.expectEqual(@as(u32, 0o644), Kind.plain.fileMode());
    const p = try filePath(testing.allocator, "/srv/cfg", .secret, "ssh-key-abc");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/srv/cfg/secret/ssh-key-abc", p);
}

test "Kind's directories are private for secrets" {
    try testing.expectEqual(@as(u32, 0o700), Kind.secret.dirMode());
    try testing.expectEqual(@as(u32, 0o755), Kind.plain.dirMode());
}

test "parseArgs: get, put and list, with --secret in any position" {
    const g = parseArgs(&.{ "get", "db-host" }).?;
    try testing.expectEqual(Op.get, g.op);
    try testing.expectEqual(Kind.plain, g.kind);
    try testing.expectEqualStrings("db-host", g.key);
    try testing.expectEqual(Kind.secret, parseArgs(&.{ "get", "--secret", "k" }).?.kind);
    try testing.expectEqual(Kind.secret, parseArgs(&.{ "get", "k", "--secret" }).?.kind);
    const p = parseArgs(&.{ "put", "--secret", "k" }).?;
    try testing.expectEqual(Op.put, p.op);
    try testing.expectEqual(Kind.secret, p.kind);
    try testing.expectEqualStrings("k", p.key);
    const l = parseArgs(&.{"list"}).?;
    try testing.expectEqual(Op.list, l.op);
    try testing.expectEqual(Kind.plain, l.kind);
    try testing.expectEqualStrings("", l.key);
    try testing.expectEqual(Kind.secret, parseArgs(&.{ "list", "--secret" }).?.kind);
}

test "parseArgs refuses malformed commands" {
    const bad = [_][]const []const u8{
        &.{},
        &.{ "frob", "k" },
        &.{"GET"},
        &.{"get"},
        &.{ "put", "--secret" },
        &.{ "get", "k", "x" },
        &.{ "list", "k" },
        &.{ "get", "--secret", "--secret", "k" },
        &.{ "get", "--json", "k" },
        &.{ "get", "--" },
    };
    for (bad) |a| {
        if (parseArgs(a) != null) return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// `yolo cfg get|put|list`: the Config at YOLO_CONFIG_URL.
pub fn cmd(ctx: Ctx, args: []const []const u8) u8 {
    const c = parseArgs(args) orelse util.die(usage);
    if (c.op != .list and !validKey(c.key))
        util.dief("cfg: bad key '{s}': use 1 to 253 of a-z A-Z 0-9 - . _, not . or ..", .{c.key});
    const url = ctx.opt("CONFIG_URL", "");
    if (url.len == 0) util.die("cfg: YOLO_CONFIG_URL isn't set (in the environment or yolo.conf)");
    const loc = parseUrl(url) orelse
        util.dief("cfg: bad YOLO_CONFIG_URL '{s}' (file:///DIR or datum://PROJECT/NAME)", .{url});
    return switch (loc) {
        .datum => |d| switch (c.op) {
            .get => datumapi.get(ctx, d.project, d.name, c.kind, c.key),
            .put => datumapi.put(ctx, d.project, d.name, c.kind, c.key, readStdin(ctx)),
            .list => datumapi.list(ctx, d.project, d.name, c.kind),
        },
        .file => |f| switch (c.op) {
            .get => getFile(ctx, f.dir, c),
            .put => putFile(ctx, f.dir, c),
            .list => listFile(ctx, f.dir, c.kind),
        },
    };
}

fn getFile(ctx: Ctx, dir: []const u8, c: Cmd) u8 {
    const path = filePath(ctx.arena, dir, c.kind, c.key) catch util.die("out of memory");
    const value = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => util.dief("cfg: no {s} entry {s}", .{ c.kind.dirName(), c.key }),
        else => util.dief("cfg: can't read {s} entry {s}: {t}", .{ c.kind.dirName(), c.key, e }),
    };
    util.outRaw(value);
    return 0;
}

fn putFile(ctx: Ctx, dir: []const u8, c: Cmd) u8 {
    const sub = util.join(ctx, &.{ dir, c.kind.dirName() });
    ensureKindDir(ctx, sub, c.kind);
    const target = filePath(ctx.arena, dir, c.kind, c.key) catch util.die("out of memory");
    const value = readStdin(ctx);
    writeAtomic(ctx, sub, target, c.kind.fileMode(), value) catch |e|
        util.dief("cfg: can't write {s} entry {s}: {t}", .{ c.kind.dirName(), c.key, e });
    return 0;
}

fn listFile(ctx: Ctx, dir: []const u8, kind: Kind) u8 {
    // Names that aren't valid keys (temporary files, strays) are skipped; a
    // missing directory lists as empty.
    for (util.listDir(ctx, util.join(ctx, &.{ dir, kind.dirName() }))) |name| {
        if (validKey(name)) util.say(name);
    }
    return 0;
}

/// Create the kind's directory with its mode when it is missing (an existing
/// one keeps whatever mode its owner gave it).
fn ensureKindDir(ctx: Ctx, sub: []const u8, kind: Kind) void {
    if (util.dirExists(ctx, sub)) return;
    util.createDirPath(ctx, sub) catch |e| util.dief("cfg: can't create {s}: {t}", .{ sub, e });
    std.Io.Dir.cwd().setFilePermissions(ctx.io, sub, .fromMode(kind.dirMode()), .{}) catch |e|
        util.dief("cfg: can't set the mode of {s}: {t}", .{ sub, e });
}

/// All of stdin, verbatim: the value is never trimmed.
fn readStdin(ctx: Ctx) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.readStreaming(std.Io.File.stdin(), ctx.io, &.{buf[0..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => util.dief("cfg: can't read stdin: {t}", .{e}),
        };
        if (n == 0) break;
        out.appendSlice(ctx.arena, buf[0..n]) catch util.die("out of memory");
    }
    return out.items;
}

/// Write `value` to a new file in `sub` created with `mode`, fsync it, then
/// rename it over `target`: a reader sees the old entry or the new one, never a
/// part of either. The temporary name holds a `~`, which validKey refuses, so
/// `list` skips it; on failure it is removed.
fn writeAtomic(ctx: Ctx, sub: []const u8, target: []const u8, mode: u32, value: []const u8) !void {
    var rnd: [8]u8 = undefined;
    try util.randomBytes(ctx, &rnd);
    const tmp = try std.fmt.allocPrint(ctx.arena, "{s}/~tmp-{x:0>16}", .{ sub, mem.readInt(u64, &rnd, .little) });
    var f = try std.Io.Dir.cwd().createFile(ctx.io, tmp, .{ .exclusive = true, .permissions = .fromMode(mode) });
    var renamed = false;
    defer if (!renamed) util.removeFile(ctx, tmp);
    defer f.close(ctx.io);
    try f.writeStreamingAll(ctx.io, value);
    try f.sync(ctx.io);
    try util.rename(ctx, tmp, target);
    renamed = true;
}
