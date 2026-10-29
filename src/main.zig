//! yolo: run coding agents in named, isolated sessions, locally (docker or
//! podman) or on Datum Compute. Each session runs one harness's image: claude
//! (default), gemini, codex, opencode or pi. `yolo help` lists the commands.
//!
//! Session state lives in $YOLO_STATE (~/.local/state/yolo/sessions/NAME): at
//! least `backend` and `harness`, plus each backend's own files (keys,
//! tickets). Only `yolo new` needs --backend; later commands read it there.
//!
//! Not in nixpkgs, or deliberately the host's, so taken from PATH: datumctl
//! (datum backend and builds), podman, colima or docker (docker backend), ssh,
//! ssh-keygen, ssh-add, aws, git and nix.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const util = @import("util.zig");
const json = @import("json.zig");
const session = @import("session.zig");
const keys = @import("keys.zig");
const docker = @import("docker.zig");
const datum = @import("datum.zig");
const infra = @import("infra.zig");
const images = @import("images.zig");

const Ctx = util.Ctx;

/// A functional backend: the five session operations, closed over its config.
/// A new backend is a new arm here plus its name in loadBackend.
pub const Backend = union(enum) {
    /// The runtime a new session gets; later commands read the recorded one.
    docker: docker.Runtime,
    datum: datum.Datum,

    pub fn new(ctx: Ctx, self: Backend, root: []const u8, name: []const u8, harness: []const u8, opts: []const []const u8) u8 {
        return switch (self) {
            .docker => |r| docker.dockerNew(ctx, root, r, docker.config(ctx, r), name, harness, opts),
            .datum => |d| datum.datumNew(ctx, d, name, harness, opts),
        };
    }

    pub fn attach(ctx: Ctx, self: Backend, name: []const u8, args: []const []const u8) u8 {
        return switch (self) {
            .docker => |r| docker.dockerAttach(ctx, docker.config(ctx, r), name, args),
            .datum => |d| datum.datumAttach(ctx, d, name, args),
        };
    }

    pub fn ls(ctx: Ctx, self: Backend, full: bool) u8 {
        return switch (self) {
            .docker => docker.dockerLs(ctx),
            .datum => |d| datum.datumLs(ctx, d, full),
        };
    }

    pub fn logs(ctx: Ctx, self: Backend, name: []const u8, args: []const []const u8) u8 {
        return switch (self) {
            .docker => |r| docker.dockerLogs(ctx, docker.config(ctx, r), name, args),
            .datum => |d| datum.datumLogs(ctx, d, name, args),
        };
    }

    pub fn rm(ctx: Ctx, self: Backend, name: []const u8) u8 {
        return switch (self) {
            .docker => docker.dockerRm(ctx, name),
            .datum => |d| datum.datumRm(ctx, d, name),
        };
    }
};

/// The backend named on the command line (`loadBackend`).
pub fn loadBackend(ctx: Ctx, root: []const u8, which: []const u8) Backend {
    if (std.mem.eql(u8, which, "docker")) return .{ .docker = docker.containerRuntime(ctx) };
    if (std.mem.eql(u8, which, "datum")) return .{ .datum = datum.config(ctx, root) };
    util.dief("unknown backend '{s}' (docker or datum)", .{which});
}

/// The backend a session was made with, read from its `backend` file;
/// sessions made on another machine are adopted from Datum (`sessionBackend`).
pub fn sessionBackend(ctx: Ctx, root: []const u8, name: []const u8) Backend {
    const which = session.sessionBackend(ctx, name);
    return loadBackend(ctx, root, which);
}

pub const usage =
    \\yolo: run coding agents in named, isolated sessions, locally (docker or
    \\podman) or on Datum Compute. Each session runs one harness's image: claude
    \\(default), gemini, codex, opencode or pi.
    \\
    \\  yolo new NAME [--backend docker|datum] [--agent HARNESS] [backend options]
    \\                                    create a session and wait until it's ready
    \\  yolo attach NAME [args...]        shell as drewr, or run a command (alias: ssh)
    \\  yolo ls [--full]                  list sessions (--full: whole image references)
    \\  yolo logs NAME [args...]          session logs
    \\  yolo rm NAME                      save workspaces, then delete the session
    \\  yolo build HARNESS... [--backend docker|datum] [--class CLASS]
    \\                                    build images (datum: on the EC2 build box,
    \\                                    for --class unikernel or general-purpose)
    \\  yolo sync-pins                    pin image/flake.lock to the dotfiles' revisions
    \\  yolo version                      which yolo this is (compiled build, or the checkout's commit)
    \\  yolo infra buildbox|meta CMD      the EC2 build box and the shared home's metadata host:
    \\                                    launch [REV] | ticket | ipv6 | start | stop | status | terminate,
    \\                                    and for the build box, tunnel [PORT]
    \\
    \\The backend defaults to $YOLO_BACKEND, else docker; after `new`, each session
    \\remembers its own. Backend options for `new`:
    \\  docker  -v HOST:CONTAINER[:ro]    bind-mount a directory (repeatable)
    \\  datum   --key PUBKEY_FILE         authorize this key instead of the agent's
    \\          --no-home                 private, ephemeral HOME, not the shared home
    \\          --class unikernel|general-purpose
    \\                                    runtime class (default $YOLO_CLASS, else unikernel)
    \\Session state lives in $YOLO_STATE (~/.local/state/yolo/sessions).
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The Io owns the threads and buffers behind every file, socket and child
    // process: give it a real allocator (failing ones break spawn).
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();
    util.io_global = io;

    var env = try std.process.Environ.createMap(init.environ, arena);
    const args = try init.args.toSlice(arena);
    return run(.{
        .io = io,
        .gpa = arena,
        .arena = arena,
        .env = &env,
    }, args);
}

