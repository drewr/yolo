//! Image builds (datum): on the EC2 build box, over iroh.
//!
//! unikernel (default): `datumctl compute build` against the box's BuildKit,
//! pinned in image/images. general-purpose: a standard linux/amd64 image via
//! buildctl, pinned in image/images-general-purpose and pushed with your
//! registry login (~/.docker/config.json). Pins llm-agents and nixpkgs to the
//! dotfiles' revisions first (sync-pins). The box must be running; its ticket
//! comes from $BUILDBOX_TICKET or ~/.local/state/agent-sandbox-build
//! (yolo infra buildbox ticket). If BuildKit doesn't answer, the box is
//! started (it stops itself after 30 idle minutes) and waited for.

const std = @import("std");
const mem = std.mem;

const util = @import("util.zig");
const json = @import("json.zig");
const infra = @import("infra.zig");
const main = @import("main.zig");
const Ctx = util.Ctx;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// Every REPO@sha256:HEX in a build log, in order.
pub fn digestRefs(allocator: mem.Allocator, repo: []const u8, out: []const u8) ![]const []const u8 {
    const pre = try std.fmt.allocPrint(allocator, "{s}@sha256:", .{repo});
    var refs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (mem.indexOfPos(u8, out, i, pre)) |at| {
        const hex_start = at + pre.len;
        var end = hex_start;
        while (end < out.len and std.ascii.isHex(out[end])) end += 1;
        try refs.append(allocator, out[at..end]);
        i = at + pre.len;
    }
    return refs.items;
}

/// The last REPO@sha256:... in a build log (`lastDigestRef`).
pub fn lastDigestRef(allocator: mem.Allocator, repo: []const u8, out: []const u8) ?[]const u8 {
    const refs = digestRefs(allocator, repo, out) catch return null;
    return if (refs.len == 0) null else refs[refs.len - 1];
}

/// HARNESS's line in an images file (`pinImage`): the header when there is no
/// file yet, every other harness's line kept, HARNESS last and padded so the
/// image reference starts in column 11.
pub fn pinImageText(allocator: mem.Allocator, old: ?[]const u8, cls: []const u8, h: []const u8, ref: []const u8) ![]u8 {
    const header = try std.fmt.allocPrint(allocator, "# One pinned image per harness for the {s} class (yolo build HARNESS --backend datum --class {s}).", .{ cls, cls });
    var out: std.ArrayList(u8) = .empty;
    if (old) |text| {
        var it = mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const first = firstWord(line) orelse {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
                continue;
            };
            if (mem.eql(u8, first, h)) continue;
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    } else {
        try out.appendSlice(allocator, header);
        try out.append(allocator, '\n');
    }
    const pad = if (h.len < 9) 9 - h.len else 0;
    try out.appendSlice(allocator, h);
    try out.appendNTimes(allocator, ' ', pad);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, ref);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn firstWord(line: []const u8) ?[]const u8 {
    var it = mem.tokenizeAny(u8, line, " \t\r");
    return it.next();
}

