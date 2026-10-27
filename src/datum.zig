//! The datum backend: sessions on Datum Compute, reached by SSH over iroh.
//!
//! Each session gets a fresh iroh secret and SSH host key generated here,
//! stored in a per-session Datum Secret (yolo-NAME) and in the session
//! directory. The client derives the iroh ticket from the secret and pins the
//! host key, so nothing is read from instance logs and there is no
//! trust-on-first-use. Every key in the Secret agent-providers is passed to
//! the session as a variable of the same name (only key names are read here).
//! If the Secret agent-home exists, every session mounts the same JuiceFS
//! volume as HOME. See docs/datum.md.

const std = @import("std");
const util = @import("util.zig");
const json = @import("json.zig");
const keys = @import("keys.zig");
const session = @import("session.zig");
const Ctx = util.Ctx;
const mem = std.mem;

pub const default_relay = "https://use1-1.relay.n0.iroh.link./";

pub const Datum = struct {
    images: []const u8, // unikernel images, one per harness
    gp_images: []const u8, // general-purpose (standard OCI) images
    user: []const u8, // login user in the sandbox; root also works
    forward_agent: bool, // forward the local agent while connected, for git over SSH
    pull_secret: []const u8,
    location: []const u8,
    network: []const u8,
    instance_type: []const u8,
    cls: []const u8, // unikernel, or general-purpose
    relay: []const u8, // the relay instances have chosen in every run so far
    home_secret: []const u8,
    providers_secret: []const u8,
    jfs_opts: []const u8, // extra `juicefs mount` options for the shared home
};

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// The login user in the sandbox: `DATUM_SESSION`, else production's default.
/// Also what `useDatumSession` puts in the environment for child processes.
pub fn datumSessionFrom(ctx: Ctx) []const u8 {
    return ctx.firstEnv(&.{ "YOLO_DATUM_SESSION", "AGENT_SANDBOX_DATUM_SESSION", "DATUM_SESSION" }) orelse
        "aaraines@gmail.com@api.datum.net";
}

