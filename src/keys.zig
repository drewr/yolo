//! Keys and iroh tickets: the iroh endpoint's public key from its Ed25519
//! secret, the z-base-32 DNS label, the endpoint ticket that carries the relay
//! URL, and the public keys a session authorizes.
//!
//! The derivations are byte-identical to the Haskell yolo's (which used
//! crypton): they are pinned by the golden vectors in tests/golden/.

const std = @import("std");
const util = @import("util.zig");
const Ctx = util.Ctx;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

pub const zbase32_alphabet = "ybndrfg8ejkmcpqxot1uwisza345h769";
pub const base32_alphabet = "abcdefghijklmnopqrstuvwxyz234567";

pub const KeyError = error{
    BadSecret,
    RelayTooLong,
};

/// The iroh endpoint's public key from its 32-byte Ed25519 secret.
pub fn pubFromSecret(secret: [32]u8) [32]u8 {
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(secret) catch unreachable;
    return kp.public_key.toBytes();
}

/// The iroh endpoint's public key for a hex secret (`pubFromSecretHex`).
pub fn pubFromSecretHex(hex: []const u8) KeyError![32]u8 {
    return pubFromSecret(secretFromHex(hex) orelse return error.BadSecret);
}

/// 32 bytes from 64 hex digits.
pub fn secretFromHex(hex: []const u8) ?[32]u8 {
    const t = util.trim(hex);
    if (t.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, t) catch return null;
    return out;
}

pub fn hexSecret(allocator: std.mem.Allocator, secret: [32]u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{x}", .{secret});
}

/// 5-bit groups over the bytes, zero-padded at the end, mapped through
/// `alphabet` (base32 without '=').
pub fn encode5(allocator: std.mem.Allocator, alphabet: []const u8, bytes: []const u8) ![]u8 {
    const groups = (bytes.len * 8 + 4) / 5;
    const out = try allocator.alloc(u8, groups);
    var acc: u16 = 0;
    var bits: u4 = 0;
    var i: usize = 0;
    for (bytes) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            out[i] = alphabet[@as(usize, (acc >> bits) & 0x1f)];
            i += 1;
        }
    }
    if (bits > 0) {
        out[i] = alphabet[@as(usize, (acc << (5 - bits)) & 0x1f)];
        i += 1;
    }
    return out;
}

/// The z-base-32 label for iroh's DNS discovery name
/// `_iroh.<label>.dns.iroh.link`.
pub fn zbase32(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return encode5(allocator, zbase32_alphabet, bytes);
}

/// The name the endpoint publishes for DNS discovery (`ENDPOINT_DNS` in the
/// Workload).
pub fn endpointDns(allocator: std.mem.Allocator, pubkey: [32]u8) ![]u8 {
    const label = try zbase32(allocator, &pubkey);
    return std.fmt.allocPrint(allocator, "_iroh.{s}.dns.iroh.link", .{label});
}

/// An iroh endpoint ticket carrying the relay URL, so the client dials the
/// relay directly instead of depending on DNS discovery, which instances have
/// failed to publish to (docs/datum.md). Wire format, as decoded from dumbpipe
/// tickets: `00 | pubkey(32) | n_addrs=1 | 00 len url`.
pub fn endpointTicket(allocator: std.mem.Allocator, relay: []const u8, hex: []const u8) KeyError![]u8 {
    if (relay.len >= 128) return error.RelayTooLong;
    const pubkey = try pubFromSecretHex(hex);
    var bytes = std.ArrayList(u8).empty;
    try bytes.append(allocator, 0);
    try bytes.appendSlice(allocator, &pubkey);
    try bytes.appendSlice(allocator, &.{ 1, 0, @intCast(relay.len) });
    try bytes.appendSlice(allocator, relay);
    const encoded = try encode5(allocator, base32_alphabet, bytes.items);
    return std.mem.concat(allocator, u8, &.{ "endpoint", encoded });
}

/// The `known_hosts` line pinning a session's host key: the workload name as
/// HostKeyAlias, then the key type and its base64.
pub fn knownHostsLine(allocator: std.mem.Allocator, workload: []const u8, pubkey_line: []const u8) ![]u8 {
    var it = std.mem.tokenizeAny(u8, pubkey_line, " \t\n\r");
    _ = it.next() orelse return error.BadPublicKey;
    const kind = it.next() orelse return error.BadPublicKey;
    const key = it.next() orelse return error.BadPublicKey;
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ workload, kind, key });
}

/// The public keys in an `ssh-add -L` or `authorized_keys` listing: the key
/// material (second field) of every line that looks like an SSH key.
pub fn keyMaterial(allocator: std.mem.Allocator, listing: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const kind = it.next() orelse continue;
        if (!std.mem.startsWith(u8, kind, "ssh-") and !std.mem.startsWith(u8, kind, "ecdsa-") and !std.mem.startsWith(u8, kind, "sk-")) continue;
        const material = it.next() orelse continue;
        try out.append(allocator, material);
    }
    return out.items;
}

/// Whether any of `mine` appears among `theirs`.
pub fn anyAuthorized(mine: []const []const u8, theirs: []const []const u8) bool {
    for (mine) |m| {
        for (theirs) |t| {
            if (std.mem.eql(u8, m, t)) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// Errors the Haskell reports with `die`, carried back to the caller so it can
/// clean up a half-made session first.
pub const AuthError = error{
    NoPublicKey,
    OutOfMemory,
};

pub const no_public_key = "no public key to authorize: load one into ssh-agent (is it responding?) or pass --key FILE";

/// Public keys to authorize: FILE if given, else the SSH agent's, else
/// ~/.ssh/id_*.pub. Never empty: a session nobody can log into is useless.
pub fn authorizedKeys(ctx: Ctx, file: ?[]const u8) AuthError![]const u8 {
    const keys = if (file) |f|
        (util.readFileMaybe(ctx, f) orelse "")
    else blk: {
        const agent = agentKeys(ctx);
        if (agent.len != 0) break :blk agent;
        const home = util.homeDir(ctx);
        for ([_][]const u8{ "id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub" }) |name| {
            const p = util.join(ctx, &.{ home, ".ssh", name });
            if (util.fileExists(ctx, p)) {
                break :blk (util.readFileMaybe(ctx, p) orelse "");
            }
        }
        break :blk "";
    };
    if (!hasSshKey(keys)) return error.NoPublicKey;
    // Written as received, minus a trailing newline's worth of whitespace.
    return util.trim(keys);
}

fn hasSshKey(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ssh-")) return true;
    }
    return false;
}

/// The SSH agent's keys, or "" when it has none or doesn't answer within 10 s
/// (a forwarded agent can stall).
pub fn agentKeys(ctx: Ctx) []const u8 {
    const r = util.capture(ctx, &.{ "ssh-add", "-L" }, .{ .timeout_ms = 10_000 }) catch return "";
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "ssh-")) continue;
        out.appendSlice(ctx.arena, line) catch return "";
        out.append(ctx.arena, '\n') catch return "";
    }
    return out.items;
}

/// The public key of a private key file, via `ssh-keygen -y` (used to pin the
/// host key of an adopted session and for nothing else: the private key isn't
/// kept). `null` when ssh-keygen can't read it.
pub fn publicKeyOf(ctx: Ctx, key_path: []const u8) ?[]const u8 {
    const r = util.capture(ctx, &.{ "ssh-keygen", "-y", "-f", key_path }, .{}) catch return null;
    if (r.term != .exited or r.code != 0) return null;
    return util.trim(r.stdout);
}