/// The locked rev of a root input in a flake.lock (`lockedRev`).
pub fn lockedRev(allocator: mem.Allocator, lock_text: []const u8, input: []const u8) ?[]const u8 {
    const top = json.parse(allocator, lock_text) orelse return null;
    const nodes = json.object(&.{"nodes"}, top) orelse return null;
    const root_name = switch (json.at(&.{"root"}, top)) {
        .string => |s| s,
        else => return null,
    };
    const root_node = nodes.get(root_name) orelse return null;
    const inputs = json.object(&.{"inputs"}, root_node) orelse return null;
    const node_name = switch (inputs.get(input) orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const node = nodes.get(node_name) orelse return null;
    const locked = json.object(&.{"locked"}, node) orelse return null;
    return switch (locked.get("rev") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The first seven characters, for messages (`take 7`).
pub fn short(rev: []const u8) []const u8 {
    return rev[0..@min(rev.len, 7)];
}

/// The image name and tag for a class.
pub fn imageTag(allocator: mem.Allocator, registry: []const u8, h: []const u8, cls: []const u8) ![]const u8 {
    const tag = if (mem.eql(u8, cls, "general-purpose")) "gp-dev" else "dev";
    return std.fmt.allocPrint(allocator, "{s}/agent-{s}:{s}", .{ registry, h, tag });
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

fn imagesPath(ctx: Ctx, root: []const u8, cls: []const u8) []const u8 {
    return if (mem.eql(u8, cls, "general-purpose"))
        util.join(ctx, &.{ root, "image/images-general-purpose" })
    else
        util.join(ctx, &.{ root, "image/images" });
}

fn pinImage(ctx: Ctx, file: []const u8, cls: []const u8, h: []const u8, ref: []const u8) void {
    const old = if (util.exists(ctx, file)) util.readFileMaybe(ctx, file) else null;
    const text = pinImageText(ctx.arena, old, cls, h, ref) catch util.die("out of memory");
    util.writeFileOrDie(ctx, file, text);
}

/// Look HARNESS's image up in an images file (`lookupImage`: the first
/// "HARNESS IMAGE" line).
pub fn lookupImage(ctx: Ctx, file: []const u8, harness: []const u8) ?[]const u8 {
    const text = util.readFileMaybe(ctx, file) orelse return null;
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var words = mem.tokenizeAny(u8, line, " \t\r");
        const h = words.next() orelse continue;
        const img = words.next() orelse continue;
        if (mem.eql(u8, h, harness)) return ctx.arena.dupe(u8, img) catch null;
    }
    return null;
}

/// Pin image/flake.lock's llm-agents and nixpkgs to the revisions the
/// dotfiles use (d/.config/home-manager/flake.lock in the locked `dotfiles`
/// input), so the images carry the same harness versions and nixpkgs as a
/// laptop with these dotfiles. To follow newer dotfiles: nix flake update
/// dotfiles --flake image, then build (`syncPins`).
pub fn syncPins(ctx: Ctx, root: []const u8) u8 {
    main.needCheckout(root, "yolo sync-pins");
    const here = util.join(ctx, &.{ root, "image" });
    const nix = [_][]const u8{ "nix", "--extra-experimental-features", "nix-command flakes" };
    var eval: std.ArrayList([]const u8) = .empty;
    eval.appendSlice(ctx.arena, &nix) catch util.die("out of memory");
    eval.appendSlice(ctx.arena, &.{ "eval", "--raw", std.fmt.allocPrint(ctx.arena, "{s}#lib.dotfiles", .{here}) catch "" }) catch util.die("out of memory");
    const r = util.capture(ctx, eval.items, .{}) catch util.die("the nix CLI isn't in PATH");
    if (r.term != .exited or r.code != 0) util.dief("sync-pins: {s}", .{util.trim(r.stderr)});
    const dotfiles = util.trim(r.stdout);
    const dot_lock = util.readFileMaybe(ctx, util.join(ctx, &.{ dotfiles, "d/.config/home-manager/flake.lock" })) orelse
        util.die("sync-pins: can't read the dotfiles' flake.lock");
    const lock_path = util.join(ctx, &.{ here, "flake.lock" });
    const lock = util.readFileMaybe(ctx, lock_path) orelse util.die("sync-pins: can't read image/flake.lock");
    const want_a = lockedRev(ctx.arena, dot_lock, "llm-agents") orelse "?";
    const want_n = lockedRev(ctx.arena, dot_lock, "nixpkgs") orelse "?";
    const have_a = lockedRev(ctx.arena, lock, "llm-agents") orelse "?";
    const have_n = lockedRev(ctx.arena, lock, "nixpkgs") orelse "?";
    if (mem.eql(u8, want_a, have_a) and mem.eql(u8, want_n, have_n)) {
        util.sayf("sync-pins: already at the dotfiles' pins (llm-agents {s}, nixpkgs {s})", .{ short(want_a), short(want_n) });
        return 0;
    }
    var lock_cmd: std.ArrayList([]const u8) = .empty;
    lock_cmd.appendSlice(ctx.arena, &nix) catch util.die("out of memory");
    lock_cmd.appendSlice(ctx.arena, &.{
        "flake",                                                                                "lock",             here,      "--override-input",                                                            "llm-agents",
        std.fmt.allocPrint(ctx.arena, "github:numtide/llm-agents.nix/{s}", .{want_a}) catch "", "--override-input", "nixpkgs", std.fmt.allocPrint(ctx.arena, "github:nixos/nixpkgs/{s}", .{want_n}) catch "",
    }) catch util.die("out of memory");
    const lr = util.capture(ctx, lock_cmd.items, .{}) catch util.die("the nix CLI isn't in PATH");
    // Nix's own progress goes to stderr; its noise about the git tree doesn't.
    const combined = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ lr.stdout, lr.stderr }) catch "";
    var it = mem.splitScalar(u8, combined, '\n');
    while (it.next()) |line| {
        if (mem.startsWith(u8, line, "warning: Git tree")) continue;
        if (line.len != 0) util.say(line);
    }
    if (lr.term != .exited or lr.code != 0) util.die("sync-pins: nix flake lock failed");
    util.sayf("sync-pins: llm-agents {s} -> {s}, nixpkgs {s} -> {s}", .{ short(have_a), short(want_a), short(have_n), short(want_n) });
    return 0;
}

/// `yolo build HARNESS... --backend datum` (`buildDatum`).
pub fn buildDatum(ctx: Ctx, root: []const u8, cls: []const u8, hs: []const []const u8) u8 {
    main.needCheckout(root, "yolo build --backend datum");
    if (!mem.eql(u8, cls, "unikernel") and !mem.eql(u8, cls, "general-purpose"))
        util.dief("unknown class '{s}' (unikernel or general-purpose)", .{cls});
    const images = imagesPath(ctx, root, cls);
    const state = util.join(ctx, &.{ util.stateHome(ctx), "agent-sandbox-build" });
    const registry = ctx.envNonEmpty("AGENT_IMAGE_REGISTRY") orelse "ghcr.io/drewr";
    const b = infra.boxConfig(ctx, "buildbox");
    const port = ctx.envNonEmpty("BUILDBOX_PORT") orelse "12340";
    util.createDirPath(ctx, util.join(ctx, &.{ state, "logs" })) catch |e|
        util.dief("can't create {s}: {t}", .{ state, e });
    _ = syncPins(ctx, root);

    const ctx2 = util.join(ctx, &.{ root, "image" });
    const buildkit = std.fmt.allocPrint(ctx.arena, "tcp://127.0.0.1:{s}", .{port}) catch "";
    var failures: u32 = 0;

    var ticket = infra.buildboxTicket(ctx, b);
    var tries: u8 = 0;
    while (true) {
        // The tunnel has to stay up for the whole of runBuilds below; the
        // defer is scoped to the loop body by the block, so a retry opens a
        // fresh one and the old process is killed first.
        const tunnel = infra.openTunnel(ctx, port, ticket);
        const up = infra.ensureBuildkit(ctx, b, buildkit);
        if (up) {
            failures = runBuilds(ctx, b, cls, hs, images, state, registry, buildkit, ctx2);
            if (tunnel) |t| {
                var tt = t;
                tt.kill(ctx.io);
            }
            break;
        }
        if (tunnel) |t| {
            var tt = t;
            tt.kill(ctx.io);
        }
        tries += 1;
        if (tries > 1) util.die("BuildKit on the build box isn't answering (yolo infra buildbox status)");
        ticket = infra.refreshTicket(ctx, b, ticket);
    }
    return if (failures > 0) 1 else 0;
}

fn runBuilds(
    ctx: Ctx,
    b: infra.Box,
    cls: []const u8,
    hs: []const []const u8,
    images: []const u8,
    state: []const u8,
    registry: []const u8,
    buildkit: []const u8,
    ctx_dir: []const u8,
) u32 {
    _ = b;
    var failures: u32 = 0;
    for (hs) |h| {
        const log_path = util.join(ctx, &.{ state, "logs", std.fmt.allocPrint(ctx.arena, "build-{s}-{s}.log", .{ h, cls }) catch "" });
        const meta_path = util.join(ctx, &.{ state, "logs", std.fmt.allocPrint(ctx.arena, "build-{s}-{s}.json", .{ h, cls }) catch "" });
        const image = imageTag(ctx.arena, registry, h, cls) catch "";
        const repo = std.fmt.allocPrint(ctx.arena, "{s}/agent-{s}", .{ registry, h }) catch "";
        const t0 = util.monoNow(ctx);
        util.removeTree(ctx, meta_path);

        var log_file = std.Io.Dir.cwd().createFile(ctx.io, log_path, .{}) catch |e|
            util.dief("can't write {s}: {t}", .{ log_path, e });
        defer log_file.close(ctx.io);

        const code = if (mem.eql(u8, cls, "general-purpose"))
            util.logged(ctx, log_file, &.{
                "buildctl",                                                            "--addr",               buildkit,
                "build",                                                               "--progress",           "plain",
                "--frontend",                                                          "dockerfile.v0",        "--local",
                util.join(ctx, &.{ "context=", ctx_dir }),                             "--local",              util.join(ctx, &.{ "dockerfile=", ctx_dir }),
                "--opt",                                                               "platform=linux/amd64", "--opt",
                std.fmt.allocPrint(ctx.arena, "build-arg:HARNESS={s}", .{h}) catch "", "--output",             std.fmt.allocPrint(ctx.arena, "type=image,name={s},push=true", .{image}) catch "",
                "--metadata-file",                                                     meta_path,
            })
        else
            util.logged(ctx, log_file, &.{
                "datumctl",                                                  "compute", "build", "--analyze", "--push",
                "--buildkit-host",                                           buildkit,  "-o",    image,       "--build-arg",
                std.fmt.allocPrint(ctx.arena, "HARNESS={s}", .{h}) catch "", ctx_dir,
            });

        const out = util.readFileMaybe(ctx, log_path) orelse "";
        const ref: ?[]const u8 = if (code != 0) null else if (mem.eql(u8, cls, "general-purpose")) blk: {
            const m = util.readFileMaybe(ctx, meta_path) orelse break :blk null;
            const v = json.parse(ctx.arena, m) orelse break :blk null;
            const digest = json.str(&.{"containerimage.digest"}, v);
            if (digest.len == 0) break :blk null;
            break :blk std.fmt.allocPrint(ctx.arena, "{s}@{s}", .{ repo, digest }) catch null;
        } else lastDigestRef(ctx.arena, repo, out);

        const secs = util.secondsSince(ctx, t0);
        if (ref) |r| {
            pinImage(ctx, images, cls, h, r);
            util.sayf("{s}: {s} ({d}s)", .{ h, r, secs });
        } else {
            failures += 1;
            util.errPrint("{s}: FAILED after {d}s: {s} (log: {s})\n", .{ h, secs, errorLine(ctx, out), log_path });
        }
    }
    return failures;
}

/// The last log line mentioning "error", cut to 200 characters; "" if none
/// (the Haskell's `errLine`).
fn errorLine(ctx: Ctx, out: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (containsError(line)) last = line;
    }
    return ctx.arena.dupe(u8, last[0..@min(last.len, 200)]) catch "";
}