/// The provider keys to pass: those of `keys` that are valid variable names,
/// sorted (the Haskell kept the JSON order; sorting is stable across runs).
pub fn providerKeyNames(allocator: mem.Allocator, names: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |k| {
        if (util.isVarName(k)) try out.append(allocator, k);
    }
    mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out.items;
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

// The backend is the tagged union in main.zig; its datum arm is a config.

pub fn config(ctx: Ctx, root: []const u8) Datum {
    useDatumSession(ctx);
    return Datum{
        .images = ctx.opt("IMAGES", util.join(ctx, &.{ root, "image/images" })),
        .gp_images = ctx.opt("GP_IMAGES", util.join(ctx, &.{ root, "image/images-general-purpose" })),
        .user = ctx.opt("USER", "drewr"),
        .forward_agent = mem.eql(u8, ctx.opt("FORWARD_AGENT", "1"), "1"),
        .pull_secret = ctx.opt("PULL_SECRET", "ghcr-drewr"),
        .location = ctx.opt("LOCATION", "us-east-1"),
        .network = ctx.opt("NETWORK", "default"),
        .instance_type = ctx.opt("INSTANCE_TYPE", "datumcloud/d1-standard-2"),
        .cls = ctx.opt("CLASS", "unikernel"),
        .relay = ctx.opt("RELAY", default_relay),
        .home_secret = ctx.opt("HOME_SECRET", "agent-home"),
        .providers_secret = ctx.opt("PROVIDERS_SECRET", "agent-providers"),
        .jfs_opts = ctx.opt("JFS_OPTS", ""),
    };
}

/// Point DATUM_SESSION at production (api.datum.net), project drewr-y4nd1b;
/// an explicit session wins.
pub fn useDatumSession(ctx: Ctx) void {
    ctx.setEnv("DATUM_SESSION", datumSessionFrom(ctx));
}

// ---------------------------------------------------------------------------
// new
// ---------------------------------------------------------------------------

pub fn datumNew(ctx: Ctx, d: Datum, name: []const u8, harness: []const u8, opts0: []const []const u8) u8 {
    var key: ?[]const u8 = null;
    var want_home = true;
    var cls = d.cls;
    var i: usize = 0;
    while (i < opts0.len) {
        if (mem.eql(u8, opts0[i], "--key") and i + 1 < opts0.len) {
            key = opts0[i + 1];
            i += 2;
        } else if (mem.eql(u8, opts0[i], "--no-home")) {
            want_home = false;
            i += 1;
        } else if (mem.eql(u8, opts0[i], "--class") and i + 1 < opts0.len) {
            cls = opts0[i + 1];
            i += 2;
        } else {
            util.dief("datum: unknown option {s}", .{opts0[i]});
        }
    }
    if (!session.isClass(cls)) util.dief("datum: unknown class '{s}' (unikernel or general-purpose)", .{cls});
    if (key) |k| {
        if (!util.isReadable(ctx, k)) util.dief("datum: cannot read {s}", .{k});
    }
    // The shared home: only if the Secret exists.
    const home_ok = util.quiet(ctx, &.{ "datumctl", "get", "secret", d.home_secret }) == 0;
    if (want_home and !home_ok) {
        util.warn("no Secret {s}; this session's HOME is ephemeral", .{d.home_secret});
    }
    const home = want_home and home_ok;

    const images = if (mem.eql(u8, cls, "general-purpose")) d.gp_images else d.images;
    const image_env = ctx.opt("IMAGE", "");
    const image = if (image_env.len != 0) image_env else blk: {
        const found = lookupImage(ctx, images, harness) orelse util.dief(
            "no {s} image for harness '{s}' in {s} (yolo build {s} --backend datum --class {s})",
            .{ cls, harness, images, harness, cls },
        );
        break :blk found;
    };

    const dir = session.create(ctx, name, "datum", harness);
    const wl = std.fmt.allocPrint(ctx.arena, "yolo-{s}", .{name}) catch util.die("out of memory");
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "class" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{cls}) catch "");
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "workload" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{wl}) catch "");
    session.recordDatumSession(ctx, dir);

    // Session keys, readable only by this user.
    const secret_hex = blk: {
        var secret: [32]u8 = undefined;
        ctx.io.randomSecure(&secret) catch |e| util.dief("can't get random bytes: {t}", .{e});
        const hex = keys.hexSecret(ctx.arena, secret) catch util.die("out of memory");
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "iroh_secret" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{hex}) catch "");
        break :blk hex;
    };
    {
        const ticket = keys.endpointTicket(ctx.arena, d.relay, secret_hex) catch |e| switch (e) {
            error.RelayTooLong => util.die("relay URL too long"),
            error.BadSecret => util.die("bad iroh secret"),
            error.OutOfMemory => util.die("out of memory"),
        };
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "ticket" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{ticket}) catch "");
    }
    const host_key_result = util.quiet(ctx, &.{
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", wl, "-f", util.join(ctx, &.{ dir, "host_key" }),
    }) == 0;
    if (!host_key_result) {
        util.removeTree(ctx, dir);
        util.die("could not make the host key");
    }
    const pub_line = util.readFileMaybe(ctx, util.join(ctx, &.{ dir, "host_key.pub" })) orelse "";
    {
        const kh = keys.knownHostsLine(ctx.arena, wl, pub_line) catch |e| switch (e) {
            error.BadPublicKey => util.die("ssh-keygen made no public key"),
            else => util.die("out of memory"),
        };
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "known_hosts" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{kh}) catch "");
    }
    const authorized = keys.authorizedKeys(ctx, key) catch |e| switch (e) {
        error.NoPublicKey => {
            util.removeTree(ctx, dir);
            util.die(keys.no_public_key);
        },
        else => util.die("out of memory"),
    };
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "authorized_keys" }), authorized);
    // A --key FILE.pub with its private key beside it is also the identity.
    if (key) |k| {
        if (mem.endsWith(u8, k, ".pub") and k.len >= 4) {
            const priv = k[0 .. k.len - 4];
            if (util.fileExists(ctx, priv)) {
                const real = util.realPath(ctx, priv) orelse priv;
                util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "identity" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{real}) catch "");
            }
        }
    }
    // The ticket is derived above; a session without one is useless.
    const ticket_ok = mem.startsWith(u8, util.readMeta(ctx, util.join(ctx, &.{ dir, "ticket" }), ""), "endpoint");
    if (!ticket_ok) {
        util.removeTree(ctx, dir);
        util.die("could not derive the iroh ticket");
    }

    // The session Secret: iroh secret, authorized keys and host key, base64'd.
    const secret_hex_text = util.readMeta(ctx, util.join(ctx, &.{ dir, "iroh_secret" }), "");
    const authorized_text = util.readFileMaybe(ctx, util.join(ctx, &.{ dir, "authorized_keys" })) orelse "";
    const host_key = util.readFileMaybe(ctx, util.join(ctx, &.{ dir, "host_key" })) orelse "";
    const auth_b64 = util.b64encode(ctx.arena, authorized_text) catch util.die("out of memory");
    const host_b64 = util.b64encode(ctx.arena, host_key) catch util.die("out of memory");
    apply(ctx, "the session Secret", renderSecret(ctx.arena, wl, secret_hex_text, auth_b64, host_b64));

    const providers = datumProviderKeyNames(ctx, d);
    const pubkey = keys.pubFromSecretHex(secret_hex_text) catch util.die("bad iroh secret");
    const endpoint_dns = keys.endpointDns(ctx.arena, pubkey) catch util.die("out of memory");
    apply(ctx, "the Workload", renderWorkload(ctx.arena, d, .{
        .workload = wl,
        .name = name,
        .harness = harness,
        .cls = cls,
        .image = image,
        .endpoint_dns = endpoint_dns,
        .provider_keys = providers,
        .home = home,
    }));

    util.errPrint("created {s} ({s}: {s}); waiting for SSH...\n", .{ wl, harness, image });
    const t0 = util.monoNow(ctx);
    waitForSsh(ctx, d, name, t0);
    const n = util.secondsSince(ctx, t0);
    util.errPrint("ready after {d}s: yolo attach {s}\n", .{ n, name });
    return 0;
}