pub fn run(ctx: Ctx, args: []const [:0]const u8) u8 {
    const root = yoloRoot(ctx);
    const argv: []const []const u8 = args;
    const rest = if (argv.len > 1) argv[1..] else argv[0..0];

    const first = if (rest.len > 0) rest[0] else "";
    const is_help = isHelp(first);
    const is_version = isVersion(first);
    if (!is_help and !is_version) session.migrateAgentSandboxState(ctx);

    if (rest.len > 0 and std.mem.eql(u8, first, "new")) return cmdNew(ctx, root, rest[1..]);
    if (rest.len > 0 and (std.mem.eql(u8, first, "attach") or std.mem.eql(u8, first, "ssh"))) return cmdAttach(ctx, root, rest[1..]);
    if (rest.len == 1 and std.mem.eql(u8, first, "ls")) return cmdLs(ctx, root, false);
    if (rest.len == 2 and std.mem.eql(u8, first, "ls") and std.mem.eql(u8, rest[1], "--full")) return cmdLs(ctx, root, true);
    if (rest.len > 0 and std.mem.eql(u8, first, "logs")) return cmdLogs(ctx, root, rest[1..]);
    if (rest.len == 2 and std.mem.eql(u8, first, "rm")) return cmdRm(ctx, root, rest[1]);
    if (rest.len > 0 and std.mem.eql(u8, first, "build")) return cmdBuild(ctx, root, rest[1..]);
    if (rest.len == 1 and std.mem.eql(u8, first, "sync-pins")) return images.syncPins(ctx, root);
    if (rest.len > 0 and std.mem.eql(u8, first, "infra")) return infra.cmd(ctx, root, rest[1..]);
    if (rest.len == 1 and is_version) {
        util.say(std.fmt.allocPrint(ctx.arena, "{s}", .{versionLine(ctx, root)}) catch "");
        return 0;
    }
    if (rest.len == 1 and is_help) {
        // `usage` ends with a newline; the blank line before Version is the
        // Haskell's `\nVersion: ...`, not an extra line after the usage text.
        util.outRaw(usage);
        util.say(std.fmt.allocPrint(ctx.arena, "\nVersion: {s}", .{versionLine(ctx, root)}) catch "");
        return 0;
    }
    util.errPrint("{s}", .{usage});
    return 2;
}

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "help") or std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help");
}

fn isVersion(a: []const u8) bool {
    return std.mem.eql(u8, a, "version") or std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V");
}

pub fn versionLine(ctx: Ctx, root: []const u8) []const u8 {
    if (options.version.len != 0)
        return std.fmt.allocPrint(ctx.arena, "yolo {s} ({s}, compiled)", .{ options.version, options.date }) catch "yolo ?";
    const r = util.capture(ctx, &.{ "git", "-C", root, "describe", "--always", "--dirty", "--abbrev=7", "--match=^" }, .{}) catch
        return std.fmt.allocPrint(ctx.arena, "yolo (script, {s})", .{root}) catch "yolo ?";
    if (r.term != .exited or r.code != 0)
        return std.fmt.allocPrint(ctx.arena, "yolo (script, {s})", .{root}) catch "yolo ?";
    return std.fmt.allocPrint(ctx.arena, "yolo {s} (script, {s})", .{ util.trim(r.stdout), root }) catch "yolo ?";
}

pub fn yoloRoot(ctx: Ctx) []const u8 {
    return ctx.envNonEmpty("YOLO_ROOT") orelse options.root;
}

