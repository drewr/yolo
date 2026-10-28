//! The docker backend: long-lived local containers (podman, colima or docker)
//! running the same per-harness image as Datum, in local mode.
//!
//! - Container yolo-NAME, image yolo/HARNESS:local (built on first use, or
//!   with `yolo build HARNESS`).
//! - HOME is $YOLO_DOCKER_HOME (~/.local/share/yolo/home), shared by every
//!   docker session and kept across `yolo rm`. The login user takes your uid.
//! - Provider keys: $YOLO_PROVIDERS_ENV (~/.config/yolo/providers.env;
//!   KEY=value lines, keep it 0600), if it exists.
//! - Git: GIT_NAME, GIT_EMAIL, GIT_SIGNING_KEY and GITHUB_TOKEN are passed in.
//! - SSH agent: while you're attached, a socat relay in the session directory
//!   connects the container to your current $SSH_AUTH_SOCK
//!   (YOLO_FORWARD_AGENT=0 turns it off). Podman and colima on macOS can't
//!   share sockets with the VM (VirtioFS), so there, or whenever
//!   SSH_PRIVATE_KEY_FILE (a key path) or SSH_PRIVATE_KEY (base64 key) is set,
//!   the key is mounted read-only instead and loaded into an agent inside the
//!   session. It must have no passphrase.
//! - ~/.ssh/allowed_signers, if present, is copied in for git signature checks.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

const util = @import("util.zig");
const session = @import("session.zig");
const Ctx = util.Ctx;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// A container runtime: the executable (a store path, when it came from nix),
/// whether it runs in a VM that can't share host sockets, and the docker
/// context it needs, if any. A session keeps the one it was made with in its
/// `runtime` file, so later commands don't depend on what PATH has.
pub const Runtime = struct {
    exe: []const u8,
    vm: bool,
    context: ?[]const u8,

    pub fn eql(a: Runtime, b: Runtime) bool {
        const same_context = if (a.context) |ca| (if (b.context) |cb| mem.eql(u8, ca, cb) else false) else b.context == null;
        return mem.eql(u8, a.exe, b.exe) and a.vm == b.vm and same_context;
    }
};

pub fn image(allocator: mem.Allocator, harness: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "yolo/{s}:local", .{harness});
}

pub fn containerName(allocator: mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "yolo-{s}", .{name});
}

/// The `runtime` file's contents: executable, vm or -, context or -
/// (`writeRuntime`).
pub fn runtimeFile(allocator: mem.Allocator, r: Runtime) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{
        r.exe,
        if (r.vm) "vm" else "-",
        r.context orelse "-",
    });
}

/// A `runtime` file's contents back to a Runtime (`readRuntime`): exactly
/// three lines, the first non-empty.
pub fn parseRuntime(text: []const u8) ?Runtime {
    var lines: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = mem.splitScalar(u8, text, '\n');
    while (n < 3) : (n += 1) {
        lines[n] = it.next() orelse return null;
    }
    if (lines[0].len == 0) return null;
    return .{
        .exe = lines[0],
        .vm = mem.eql(u8, lines[1], "vm"),
        .context = if (mem.eql(u8, lines[2], "-")) null else lines[2],
    };
}

/// `-v HOST:CONTAINER[:ro]` with HOST made absolute (`dockerNew`'s parser);
/// the host path must exist. Dies on anything else.
pub fn volumeSpec(ctx: Ctx, spec: []const u8) []const u8 {
    const colon = mem.indexOfScalar(u8, spec, ':') orelse
        util.dief("docker: {s} is not HOST:CONTAINER", .{spec});
    const host = spec[0..colon];
    if (!util.exists(ctx, host)) util.dief("docker: {s} does not exist", .{host});
    const real = util.realPath(ctx, host) orelse util.dief("docker: can't resolve {s}", .{host});
    return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ real, spec[colon..] }) catch util.die("out of memory");
}

/// Whether the agent relay can work: podman machines and colima on macOS
/// share host files over VirtioFS, which can't carry Unix sockets.
pub fn noSocketRelay(d: Docker) bool {
    return d.rt.vm;
}

