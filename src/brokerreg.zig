//! The credential broker's registration of the sandboxes a jump box launches
//! (docs/jump-host-plan.md, Phase 4). A sandbox gets a proxy secret key; its
//! proxy's endpoint id goes into the box's Config as one `[[sandbox]]` block,
//! under `broker-sandbox.NAME`, and `broker-gen` changes so the box's root
//! syncs the broker's policy from Config.
//!
//! The proxy's endpoint id is its iroh public key as lowercase hex, which is
//! what `yolo-broker-proxy id` prints (iroh-base's PublicKey Display) and what
//! the broker's policy reads as `id`.
//!
//! The Config comes from YOLO_CONFIG_URL (config.zig); the broker settings from
//! YOLO_BROKER_ID and YOLO_BROKER_CA_FILE, which `jump login` exports.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const util = @import("util.zig");
const keys = @import("keys.zig");
const config = @import("config.zig");
const jumpbox = @import("jumpbox.zig");
const Ctx = util.Ctx;

/// The Config key of a sandbox's `[[sandbox]]` block: `broker-sandbox.NAME`.
pub const sandbox_prefix = "broker-sandbox.";
/// The Config key that changes whenever the broker's policy changes.
pub const gen_key = "broker-gen";
/// The Config key of the default rules for new sandboxes (TOML).
pub const rules_key = "broker-rules";
/// The session file recording a registered sandbox's endpoint id.
pub const session_file = "broker";

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// The broker settings a sandbox needs, from the environment of `yolo new`.
pub const Env = struct {
    broker_id: []const u8,
    config_url: []const u8,
    /// The broker's CA certificate (PEM file contents), base64'd.
    ca_b64: []const u8,
};

/// Whether a sandbox of `harness` gets broker access: never a jump box, and
/// only when the broker id, CA file and Config URL are all set.
pub fn enabled(harness: []const u8, broker_id: []const u8, ca_file: []const u8, config_url: []const u8) bool {
    if (mem.eql(u8, harness, jumpbox.harness)) return false;
    return broker_id.len != 0 and ca_file.len != 0 and config_url.len != 0;
}

/// The proxy's endpoint id for its 32-byte secret key: the lowercase hex of
/// the Ed25519 public key.
pub fn endpointId(allocator: mem.Allocator, secret: [32]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{x}", .{keys.pubFromSecret(secret)});
}

/// Whether `s` can sit in a TOML basic string: no control characters.
pub fn tomlSafe(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// `s` as a TOML basic string, in double quotes with `"` and `\` escaped.
/// `s` must be tomlSafe.
pub fn tomlString(allocator: mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

/// The `[[sandbox]]` block the broker's policy reads for a sandbox: its
/// endpoint id, its name, and its rules. `rules` is the text of `broker-rules`
/// (a `rules = [ ... ]` line or block), copied in trimmed; null means none, so
/// `rules = []`. Null when the id or name isn't tomlSafe.
pub fn sandboxBlock(allocator: mem.Allocator, endpoint_id: []const u8, name: []const u8, rules: ?[]const u8) !?[]u8 {
    if (!tomlSafe(endpoint_id) or !tomlSafe(name)) return null;
    const id_s = try tomlString(allocator, endpoint_id);
    defer allocator.free(id_s);
    const name_s = try tomlString(allocator, name);
    defer allocator.free(name_s);
    return try std.fmt.allocPrint(allocator, "[[sandbox]]\nid = {s}\nname = {s}\n{s}\n", .{
        id_s, name_s, rules orelse "rules = []",
    });
}

/// The Config key of a sandbox's block.
pub fn sandboxKey(allocator: mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ sandbox_prefix, name });
}

/// A new `broker-gen` value from the time and 8 random bytes, so two writes
/// never share a value.
pub fn genValue(allocator: mem.Allocator, unix_seconds: i64, random: [8]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}-{x}", .{ unix_seconds, random });
}