fn waitForSsh(ctx: Ctx, d: Datum, name: []const u8, t0: std.Io.Timestamp) void {
    while (true) {
        const dir = session.dir(ctx, name);
        const ticket = util.readMeta(ctx, util.join(ctx, &.{ dir, "ticket" }), "");
        const wl = session.workload(ctx, dir, name);
        const identity = util.readFileMaybe(ctx, util.join(ctx, &.{ dir, "identity" }));
        const ident = if (identity) |i| util.trim(i) else null;
        const argv = datumSsh(ctx, d, dir, wl, ticket, ident, &.{ "-o", "ConnectTimeout=20", "-o", "BatchMode=yes", "true" });
        const ok = util.quiet(ctx, argv) == 0;
        if (ok) return;
        const n = util.secondsSince(ctx, t0);
        if (n >= 300) util.dief("no SSH after 5 min; try: yolo logs {s}", .{name});
        util.sleep(ctx, 10_000);
    }
}

/// The ssh command line for a session (options first, then the command).
pub fn datumSsh(
    ctx: Ctx,
    d: Datum,
    dir: []const u8,
    wl: []const u8,
    ticket: []const u8,
    identity: ?[]const u8,
    args: []const []const u8,
) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(ctx.arena, &.{ "ssh", "-o" }) catch util.die("out of memory");
    const proxy = std.fmt.allocPrint(ctx.arena, "ProxyCommand=dumbpipe connect {s} 2>/dev/null", .{ticket}) catch util.die("out of memory");
    out.appendSlice(ctx.arena, &.{ proxy, "-o" }) catch util.die("out of memory");
    const known = std.fmt.allocPrint(ctx.arena, "UserKnownHostsFile={s}/known_hosts", .{dir}) catch util.die("out of memory");
    out.appendSlice(ctx.arena, &.{ known, "-o" }) catch util.die("out of memory");
    out.appendSlice(ctx.arena, &.{
        std.fmt.allocPrint(ctx.arena, "HostKeyAlias={s}", .{wl}) catch "",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ServerAliveInterval=30",
    }) catch util.die("out of memory");
    if (identity) |i| {
        out.appendSlice(ctx.arena, &.{ "-i", i, "-o", "IdentitiesOnly=yes" }) catch util.die("out of memory");
    }
    if (d.forward_agent) out.appendSlice(ctx.arena, &.{ "-o", "ForwardAgent=yes" }) catch util.die("out of memory");
    // Options up to --, or the first non-option; then the destination.
    const split = splitSshArgs(ctx.arena, args);
    out.appendSlice(ctx.arena, split.opts) catch util.die("out of memory");
    out.append(ctx.arena, std.fmt.allocPrint(ctx.arena, "{s}@{s}", .{ d.user, wl }) catch "") catch util.die("out of memory");
    out.appendSlice(ctx.arena, split.cmd) catch util.die("out of memory");
    return out.items;
}

/// ssh-style argument split (`split` in the Haskell): -o/-L/-R/-D/-i take a
/// value, `--` ends the options, and the first non-option starts the command.
pub const SshArgs = struct {
    opts: []const []const u8,
    cmd: []const []const u8,
};