/// The zsh command run in the container: a login shell, or the words joined
/// (`unwords`) as one `-lc` script.
pub fn attachCommand(allocator: mem.Allocator, args: []const []const u8) ![]const []const u8 {
    if (args.len == 0) return &.{ "zsh", "-l" };
    const script = try mem.join(allocator, " ", args);
    return try allocator.dupe([]const u8, &.{ "zsh", "-lc", script });
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

pub const Docker = struct {
    rt: Runtime,
    home: []const u8,
    providers_env: []const u8,
    forward_agent: bool,
    user: []const u8,
};

/// Settings around a runtime, which also takes effect: its docker context
/// (`dockerConfig`).
pub fn config(ctx: Ctx, runtime: Runtime) Docker {
    if (runtime.context) |c| ctx.setEnv("DOCKER_CONTEXT", c);
    const home = util.homeDir(ctx);
    const data_home = ctx.envNonEmpty("XDG_DATA_HOME") orelse util.join(ctx, &.{ home, ".local/share" });
    const config_home = util.configHome(ctx);
    const home_default = if (builtin.os.tag == .macos)
        util.join(ctx, &.{ home, "Library/Application Support/yolo/home" })
    else
        util.join(ctx, &.{ data_home, "yolo/home" });
    return .{
        .rt = runtime,
        .home = ctx.opt("DOCKER_HOME", home_default),
        .providers_env = ctx.opt("PROVIDERS_ENV", util.join(ctx, &.{ config_home, "yolo/providers.env" })),
        .forward_agent = mem.eql(u8, ctx.opt("FORWARD_AGENT", "1"), "1"),
        .user = ctx.opt("USER", "drewr"),
    };
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// $YOLO_RUNTIME (or $CONTAINER_RUNTIME), else the first of podman, colima
/// (each from PATH, or else nixpkgs; colima through the docker CLI and its
/// docker context) and docker that is up (`containerRuntimeMaybe`).
pub fn containerRuntimeMaybe(ctx: Ctx) ?Runtime {
    if (ctx.firstEnv(&.{ "YOLO_RUNTIME", "CONTAINER_RUNTIME" })) |r| {
        return .{ .exe = r, .vm = builtin.os.tag == .macos and mem.eql(u8, std.fs.path.basename(r), "podman"), .context = null };
    }
    if (podmanRuntime(ctx)) |r| return r;
    if (colimaRuntime(ctx)) |r| return r;
    return dockerRuntime(ctx);
}

pub fn containerRuntime(ctx: Ctx) Runtime {
    return containerRuntimeMaybe(ctx) orelse
        util.die("docker: no podman, colima or docker found (podman and colima must be running)");
}

fn podmanRuntime(ctx: Ctx) ?Runtime {
    const p = findOrNix(ctx, "podman", "podman") orelse return null;
    if (util.quiet(ctx, &.{ p, "info" }) != 0) return null;
    return .{ .exe = p, .vm = builtin.os.tag == .macos, .context = null };
}

/// Colima runs the docker daemon in a VM; the docker CLI reaches it through
/// its docker context.
fn colimaRuntime(ctx: Ctx) ?Runtime {
    const c = findOrNix(ctx, "colima", "colima") orelse return null;
    if (util.quiet(ctx, &.{ c, "status" }) != 0) return null;
    const d = findOrNix(ctx, "docker-client", "docker") orelse return null;
    return .{ .exe = d, .vm = builtin.os.tag == .macos, .context = "colima" };
}

fn dockerRuntime(ctx: Ctx) ?Runtime {
    const d = util.findExecutable(ctx, "docker") orelse return null;
    return .{ .exe = d, .vm = false, .context = null };
}

/// EXE from PATH, else from nixpkgs#PKG when nix is there to build it
/// (`findOrNix`).
fn findOrNix(ctx: Ctx, pkg: []const u8, exe: []const u8) ?[]const u8 {
    if (util.findExecutable(ctx, exe)) |_| return exe;
    if (util.findExecutable(ctx, "nix") == null) return null;
    util.warn("no {s} in PATH; trying nixpkgs#{s}", .{ exe, pkg });
    const r = util.capture(ctx, &.{ "nix", "--extra-experimental-features", "nix-command flakes", "build", "--no-link", "--print-out-paths", (std.fmt.allocPrint(ctx.arena, "nixpkgs#{s}", .{pkg}) catch return null) }, .{}) catch return null;
    if (r.term != .exited or r.code != 0) return null;
    var it = mem.tokenizeScalar(u8, r.stdout, '\n');
    while (it.next()) |out| {
        const p = std.fmt.allocPrint(ctx.arena, "{s}/bin/{s}", .{ util.trim(out), exe }) catch continue;
        if (util.fileExists(ctx, p)) return p;
    }
    return null;
}

/// Sessions keep the runtime they were made with; failing that (older
/// sessions), the one found now (`sessionDocker`).
fn sessionDocker(ctx: Ctx, name: []const u8) Docker {
    const dir = session.dir(ctx, name);
    if (readRuntime(ctx, dir)) |r| return config(ctx, r);
    return config(ctx, containerRuntime(ctx));
}

fn writeRuntime(ctx: Ctx, dir: []const u8, r: Runtime) void {
    const p = util.join(ctx, &.{ dir, "runtime" });
    util.writeFileOrDie(ctx, p, runtimeFile(ctx.arena, r) catch "");
}

fn readRuntime(ctx: Ctx, dir: []const u8) ?Runtime {
    const text = util.readFileMaybe(ctx, util.join(ctx, &.{ dir, "runtime" })) orelse return null;
    return parseRuntime(text);
}

/// `yolo/HARNESS:local` from image/, with the same Dockerfile Datum uses
/// (`dockerBuild`). Dies when the build fails.
pub fn dockerBuild(ctx: Ctx, root: []const u8, d: Docker, harness: []const u8) void {
    util.errPrint("yolo: building {s}\n", .{image(ctx.arena, harness) catch harness});
    const code = util.inherit(ctx, &.{
        d.rt.exe,                            "build",
        "--build-arg",                       std.fmt.allocPrint(ctx.arena, "HARNESS={s}", .{harness}) catch "",
        "-t",                                image(ctx.arena, harness) catch "",
        "-f",                                util.join(ctx, &.{ root, "image/Dockerfile" }),
        util.join(ctx, &.{ root, "image" }),
    });
    if (code != 0) util.dief("docker: could not build {s}", .{image(ctx.arena, harness) catch harness});
}

/// `yolo build HARNESS... --backend docker`: one image per harness.
pub fn buildAll(ctx: Ctx, root: []const u8, harnesses: []const []const u8) u8 {
    const d = config(ctx, containerRuntime(ctx));
    for (harnesses) |h| dockerBuild(ctx, root, d, h);
    return 0;
}

/// The containers of every docker session, once per runtime the sessions use
/// (`dockerLs`). Sessions from before runtimes were recorded use the one
/// found now.
pub fn dockerLs(ctx: Ctx) u8 {
    const mine = session.localSessions(ctx, "docker");
    var recorded: std.ArrayList(?Runtime) = .empty;
    var any_missing = false;
    for (mine) |n| {
        const r = readRuntime(ctx, util.join(ctx, &.{ session.state(ctx), n }));
        if (r == null) any_missing = true;
        recorded.append(ctx.arena, r) catch {};
    }
    const found = if (any_missing) containerRuntimeMaybe(ctx) else null;
    var used: std.ArrayList(Runtime) = .empty;
    for (recorded.items) |r| {
        const choice = r orelse found orelse continue;
        var seen = false;
        for (used.items) |u| if (u.eql(choice)) {
            seen = true;
        };
        if (!seen) used.append(ctx.arena, choice) catch {};
    }
    if (used.items.len == 0) util.errPrint("yolo: no container runtime found to list the docker sessions\n", .{});
    for (used.items) |r| {
        util.sayf("runtime: {s}", .{r.exe});
        const d = config(ctx, r);
        _ = util.inherit(ctx, &.{
            d.rt.exe,                                    "ps",          "-a",
            "--filter",                                  "name=^yolo-", "--format",
            "table {{.Names}}\t{{.Status}}\t{{.Image}}",
        });
    }
    return 0;
}

pub fn dockerNew(ctx: Ctx, root: []const u8, runtime: Runtime, d: Docker, name: []const u8, harness: []const u8, opts: []const []const u8) u8 {
    // Mounts first: nothing is created if an option is bad.
    var mounts: std.ArrayList([]const u8) = .empty;
    for (opts) |o| {
        if (mem.eql(u8, o, "-v") or mem.eql(u8, o, "--volume")) continue;
        if (mem.startsWith(u8, o, "-")) util.dief("docker: unknown option {s}", .{o});
        appendMaybe(&mounts, ctx, "-v");
        appendMaybe(&mounts, ctx, volumeSpec(ctx, o));
    }

    // The session exists from here on, so `yolo ls` shows it while the image
    // builds; `state` says what it's doing, until it's ready.
    const dir = session.create(ctx, name, "docker", harness);
    writeRuntime(ctx, dir, runtime);
    util.errPrint("yolo: runtime {s}\n", .{runtime.exe});
    const img = image(ctx.arena, harness) catch "";
    if (util.quiet(ctx, &.{ d.rt.exe, "image", "inspect", img }) != 0) {
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "state" }), "building\n");
        dockerBuild(ctx, root, d, harness);
    }
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "state" }), "starting\n");
    util.createDirPath(ctx, d.home) catch |e| util.dief("can't create {s}: {t}", .{ d.home, e });
    util.createDirPath(ctx, util.join(ctx, &.{ dir, "agent" })) catch |e| util.dief("can't create {s}: {t}", .{ dir, e });

    // SSH: relay the host agent at attach, or inject a key (see above).
    var key_mount: std.ArrayList([]const u8) = .empty;
    const key_b64 = ctx.envNonEmpty("SSH_PRIVATE_KEY");
    const key_file = ctx.envNonEmpty("SSH_PRIVATE_KEY_FILE");
    if (key_b64) |b64| {
        const stripped = blk: {
            var b: std.ArrayList(u8) = .empty;
            for (b64) |c| if (!std.ascii.isWhitespace(c)) b.append(ctx.arena, c) catch {};
            break :blk b.items;
        };
        const key = util.b64decode(ctx.arena, stripped) catch
            util.dief("docker: SSH_PRIVATE_KEY is not valid base64", .{});
        const key_path = util.join(ctx, &.{ dir, "ssh_key" });
        util.writeFile(ctx, key_path, key, @fromBackingInt(@intCast(0o600))) catch |e|
            util.dief("can't write {s}: {t}", .{ key_path, e });
        appendSlice(&key_mount, ctx, &.{ "-v", std.fmt.allocPrint(ctx.arena, "{s}:/run/yolo-key/id:ro", .{key_path}) catch "" });
    } else if (key_file) |f| {
        if (!util.isReadable(ctx, f)) util.dief("docker: cannot read {s}", .{f});
        const real = util.realPath(ctx, f) orelse util.dief("docker: can't resolve {s}", .{f});
        appendSlice(&key_mount, ctx, &.{ "-v", std.fmt.allocPrint(ctx.arena, "{s}:/run/yolo-key/id:ro", .{real}) catch "" });
    } else if (noSocketRelay(d)) {
        util.errPrint("yolo: {s} (a VM on macOS) can't relay the SSH agent; set SSH_PRIVATE_KEY_FILE for SSH in the session\n", .{std.fs.path.basename(d.rt.exe)});
    }
    if (key_mount.items.len != 0) util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "ssh_key_mode" }), "");

    // Copied rather than bind-mounted: it is often a symlink into /nix/store,
    // which a podman machine VM can't see.
    var signers: std.ArrayList([]const u8) = .empty;
    const allowed = util.join(ctx, &.{ util.homeDir(ctx), ".ssh/allowed_signers" });
    if (util.fileExists(ctx, allowed)) {
        const dest = util.join(ctx, &.{ dir, "allowed_signers" });
        util.copyFile(ctx, allowed, dest) catch |e| util.dief("can't copy {s}: {t}", .{ allowed, e });
        appendSlice(&signers, ctx, &.{ "-v", std.fmt.allocPrint(ctx.arena, "{s}:/etc/ssh/allowed_signers:ro", .{dest}) catch "" });
    }

    // Environment.
    var env: std.ArrayList([]const u8) = .empty;
    const uid = std.fmt.allocPrint(ctx.arena, "HOST_UID={d}", .{util.uid()}) catch "";
    const gid = std.fmt.allocPrint(ctx.arena, "HOST_GID={d}", .{util.gid()}) catch "";
    appendSlice(&env, ctx, &.{ "-e", "YOLO_MODE=local", "-e", std.fmt.allocPrint(ctx.arena, "SESSION_NAME={s}", .{name}) catch "", "-e", uid, "-e", gid });
    for ([_][]const u8{ "GIT_NAME", "GIT_EMAIL", "GIT_SIGNING_KEY", "GITHUB_TOKEN" }) |v| {
        if (ctx.envNonEmpty(v) != null) appendSlice(&env, ctx, &.{ "-e", v });
    }
    if (util.fileExists(ctx, d.providers_env)) {
        const text = util.readFileMaybe(ctx, d.providers_env) orelse "";
        var names: std.ArrayList(u8) = .empty;
        var it = mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const k = util.providerName(line) orelse continue;
            if (names.items.len != 0) names.append(ctx.arena, ' ') catch {};
            names.appendSlice(ctx.arena, k) catch {};
        }
        appendSlice(&env, ctx, &.{
            "--env-file",
            d.providers_env,
            "-e",
            std.fmt.allocPrint(ctx.arena, "PROVIDER_KEYS={s}", .{names.items}) catch "",
        });
    }

    const cname = containerName(ctx.arena, name) catch name;
    var argv: std.ArrayList([]const u8) = .empty;
    appendSlice(&argv, ctx, &.{ d.rt.exe, "run", "-d", "--name", cname, "--hostname", name });
    appendSlice(&argv, ctx, env.items);
    appendSlice(&argv, ctx, &.{ "-v", std.fmt.allocPrint(ctx.arena, "{s}:/home/agent", .{d.home}) catch "" });
    appendSlice(&argv, ctx, &.{ "-v", std.fmt.allocPrint(ctx.arena, "{s}:/run/yolo-agent", .{util.join(ctx, &.{ dir, "agent" })}) catch "" });
    appendSlice(&argv, ctx, key_mount.items);
    appendSlice(&argv, ctx, signers.items);
    appendSlice(&argv, ctx, mounts.items);
    appendMaybe(&argv, ctx, img);
    if (util.quiet(ctx, argv.items) != 0) util.dief("docker: could not start {s}", .{cname});

    util.errPrint("started {s} ({s}: {s}); waiting for init...\n", .{ cname, harness, img });
    const t0 = util.monoNow(ctx);
    while (true) {
        const r = util.capture(ctx, &.{ d.rt.exe, "logs", cname }, .{}) catch util.Result{ .term = .exited, .code = 1, .stdout = "", .stderr = "" };
        if (mem.indexOf(u8, r.stdout, "[agent] ready") != null or mem.indexOf(u8, r.stderr, "[agent] ready") != null) break;
        if (util.secondsSince(ctx, t0) >= 120) {
            util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "state" }), "not ready\n");
            util.dief("init not ready after 2 min; try: yolo logs {s}", .{name});
        }
        util.sleep(ctx, 1000);
    }
    util.removeTree(ctx, util.join(ctx, &.{ dir, "state" }));
    util.errPrint("ready after {d}s: yolo attach {s}\n", .{ util.secondsSince(ctx, t0), name });
    return 0;
}

