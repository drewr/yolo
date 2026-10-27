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
const keys = @import("keys.zig");
const session = @import("session.zig");
const docker = @import("docker.zig");
const datum = @import("datum.zig");
const infra = @import("infra.zig");
const images = @import("images.zig");

const Ctx = util.Ctx;

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

/// main returns the exit code so the same entry point works for the binary
/// (std.process.Init) and the test runner (Init.Minimal, where only the
/// imported tests matter).
pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
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

/// Dispatch the command line; returns the process's exit code.
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
        util.say("{s}", .{versionLine(ctx, root)});
        return 0;
    }
    if (rest.len == 1 and is_help) {
        util.say("{s}", .{usage});
        util.say("\nVersion: {s}", .{versionLine(ctx, root)});
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

/// The commit and date the flake built this yolo from (empty for a plain
/// `zig build`), else the checkout's.
pub fn versionLine(ctx: Ctx, root: []const u8) []const u8 {
    if (options.version.len != 0)
        return std.fmt.allocPrint(ctx.arena, "yolo {s} ({s}, compiled)", .{ options.version, options.date }) catch "yolo ?";
    const r = util.capture(ctx, &.{ "git", "-C", root, "describe", "--always", "--dirty", "--abbrev=7", "--match=^" }, .{}) catch
        return std.fmt.allocPrint(ctx.arena, "yolo (script, {s})", .{root}) catch "yolo ?";
    if (r.term != .exited or r.code != 0)
        return std.fmt.allocPrint(ctx.arena, "yolo (script, {s})", .{root}) catch "yolo ?";
    return std.fmt.allocPrint(ctx.arena, "yolo {s} (script, {s})", .{ util.trim(r.stdout), root }) catch "yolo ?";
}

/// The repository: $YOLO_ROOT (the compiled yolo's wrapper defaults it to the
/// flake's source), else the build root compiled in (`zig build run` in a
/// checkout).
pub fn yoloRoot(ctx: Ctx) []const u8 {
    return ctx.envNonEmpty("YOLO_ROOT") orelse options.root;
}

/// Commands that rewrite image/ (pins, flake.lock) need a checkout, not the
/// read-only copy a compiled yolo carries.
pub fn needCheckout(root: []const u8, what: []const u8) void {
    if (std.mem.startsWith(u8, root, "/nix/store/"))
        util.dief("{s} updates image/ in the repository; run it from a yolo checkout or set YOLO_ROOT to one", .{what});
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmdNew(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    _ = ctx;
    _ = root;
    _ = rest;
    util.die("not ported yet");
}

fn cmdAttach(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    _ = ctx;
    _ = root;
    _ = rest;
    util.die("not ported yet");
}

fn cmdLogs(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    _ = ctx;
    _ = root;
    _ = rest;
    util.die("not ported yet");
}

fn cmdRm(ctx: Ctx, root: []const u8, name: []const u8) u8 {
    _ = ctx;
    _ = root;
    _ = name;
    util.die("not ported yet");
}

fn cmdLs(ctx: Ctx, root: []const u8, full: bool) u8 {
    _ = ctx;
    _ = root;
    _ = full;
    util.die("not ported yet");
}

fn cmdBuild(ctx: Ctx, root: []const u8, rest: []const []const u8) u8 {
    _ = ctx;
    _ = root;
    _ = rest;
    util.die("not ported yet");
}

test {
    _ = util;
    _ = keys;
    _ = session;
}