pub fn splitSshArgs(allocator: std.mem.Allocator, args: []const []const u8) SshArgs {
    var opts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (mem.eql(u8, a, "--")) return .{ .opts = opts.items, .cmd = args[i + 1 ..] };
        if (isValueOption(a)) {
            opts.appendSlice(allocator, &.{ a, if (i + 1 < args.len) args[i + 1] else "" }) catch {};
            i += 1;
            continue;
        }
        if (mem.startsWith(u8, a, "-")) {
            opts.append(allocator, a) catch {};
            continue;
        }
        return .{ .opts = opts.items, .cmd = args[i..] };
    }
    return .{ .opts = opts.items, .cmd = &.{} };
}

fn isValueOption(a: []const u8) bool {
    for ([_][]const u8{ "-o", "-L", "-R", "-D", "-i" }) |o| {
        if (mem.eql(u8, a, o)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// attach / logs / rm
// ---------------------------------------------------------------------------

pub fn datumAttach(ctx: Ctx, d: Datum, name: []const u8, args: []const []const u8) u8 {
    const dir = session.dir(ctx, name);
    if (!util.fileExists(ctx, util.join(ctx, &.{ dir, "ticket" }))) util.dief("no local state for {s}", .{name});
    const ticket = util.readMeta(ctx, util.join(ctx, &.{ dir, "ticket" }), "");
    const wl = session.workload(ctx, dir, name);
    const identity = util.readFileMaybe(ctx, util.join(ctx, &.{ dir, "identity" }));
    const ident = if (identity) |i| util.trim(i) else null;
    const argv = datumSsh(ctx, d, dir, wl, ticket, ident, args);
    util.replace(ctx, argv);
}

pub fn datumLogs(ctx: Ctx, d: Datum, name: []const u8, args: []const []const u8) u8 {
    _ = d;
    const dir = session.dir(ctx, name);
    const wl = session.workload(ctx, dir, name);
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(ctx.arena, &.{ "datumctl", "compute", "logs", wl }) catch {};
    argv.appendSlice(ctx.arena, args) catch {};
    return util.inherit(ctx, argv.items);
}

pub fn datumRm(ctx: Ctx, d: Datum, name: []const u8) u8 {
    const dir = session.dir(ctx, name);
    // Persist RAM workspaces (/work) to the shared home and release their locks
    // before the instance goes, so another session can open them right away.
    const has_ticket = util.fileExists(ctx, util.join(ctx, &.{ dir, "ticket" }));
    if (has_ticket) {
        const ticket = util.readMeta(ctx, util.join(ctx, &.{ dir, "ticket" }), "");
        const wl = session.workload(ctx, dir, name);
        const argv = datumSsh(ctx, d, dir, wl, ticket, null, &.{ "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "--", "HOME=/home/agent; [ -d /work ] && ws close --all" });
        if (util.quiet(ctx, argv) == 0) {
            util.errPrint("workspaces saved\n", .{});
        } else {
            util.errPrint("yolo: could not save workspaces of {s}\n", .{name});
        }
    }
    const wl = session.workload(ctx, dir, name);
    for ([_][]const u8{ "workload", "secret" }) |kind| {
        const r = util.capture(ctx, &.{ "datumctl", "delete", kind, wl }, .{}) catch continue;
        // The outcome: stdout's last line ("... deleted"), else the error.
        const line = util.lastLine(r.stdout) orelse util.lastLine(r.stderr) orelse continue;
        util.outRaw(line);
        util.outRaw("\n");
    }
    util.removeTree(ctx, dir);
    return 0;
}

// ---------------------------------------------------------------------------
// ls: sync with Datum, then one row per workload
// ---------------------------------------------------------------------------

/// `cmdLs` prints the datum table itself, from the items it already synced
/// (the Haskell's `bLs` for datum is only the sync); listing again here would
/// print every session twice.
pub fn datumLs(ctx: Ctx, d: Datum, full: bool) u8 {
    _ = d;
    _ = full;
    _ = datumSync(ctx);
    return 0;
}

pub fn datumSync(ctx: Ctx) ?[]const json.Value {
    const r = util.capture(ctx, &.{ "datumctl", "get", "workloads", "-o", "json" }, .{}) catch |e| {
        util.warn("can't list Datum sessions, so they weren't synced: {t}", .{e});
        return null;
    };
    if (r.term != .exited or r.code != 0) {
        util.warn("can't list Datum sessions, so they weren't synced: {s}", .{util.trim(r.stderr)});
        return null;
    }
    const v = json.parse(ctx.arena, r.stdout) orelse return null;
    const all = json.list(&.{"items"}, v);
    var items: std.ArrayList(json.Value) = .empty;
    var remote: std.ArrayList([]const u8) = .empty;
    for (all) |w| {
        const wl = json.str(&.{ "metadata", "name" }, w);
        if (session.sessionOfWorkload(wl)) |n| {
            items.append(ctx.arena, w) catch {};
            if (!contains(remote.items, n)) remote.append(ctx.arena, n) catch {};
        }
    }
    const st = session.state(ctx);
    const local = session.localSessions(ctx, "datum");
    for (remote.items) |n| {
        if (contains(local, n)) continue;
        const target = util.join(ctx, &.{ st, n });
        if (util.exists(ctx, target)) {
            util.warn("Datum session {s} isn't set up here: a local {s} of another backend has the name", .{ n, n });
        } else {
            // One bad session shouldn't stop the rest (the Haskell ran each
            // adopt under try).
            const ok = adoptMaybe(ctx, false, n);
            _ = ok;
        }
    }
    const current = ctx.envNonEmpty("DATUM_SESSION") orelse "";
    for (local) |n| {
        if (contains(remote.items, n)) continue;
        const owner = util.readMeta(ctx, util.join(ctx, &.{ st, n, "datum_session" }), current);
        if (mem.eql(u8, owner, current)) {
            util.removeTree(ctx, util.join(ctx, &.{ st, n }));
            util.warn("removed {s}: its workload is gone from Datum", .{n});
        }
    }
    return items.items;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (mem.eql(u8, x, s)) return true;
    return false;
}

/// One row per agent workload. Placements and locations stay: sessions may
/// run in other locations. Image references are shortened to
/// repo@digest-prefix unless `full`.
pub fn datumTable(ctx: Ctx, full: bool, items: []const json.Value) void {
    if (items.len == 0) return;
    var rows: std.ArrayList([]const []const u8) = .empty;
    const header: []const []const u8 = &.{ "NAME", "HEALTH", "READY", "LOCATIONS", "PLACEMENTS", "IMAGE", "AGE" };
    rows.append(ctx.arena, header) catch {};
    for (items) |w| {
        const wl = json.str(&.{ "metadata", "name" }, w);
        const name = session.sessionOfWorkload(wl) orelse "?";
        const placements = json.list(&.{ "spec", "placements" }, w);
        var locations: std.ArrayList([]const u8) = .empty;
        var placement_names: std.ArrayList([]const u8) = .empty;
        for (placements) |p| {
            const pn = json.str(&.{ "name" }, p);
            if (!contains(placement_names.items, pn)) placement_names.append(ctx.arena, pn) catch {};
            for (json.list(&.{ "locations" }, p)) |l| {
                const ln = json.str(&.{ "name" }, l);
                if (!contains(locations.items, ln)) locations.append(ctx.arena, ln) catch {};
            }
        }
        const avail = blk: {
            const conds = json.list(&.{ "status", "conditions" }, w);
            var any = false;
            for (conds) |c| {
                if (mem.eql(u8, json.str(&.{ "type" }, c), "Available")) {
                    if (mem.eql(u8, json.str(&.{ "status" }, c), "True")) any = true;
                }
            }
            break :blk if (any) "Available" else "Unavailable";
        };
        const ready = text("status", "readyReplicas", w);
        const replicas = text("status", "replicas", w);
        const ready_str = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ready, replicas }) catch "0/0";
        const locs = commas(ctx, locations.items);
        const pls = commas(ctx, placement_names.items);
        const img0 = blk: {
            const containers = json.list(&.{ "spec", "template", "spec", "runtime", "sandbox", "containers" }, w);
            if (containers.len == 0) break :blk "";
            break :blk json.str(&.{ "image" }, containers[0]);
        };
        const img = if (full) img0 else util.shortImage(ctx.arena, img0) catch img0;
        const created = json.str(&.{ "metadata", "creationTimestamp" }, w);
        const age = util.age(ctx, created);
        // A fresh slice per row: `&row` would alias one stack slot.
        const row = ctx.arena.dupe([]const u8, &.{ name, avail, ready_str, locs, pls, img, age }) catch continue;
        rows.append(ctx.arena, row) catch {};
    }

    // Render.
    var widths: [7]usize = .{ 0, 0, 0, 0, 0, 0, 0 };
    for (rows.items) |row| {
        for (row, 0..) |cell, k| {
            if (cell.len > widths[k]) widths[k] = cell.len;
        }
    }
    util.say("");
    util.say("== datum");
    for (rows.items, 0..) |row, ri| {
        var buf: std.ArrayList(u8) = .empty;
        for (row, 0..) |cell, k| {
            buf.appendSlice(ctx.arena, cell) catch {};
            if (k + 1 < row.len) {
                const pad = widths[k] - cell.len + 3;
                buf.appendNTimes(ctx.arena, ' ', pad) catch {};
            }
        }
        var line = util.trim(buf.items);
        _ = &line;
        _ = ri;
        util.outRaw(buf.items);
        util.outRaw("\n");
    }
}

fn text(path0: []const u8, path1: []const u8, v: json.Value) []const u8 {
    return json.num(std.heap.page_allocator, &.{ path0, path1 }, v) catch "0";
}

fn commas(ctx: Ctx, xs: []const []const u8) []const u8 {
    if (xs.len == 0) return "-";
    var buf: std.ArrayList(u8) = .empty;
    for (xs, 0..) |x, i| {
        if (i != 0) buf.append(ctx.arena, ',') catch {};
        buf.appendSlice(ctx.arena, x) catch {};
    }
    return buf.items;
}

// ---------------------------------------------------------------------------
// adopt: rebuild the local state of a session made on another machine
// ---------------------------------------------------------------------------

/// Rebuild the local state of a datum session made on another machine, from
/// its Datum Secret (iroh secret, host key, authorized keys) and Workload
/// (harness, class). The host's private key is only used to derive the key to
/// pin; it isn't kept. False if there's no such session on Datum.
pub const AdoptError = error{ NotOnDatum, CanNotAdopt };

/// The message `adopt` reported, for `sessionBackend` to die with.
pub var adopt_message: []const u8 = "can't set up the session from Datum";

fn fail(ctx: Ctx, comptime fmt: []const u8, args: anytype) AdoptError {
    adopt_message = std.fmt.allocPrint(ctx.arena, fmt, args) catch adopt_message;
    return error.CanNotAdopt;
}

/// adopt, with a failure turned into a warning instead of a fatal error (the
/// Haskell's `try (adoptDatum False n)`, for `ls`'s sync).
fn adoptMaybe(ctx: Ctx, check_keys: bool, name: []const u8) bool {
    return adopt(ctx, check_keys, name) catch |e| switch (e) {
        error.NotOnDatum => false,
        error.CanNotAdopt => {
            util.warn("couldn't set up {s} from Datum: {s}", .{ name, adopt_message });
            return false;
        },
    };
}

pub fn adopt(ctx: Ctx, check_keys: bool, name: []const u8) AdoptError!bool {
    if (util.findExecutable(ctx, "datumctl") == null) return false;
    useDatumSession(ctx);
    var found: ?[]const u8 = null;
    var workload: ?json.Value = null;
    for (session.workload_prefixes) |p| {
        const wl = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ p, name }) catch return false;
        const r = util.capture(ctx, &.{ "datumctl", "get", "workload", wl, "-o", "json" }, .{}) catch continue;
        if (r.term != .exited or r.code != 0) continue;
        if (json.parse(ctx.arena, r.stdout)) |w| {
            found = wl;
            workload = w;
            break;
        }
    }
    const wl = found orelse return false;
    const w = workload.?;

    const sr = util.capture(ctx, &.{ "datumctl", "get", "secret", wl, "-o", "json" }, .{}) catch
        return fail(ctx, "{s} exists on Datum, but its Secret can't be read", .{wl});
    if (sr.term != .exited or sr.code != 0)
        return fail(ctx, "{s} exists on Datum, but its Secret can't be read: {s}", .{ wl, util.trim(sr.stderr) });
    const secret = json.parse(ctx.arena, sr.stdout) orelse
        return fail(ctx, "{s} exists on Datum, but its Secret can't be read", .{wl});

    const iroh_secret = field(ctx, secret, "IROH_SECRET") orelse
        return fail(ctx, "the Secret {s} is missing session keys", .{wl});
    const host_key = twice(ctx, secret, "SSH_HOST_KEY_B64") orelse
        return fail(ctx, "the Secret {s} is missing session keys", .{wl});
    const authorized = twice(ctx, secret, "AUTHORIZED_KEYS_B64") orelse
        return fail(ctx, "the Secret {s} is missing session keys", .{wl});

    const harness = blk: {
        const h = json.str(&.{ "metadata", "labels", "agent-harness" }, w);
        break :blk if (h.len == 0) "?" else h;
    };
    const cls = blk: {
        const c = json.str(&.{ "spec", "template", "spec", "runtime", "class" }, w);
        break :blk if (c.len == 0) "unikernel" else c;
    };
    const relay = ctx.opt("RELAY", default_relay);

    const dir = session.create(ctx, name, "datum", harness);
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "class" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{cls}) catch "");
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "workload" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{wl}) catch "");
    session.recordDatumSession(ctx, dir);
    {
        const hex = util.trim(iroh_secret);
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "iroh_secret" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{hex}) catch "");
        const ticket = keys.endpointTicket(ctx.arena, relay, hex) catch util.die("could not derive the iroh ticket");
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "ticket" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{ticket}) catch "");
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "authorized_keys" }), authorized);
        const tmp = util.join(ctx, &.{ dir, "host_key.adopt" });
        // ssh-keygen refuses group/world-readable private keys (umask 077 in
        // the Haskell).
        util.writeFile(ctx, tmp, host_key, .fromMode(0o600)) catch |e| {
            util.removeTree(ctx, dir);
            return fail(ctx, "can't write {s}: {t}", .{ tmp, e });
        };
        const pub_key = keys.publicKeyOf(ctx, tmp) orelse {
            util.removeTree(ctx, dir);
            return fail(ctx, "can't read the host key of {s}", .{wl});
        };
        util.removeFile(ctx, tmp);
        const kh = keys.knownHostsLine(ctx.arena, wl, pub_key) catch {
            util.removeTree(ctx, dir);
            return fail(ctx, "can't read the host key of {s}", .{wl});
        };
        util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "known_hosts" }), std.fmt.allocPrint(ctx.arena, "{s}\n", .{kh}) catch "");
    }
    util.errPrint("yolo: set up {s} from Datum\n", .{name});
    // Logging in needs one of this machine's keys among the session's.
    if (check_keys) {
        const mine = keys.keyMaterial(ctx.arena, keys.agentKeys(ctx)) catch &.{};
        const theirs = keys.keyMaterial(ctx.arena, authorized) catch &.{};
        if (mine.len != 0 and !keys.anyAuthorized(mine, theirs))
            util.warn("none of your agent's keys is authorized for {s}; logging in will fail", .{name});
    }
    return true;
}