pub fn dockerAttach(ctx: Ctx, d: Docker, name: []const u8, args: []const []const u8) u8 {
    const dir = session.dir(ctx, name);
    const tty = util.terminals(ctx);
    const key_mode = util.fileExists(ctx, util.join(ctx, &.{ dir, "ssh_key_mode" }));
    const host_sock = ctx.envNonEmpty("SSH_AUTH_SOCK");
    const sock_ok = if (host_sock) |s| util.isSocket(ctx, s) else false;
    const term = ctx.envNonEmpty("TERM") orelse "xterm-256color";
    const sock = util.join(ctx, &.{ dir, "agent/agent.sock" });

    // The session's own agent holding an injected key, or else the current SSH
    // agent, relayed only while attached.
    var agent_env: std.ArrayList([]const u8) = .empty;
    var relay: std.process.Child = undefined;
    var have_relay = false;
    if (key_mode) {
        appendSlice(&agent_env, ctx, &.{ "-e", "SSH_AUTH_SOCK=/run/yolo-ssh/agent.sock" });
    } else if (host_sock) |hs| {
        if (d.forward_agent and sock_ok and !noSocketRelay(d)) {
            util.removeTree(ctx, sock);
            const relay_argv = [_][]const u8{
                "socat",
                std.fmt.allocPrint(ctx.arena, "UNIX-LISTEN:{s},fork,mode=600", .{sock}) catch "",
                std.fmt.allocPrint(ctx.arena, "UNIX-CONNECT:{s}", .{hs}) catch "",
            };
            if (util.spawnBackground(ctx, &relay_argv)) |child| {
                relay = child;
                have_relay = true;
            }
            var n: usize = 0;
            while (!util.exists(ctx, sock) and n < 50) : (n += 1) util.sleep(ctx, 100);
            appendSlice(&agent_env, ctx, &.{ "-e", "SSH_AUTH_SOCK=/run/yolo-agent/agent.sock" });
        }
    }
    defer {
        if (have_relay) relay.kill(ctx.io);
        util.removeTree(ctx, sock);
    }

    const login = [_][]const u8{ "zsh", "-l" };
    const zsh = attachCommand(ctx.arena, args) catch &login;
    var argv: std.ArrayList([]const u8) = .empty;
    appendSlice(&argv, ctx, &.{
        d.rt.exe,                                                    "exec",
        if (tty) "-it" else "-i",                                    "-u",
        d.user,                                                      "-w",
        "/home/agent",                                               "-e",
        "SHELL=/bin/zsh",                                            "-e",
        std.fmt.allocPrint(ctx.arena, "TERM={s}", .{term}) catch "",
    });
    appendSlice(&argv, ctx, agent_env.items);
    appendMaybe(&argv, ctx, containerName(ctx.arena, name) catch name);
    appendSlice(&argv, ctx, zsh);
    return util.inherit(ctx, argv.items);
}