/// `text` trimmed, or null when nothing is left: an empty `broker-rules` is
/// no rules.
fn rulesText(text: []const u8) ?[]const u8 {
    const t = util.trim(text);
    return if (t.len == 0) null else t;
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// The broker settings of this `yolo new`, or null when the sandbox gets no
/// broker access. A CA file that can't be read is warned about, and then the
/// sandbox has none.
pub fn envFrom(ctx: Ctx, harness: []const u8) ?Env {
    const broker_id = ctx.opt("BROKER_ID", "");
    const ca_file = ctx.opt("BROKER_CA_FILE", "");
    const config_url = ctx.opt("CONFIG_URL", "");
    if (!enabled(harness, broker_id, ca_file, config_url)) return null;
    const pem = util.readFileMaybe(ctx, ca_file) orelse {
        util.warn("broker: cannot read {s}; this sandbox gets no broker access", .{ca_file});
        return null;
    };
    const ca_b64 = util.b64encode(ctx.arena, pem) catch util.die("out of memory");
    return .{ .broker_id = broker_id, .config_url = config_url, .ca_b64 = ca_b64 };
}

/// Register a sandbox with the broker: write its `broker-sandbox.NAME` entry
/// from the box's `broker-rules`, then change `broker-gen`. Null on success,
/// else why not; the sandbox then has no broker access.
pub fn register(ctx: Ctx, config_url: []const u8, name: []const u8, endpoint_id: []const u8) ?[]const u8 {
    const rules: ?[]const u8 = switch (config.getValue(ctx, config_url, .plain, rules_key)) {
        .value => |v| rulesText(v),
        .missing => null,
        .failed => |m| return m,
    };
    const key = sandboxKey(ctx.arena, name) catch return "out of memory";
    const block = (sandboxBlock(ctx.arena, endpoint_id, name, rules) catch return "out of memory") orelse
        return "the sandbox's id or name can't be a TOML string";
    if (config.putValue(ctx, config_url, .plain, key, block)) |m| return m;
    return bumpGen(ctx, config_url);
}

/// Take a sandbox out of the broker's policy: remove its `broker-sandbox.NAME`
/// entry, then change `broker-gen`. Null on success, else the failure text.
pub fn unregister(ctx: Ctx, config_url: []const u8, name: []const u8) ?[]const u8 {
    const key = sandboxKey(ctx.arena, name) catch return "out of memory";
    if (config.removeValue(ctx, config_url, .plain, key)) |m| return m;
    return bumpGen(ctx, config_url);
}

fn bumpGen(ctx: Ctx, config_url: []const u8) ?[]const u8 {
    var random: [8]u8 = undefined;
    util.randomBytes(ctx, &random) catch return "can't get random bytes";
    const gen = genValue(ctx.arena, util.realNow(ctx).toSeconds(), random) catch return "out of memory";
    return config.putValue(ctx, config_url, .plain, gen_key, gen);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "endpointId is the lowercase hex of the public key" {
    // Throwaway pair: the id is what `yolo-broker-proxy id` printed for it
    // with YOLO_PROXY_SECRET_KEY set to the secret.
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "67293f819b544cb3f66bb74d425675c588919d53e5559e4b2b6d0f7d0b850a5a");
    const id = try endpointId(testing.allocator, secret);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("a34699c4808c6f5465cd306f1734d1c6b636de2ecf25e9f670b3332c312a5c6f", id);
}

test "sandboxBlock with no rules has rules = []" {
    const b = (try sandboxBlock(testing.allocator, "abcd", "agent-1", null)).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(
        "[[sandbox]]\nid = \"abcd\"\nname = \"agent-1\"\nrules = []\n",
        b,
    );
}

test "sandboxBlock copies the rules text as it is" {
    const rules =
        \\rules = [
        \\  { host = "slack.com", secret = "slack" },
        \\]
    ;
    const b = (try sandboxBlock(testing.allocator, "abcd", "agent-1", rules)).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(
        "[[sandbox]]\nid = \"abcd\"\nname = \"agent-1\"\n" ++ rules ++ "\n",
        b,
    );
}

test "tomlString escapes quotes and backslashes; tomlSafe refuses control characters" {
    const q = try tomlString(testing.allocator, "a\"b\\c");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", q);
    try testing.expect(tomlSafe("a\"b\\c"));
    try testing.expect(!tomlSafe("a\nb"));
    try testing.expect(!tomlSafe("a\x7fb"));
}

test "sandboxBlock refuses a name that can't be a TOML string" {
    try testing.expect((try sandboxBlock(testing.allocator, "abcd", "bad\nname", null)) == null);
}

test "genValue is the time and random bytes in hex" {
    const v = try genValue(testing.allocator, 1700000000, .{ 0, 1, 2, 3, 4, 5, 0xfe, 0xff });
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("1700000000-000102030405feff", v);
}

test "sandboxKey is broker-sandbox. and the name" {
    const k = try sandboxKey(testing.allocator, "agent-1");
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("broker-sandbox.agent-1", k);
}

test "enabled needs a harness other than jump and all three settings" {
    try testing.expect(enabled("claude", "a1", "/ca.pem", "datum://p/c"));
    try testing.expect(!enabled(jumpbox.harness, "a1", "/ca.pem", "datum://p/c"));
    try testing.expect(!enabled("claude", "", "/ca.pem", "datum://p/c"));
    try testing.expect(!enabled("claude", "a1", "", "datum://p/c"));
    try testing.expect(!enabled("claude", "a1", "/ca.pem", ""));
}

test "rulesText: blank broker-rules is no rules" {
    try testing.expect(rulesText(" \n\t") == null);
    try testing.expectEqualStrings("rules = []", rulesText("\nrules = []\n").?);
}