fn field(ctx: Ctx, secret: json.Value, k: []const u8) ?[]const u8 {
    const raw = json.str(&.{ "data", k }, secret);
    return util.b64decode(ctx.arena, raw) catch null;
}

fn twice(ctx: Ctx, secret: json.Value, k: []const u8) ?[]const u8 {
    const inner = field(ctx, secret, k) orelse return null;
    return util.b64decode(ctx.arena, inner) catch null;
}

// ---------------------------------------------------------------------------
// datumctl helpers
// ---------------------------------------------------------------------------

/// Key names in the providers Secret that are valid variable names. Values
/// are never read here.
pub fn datumProviderKeyNames(ctx: Ctx, d: Datum) []const []const u8 {
    const r = util.capture(ctx, &.{ "datumctl", "get", "secret", d.providers_secret, "-o", "json" }, .{}) catch return &.{};
    if (r.term != .exited or r.code != 0) return &.{};
    const v = json.parse(ctx.arena, r.stdout) orelse return &.{};
    const data = json.object(&.{"data"}, v) orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    var it = data.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (util.isVarName(k)) names.append(ctx.arena, k) catch {};
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.items;
}

fn apply(ctx: Ctx, what: []const u8, yaml: []const u8) void {
    const r = util.capture(ctx, &.{ "datumctl", "apply", "-f", "-" }, .{ .stdin = yaml }) catch
        util.dief("could not apply {s}", .{what});
    if (r.term != .exited or r.code != 0)
        util.dief("could not apply {s}: {s}", .{ what, util.trim(r.stderr) });
}