pub fn needCheckout(root: []const u8, what: []const u8) void {
    if (std.mem.startsWith(u8, root, "/nix/store/"))
        util.dief("{s} updates image/ in the repository; run it from a yolo checkout or set YOLO_ROOT to one", .{what});
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmdNew(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    if (rest.len == 0) util.die("usage: yolo new NAME [--backend docker|datum] [--agent HARNESS] [options]");
    const name = rest[0];
    var backend = ctx.opt("BACKEND", "docker");
    var harness = ctx.opt("AGENT", "claude");
    var i: usize = 1;
    var extra: std.ArrayList([]const u8) = .empty;
    while (i < rest.len) {
        if (std.mem.eql(u8, rest[i], "--backend") and i + 1 < rest.len) {
            backend = rest[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, rest[i], "--agent") and i + 1 < rest.len) {
            harness = rest[i + 1];
            i += 2;
        } else {
            extra.append(ctx.arena, rest[i]) catch unreachable;
            i += 1;
        }
    }
    session.checkHarness(harness);
    _ = session.dir(ctx, name);
    const b = loadBackend(ctx, root, backend);
    return Backend.new(ctx, b, root, name, harness, extra.items);
}

fn cmdAttach(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    if (rest.len == 0) util.die("usage: yolo attach NAME [args...]");
    const name = rest[0];
    const b = sessionBackend(ctx, root, name);
    return Backend.attach(ctx, b, name, rest[1..]);
}

fn cmdLogs(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    if (rest.len == 0) util.die("usage: yolo logs NAME [args...]");
    const name = rest[0];
    const b = sessionBackend(ctx, root, name);
    return Backend.logs(ctx, b, name, rest[1..]);
}

fn cmdRm(ctx: Ctx, root: []const u8, name: []const u8) u8 {
    const b = sessionBackend(ctx, root, name);
    return Backend.rm(ctx, b, name);
}

fn cmdLs(ctx: Ctx, root: []const u8, full: bool) u8 {
    // Datum is the source of truth for datum sessions: bring the local state
    // in line with it first, wherever each session was made.
    const has_datumctl = util.findExecutable(ctx, "datumctl") != null;
    var items: ?[]const json.Value = null;
    if (has_datumctl) items = datum.datumSync(ctx);
    const st = session.state(ctx);
    const names = util.listDir(ctx, st);
    var dirs: std.ArrayList([]const u8) = .empty;
    for (names) |n| {
        if (util.dirExists(ctx, util.join(ctx, &.{ st, n }))) dirs.append(ctx.arena, n) catch {};
    }
    // The fixed-width table the Haskell prints (printf "%-20s %-8s ...").
    var backends: std.ArrayList([]const u8) = .empty;
    var has_datum = false;
    util.printTableRow("NAME", "BACKEND", "HARNESS", "CLASS", "STATE");
    for (dirs.items) |n| {
        const b = util.readMeta(ctx, util.join(ctx, &.{ st, n, "backend" }), "?");
        const h = util.readMeta(ctx, util.join(ctx, &.{ st, n, "harness" }), "?");
        const c = util.readMeta(ctx, util.join(ctx, &.{ st, n, "class" }), "-");
        const s = util.readMeta(ctx, util.join(ctx, &.{ st, n, "state" }), "-");
        util.printTableRow(n, b, h, c, s);
        if (std.mem.eql(u8, b, "datum")) has_datum = true;
        // Record unique non-? non-datum backends (the datum table comes last).
        var seen = false;
        if (!std.mem.eql(u8, b, "?") and !std.mem.eql(u8, b, "datum")) {
            for (backends.items) |x| {
                if (std.mem.eql(u8, x, b)) seen = true;
            }
            if (!seen) backends.append(ctx.arena, b) catch {};
        }
    }
    for (backends.items) |b| {
        // Each backend's own listing, introduced by a blank line and "== NAME".
        util.sayf("\n== {s}", .{b});
        _ = lsBackend(ctx, root, b, full);
    }
    if (has_datum and !has_datumctl) util.warn("datumctl isn't in PATH, so the datum sessions can't be checked", .{});
    if (items) |it| datum.datumTable(ctx, full, it);
    return 0;
}

/// List one backend's sessions for `ls`. Unlike `loadBackend`, this must not
/// need a working runtime: the docker backend lists what each session
/// recorded and reports a runtime it can't find, as the Haskell does.
fn lsBackend(ctx: Ctx, root: []const u8, which: []const u8, full: bool) u8 {
    if (std.mem.eql(u8, which, "docker")) return docker.dockerLs(ctx);
    if (std.mem.eql(u8, which, "datum")) return datum.datumLs(ctx, datum.config(ctx, root), full);
    util.dief("unknown backend '{s}' (docker or datum)", .{which});
}

fn cmdBuild(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    var backend = ctx.opt("BACKEND", "docker");
    var cls: ?[]const u8 = null;
    var hs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) {
        if (std.mem.eql(u8, rest[i], "--backend") and i + 1 < rest.len) {
            backend = rest[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, rest[i], "--class") and i + 1 < rest.len) {
            cls = rest[i + 1];
            i += 2;
        } else {
            hs.append(ctx.arena, rest[i]) catch unreachable;
            i += 1;
        }
    }
    for (hs.items) |h| session.checkHarness(h);
    if (hs.items.len == 0) util.die("usage: yolo build HARNESS... [--backend docker|datum] [--class CLASS]");
    if (std.mem.eql(u8, backend, "datum")) {
        const c = cls orelse "unikernel";
        return datum.buildDatum(ctx, root, c, hs.items);
    }
    if (std.mem.eql(u8, backend, "docker")) {
        if (cls != null) util.die("--class is for the datum backend");
        return docker.buildAll(ctx, root, hs.items);
    }
    util.dief("unknown backend '{s}'", .{backend});
}

test {
    _ = util;
    _ = keys;
    _ = session;
    _ = infra;
    _ = images;
    _ = docker;
    _ = @import("golden_test.zig");
}