fn containsError(line: []const u8) bool {
    if (line.len < 5) return false;
    var i: usize = 0;
    while (i + 5 <= line.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(line[i .. i + 5], "error")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lastDigestRef takes the last pinned reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out =
        \\
        \\#4 exporting to image ref=ghcr.io/drewr/agent-claude@sha256:aaaa1111
        \\#5 exporting to image ref=ghcr.io/drewr/agent-claude@sha256:bbbb2222 done
    ;
    try testing.expectEqualStrings(
        "ghcr.io/drewr/agent-claude@sha256:bbbb2222",
        lastDigestRef(a, "ghcr.io/drewr/agent-claude", out).?,
    );
}

test "lastDigestRef ignores other repos and plain hex" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = "ghcr.io/other/agent-claude@sha256:deadbeef\nnothing here\n";
    try testing.expect(lastDigestRef(a, "ghcr.io/drewr/agent-claude", out) == null);
    try testing.expect(lastDigestRef(a, "x", "") == null);
}

test "pinImage writes a header, then replaces one harness's line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const first = try pinImageText(a, null, "unikernel", "claude", "ghcr.io/drewr/agent-claude@sha256:aa");
    try testing.expectEqualStrings(
        \\# One pinned image per harness for the unikernel class (yolo build HARNESS --backend datum --class unikernel).
        \\claude    ghcr.io/drewr/agent-claude@sha256:aa
        \\
    , first);

    const two = try pinImageText(a, first, "unikernel", "pi", "ghcr.io/drewr/agent-pi@sha256:bb");
    const three = try pinImageText(a, two, "unikernel", "claude", "ghcr.io/drewr/agent-claude@sha256:cc");
    try testing.expectEqualStrings(
        \\# One pinned image per harness for the unikernel class (yolo build HARNESS --backend datum --class unikernel).
        \\pi        ghcr.io/drewr/agent-pi@sha256:bb
        \\claude    ghcr.io/drewr/agent-claude@sha256:cc
        \\
    , three);
}

test "lockedRev reads a root input's rev" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lock =
        \\{"nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs"}},
        \\"nixpkgs":{"locked":{"rev":"abc123"}}},"root":"root","version":7}
    ;
    try testing.expectEqualStrings("abc123", lockedRev(a, lock, "nixpkgs").?);
    try testing.expect(lockedRev(a, lock, "llm-agents") == null);
    try testing.expect(lockedRev(a, "not json", "nixpkgs") == null);
}