pub fn lookupImage(ctx: Ctx, file: []const u8, harness: []const u8) ?[]const u8 {
    const body = util.readFileMaybe(ctx, file) orelse return null;
    var lines = mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        var words = mem.tokenizeAny(u8, line, " \t\r");
        const h = words.next() orelse continue;
        const img = words.next() orelse continue;
        if (mem.eql(u8, h, harness)) return ctx.arena.dupe(u8, img) catch null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The Secret and Workload YAML
// ---------------------------------------------------------------------------

pub fn renderSecret(allocator: mem.Allocator, wl: []const u8, secret_hex: []const u8, auth_b64: []const u8, host_b64: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(allocator,
        \\apiVersion: v1
        \\kind: Secret
        \\metadata:
        \\  name: {s}
        \\type: Opaque
        \\stringData:
        \\  IROH_SECRET: "{s}"
        \\  AUTHORIZED_KEYS_B64: "{s}"
        \\  SSH_HOST_KEY_B64: "{s}"
        \\
    , .{ wl, secret_hex, auth_b64, host_b64 }) catch {};
    return out.items;
}

pub const WorkloadInput = struct {
    workload: []const u8,
    name: []const u8,
    harness: []const u8,
    cls: []const u8,
    image: []const u8,
    endpoint_dns: []const u8,
    provider_keys: []const []const u8,
    home: bool,
};

pub fn renderWorkload(allocator: mem.Allocator, d: Datum, in: WorkloadInput) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(allocator,
        \\apiVersion: compute.datumapis.com/v1alpha
        \\kind: Workload
        \\metadata:
        \\  name: {s}
        \\  labels:
        \\    agent-sandbox: "true"
        \\    agent-harness: {s}
        \\spec:
        \\  template:
        \\    spec:
        \\      runtime:
        \\        class: {s}
        \\        resources:
        \\          instanceType: {s}
        \\        sandbox:
        \\          imagePullSecrets:
        \\            - name: {s}
        \\          containers:
        \\            - name: agent
        \\              image: {s}
        \\
    , .{ in.workload, in.harness, in.cls, d.instance_type, d.pull_secret, in.image }) catch {};
    if (mem.eql(u8, in.cls, "general-purpose")) {
        out.appendSlice(allocator,
            \\              securityContext:
            \\                capabilities:
            \\                  add: [SYS_ADMIN, MKNOD, CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, NET_BIND_SERVICE, SETFCAP, SETGID, SETPCAP, SETUID, SYS_CHROOT]
            \\
        ) catch {};
    }
    out.appendSlice(allocator, "              env:\n") catch {};
    value(allocator, &out, "YOLO_MODE", "datum");
    value(allocator, &out, "SESSION_NAME", in.name);
    value(allocator, &out, "JFS_MOUNT_OPTS", show(allocator, d.jfs_opts));
    value(allocator, &out, "ENDPOINT_DNS", in.endpoint_dns);
    for ([_][]const u8{ "IROH_SECRET", "AUTHORIZED_KEYS_B64", "SSH_HOST_KEY_B64" }) |k| {
        fromSecret(allocator, &out, in.workload, k);
    }
    {
        var pk: std.ArrayList(u8) = .empty;
        for (in.provider_keys, 0..) |k, i| {
            if (i != 0) pk.append(allocator, ' ') catch {};
            pk.appendSlice(allocator, k) catch {};
        }
        value(allocator, &out, "PROVIDER_KEYS", show(allocator, pk.items));
    }
    for (in.provider_keys) |k| fromSecret(allocator, &out, d.providers_secret, k);
    if (in.home) {
        for ([_][]const u8{ "META_TICKET", "META_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY" }) |k| {
            fromSecret(allocator, &out, d.home_secret, k);
        }
    }
    out.print(allocator,
        \\      networkInterfaces:
        \\        - network:
        \\            name: {s}
        \\  placements:
        \\    - name: default
        \\      locations:
        \\        - name: {s}
        \\      scaleSettings:
        \\        minReplicas: 1
        \\
    , .{ d.network, d.location }) catch {};
    return out.items;
}