pub fn dockerLogs(ctx: Ctx, d: Docker, name: []const u8, args: []const []const u8) u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    appendSlice(&argv, ctx, &.{ d.rt.exe, "logs" });
    appendSlice(&argv, ctx, args);
    appendMaybe(&argv, ctx, containerName(ctx.arena, name) catch name);
    return util.inherit(ctx, argv.items);
}

pub fn dockerRm(ctx: Ctx, name: []const u8) u8 {
    const d = sessionDocker(ctx, name);
    const dir = session.dir(ctx, name);
    // Workspaces are bind mounts and HOME is on the host: nothing to save.
    const cname = containerName(ctx.arena, name) catch name;
    if (util.quiet(ctx, &.{ d.rt.exe, "rm", "-f", cname }) == 0)
        util.errPrint("removed {s}\n", .{cname});
    util.removeTree(ctx, dir);
    return 0;
}

/// Appending to an argument list can't fail in practice (the arena is the
/// process's), so these die instead of threading an error through a command.
fn appendMaybe(list: *std.ArrayList([]const u8), ctx: Ctx, item: []const u8) void {
    list.append(ctx.arena, item) catch util.die("out of memory");
}

fn appendSlice(list: *std.ArrayList([]const u8), ctx: Ctx, items: []const []const u8) void {
    list.appendSlice(ctx.arena, items) catch util.die("out of memory");
}