fn value(allocator: mem.Allocator, out: *std.ArrayList(u8), k: []const u8, v: []const u8) void {
    out.print(allocator,
        \\                - name: {s}
        \\                  value: {s}
        \\
    , .{ k, v }) catch {};
}

fn fromSecret(allocator: mem.Allocator, out: *std.ArrayList(u8), secret: []const u8, k: []const u8) void {
    out.print(allocator,
        \\                - name: {s}
        \\                  valueFrom:
        \\                    secretKeyRef: {{ name: {s}, key: {s} }}
        \\
    , .{ k, secret, k }) catch {};
}

/// Haskell's `show` for a string: double quotes, with these escapes.
pub fn show(allocator: mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(allocator, '"') catch {};
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice(allocator, "\\\"") catch {},
            '\\' => out.appendSlice(allocator, "\\\\") catch {},
            else => out.append(allocator, c) catch {},
        }
    }
    out.append(allocator, '"') catch {};
    return out.items;
}

// ---------------------------------------------------------------------------
// build --backend datum is in images.zig; this is its datum-side entry.
// ---------------------------------------------------------------------------

pub fn buildDatum(ctx: Ctx, root: []const u8, cls: []const u8, hs: []const []const u8) u8 {
    return @import("images.zig").buildDatum(ctx, root, cls, hs);
}

test {
    _ = renderSecret;
    _ = renderWorkload;
    _ = providerKeyNames;
}
