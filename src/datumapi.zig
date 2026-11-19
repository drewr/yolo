//! Datum API access for datum:// Configs (`yolo cfg`): HTTPS to the Datum
//! control-plane API with a bearer token. The token comes from a service
//! account's credentials file when YOLO_DATUM_CREDENTIALS names one (an RS256
//! JWT exchanged at the auth server's token endpoint, found by OIDC discovery);
//! otherwise from `datumctl auth get-token`, run from PATH (the host's own
//! datumctl, which honours DATUM_SESSION itself). Tokens live in memory only.
//!
//! Pure part first, then the IO boundary. No error message carries a token, a
//! JWT, credentials or a Secret value: errors name the operation, the HTTP
//! status and the server's Status or OAuth message, nothing more.

const std = @import("std");
const mem = std.mem;

const config = @import("config.zig");
const json = @import("json.zig");
const jwt = @import("jwt.zig");
const util = @import("util.zig");

const Ctx = util.Ctx;
const Kind = config.Kind;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

pub const default_api = "https://api.datum.net";
pub const default_auth = "https://auth.datum.net";
pub const default_scope = "openid profile email offline_access";
/// Largest response body read; anything bigger fails the command.
pub const max_body = 4 * 1024 * 1024;
const max_credentials = 64 * 1024;
const max_message = 256;

const jwt_bearer_grant = "urn:ietf:params:oauth:grant-type:jwt-bearer";
const merge_patch_type = "application/merge-patch+json";
const json_type = "application/json";
const form_type = "application/x-www-form-urlencoded";

/// The Kubernetes kind of an entry's object.
pub fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .secret => "Secret",
        .plain => "ConfigMap",
    };
}

/// The namespace-default collection of Secrets or ConfigMaps in a project.
pub fn collectionUrl(allocator: mem.Allocator, api: []const u8, project: []const u8, kind: Kind) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/apis/resourcemanager.miloapis.com/v1alpha1/projects/{s}/control-plane/api/v1/namespaces/default/{s}",
        .{ mem.trimEnd(u8, api, "/"), project, kind.datumResource() },
    );
}

/// One Secret or ConfigMap, by name.
pub fn objectUrl(allocator: mem.Allocator, api: []const u8, project: []const u8, kind: Kind, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ try collectionUrl(allocator, api, project, kind), name });
}

/// The value as the API stores it: base64 for a Secret, the string itself for a
/// ConfigMap. The JSON writer escapes it.
fn writeData(allocator: mem.Allocator, s: *std.json.Stringify, kind: Kind, value: []const u8) !void {
    switch (kind) {
        .secret => try s.write(try util.b64encode(allocator, value)),
        .plain => try s.write(value),
    }
}

/// The merge-patch body that sets one key of an existing object's `data`.
pub fn patchBody(allocator: mem.Allocator, kind: Kind, key: []const u8, value: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("data");
    try s.beginObject();
    try s.objectField(key);
    try writeData(allocator, &s, kind, value);
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}

/// The body that creates the object, with one key in `data`, for a POST to the
/// collection when the object doesn't exist yet.
pub fn createBody(allocator: mem.Allocator, kind: Kind, name: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("apiVersion");
    try s.write("v1");
    try s.objectField("kind");
    try s.write(kindName(kind));
    if (kind == .secret) {
        try s.objectField("type");
        try s.write("Opaque");
    }
    try s.objectField("metadata");
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.endObject();
    try s.objectField("data");
    try s.beginObject();
    try s.objectField(key);
    try writeData(allocator, &s, kind, value);
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}

/// A ConfigMap's values are JSON strings, so they must be UTF-8. Secrets take
/// any bytes (base64 on the wire).
pub fn checkValue(kind: Kind, value: []const u8) error{NotUtf8}!void {
    if (kind == .plain and !std.unicode.utf8ValidateSlice(value)) return error.NotUtf8;
}

fn dataObject(root: json.Value) !?std.json.ObjectMap {
    const o = switch (root) {
        .object => |x| x,
        else => return error.NotAnObject,
    };
    const d = o.get("data") orelse return null;
    return switch (d) {
        .object => |x| x,
        .null => null,
        else => error.BadData,
    };
}

/// The value of KEY in a GET response's `data`: the decoded bytes for a Secret,
/// the string for a ConfigMap. Null when the object has no such key.
pub fn dataValue(allocator: mem.Allocator, body: []const u8, kind: Kind, key: []const u8) !?[]const u8 {
    const root = json.parse(allocator, body) orelse return error.BadJson;
    const data = (try dataObject(root)) orelse return null;
    const v = data.get(key) orelse return null;
    const s = switch (v) {
        .string => |x| x,
        else => return error.BadData,
    };
    if (kind == .plain) return s;
    return util.b64decode(allocator, s) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadData,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return mem.lessThan(u8, a, b);
}

/// The valid keys in a GET response's `data`, sorted. Empty when there is none.
pub fn dataKeys(allocator: mem.Allocator, body: []const u8) ![]const []const u8 {
    const root = json.parse(allocator, body) orelse return error.BadJson;
    const data = (try dataObject(root)) orelse return &.{};
    var keys: std.ArrayList([]const u8) = .empty;
    for (data.keys()) |k| {
        if (config.validKey(k)) try keys.append(allocator, k);
    }
    mem.sort([]const u8, keys.items, {}, lessThan);
    return keys.items;
}

/// The first max_message bytes, backed off to a UTF-8 boundary so a multi-byte
/// sequence is never cut in half.
fn cap(s: []const u8) []const u8 {
    if (s.len <= max_message) return s;
    var end: usize = max_message;
    // s[end] is the first byte dropped; a continuation byte there means the
    // sequence it belongs to starts before `end`, so drop that sequence too.
    while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

/// The host's text, empty when the URL has none.
fn hostText(uri: std.Uri) []const u8 {
    const host = uri.host orelse return "";
    return switch (host) {
        inline else => |s| s,
    };
}

/// Parse an https URL with a host. Anything else is refused before it can carry
/// a token or an assertion.
pub fn requireHttps(url: []const u8) error{ NotHttps, BadUrl }!std.Uri {
    const uri = std.Uri.parse(url) catch return error.BadUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.NotHttps;
    if (hostText(uri).len == 0) return error.BadUrl;
    return uri;
}

/// Whether two URLs name the same origin: scheme and host (case-insensitive)
/// and effective port (443 when absent).
pub fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and
        std.ascii.eqlIgnoreCase(hostText(a), hostText(b)) and
        (a.port orelse 443) == (b.port orelse 443);
}

/// The `message` of a Kubernetes Status body, cut to a short length; null when
/// there is none (a body that isn't JSON, say).
pub fn statusMessage(allocator: mem.Allocator, body: []const u8) ?[]const u8 {
    const root = json.parse(allocator, body) orelse return null;
    const m = json.str(&.{"message"}, root);
    if (m.len == 0) return null;
    return cap(m);
}

pub const OAuthError = struct {
    code: []const u8,
    description: []const u8,
};

/// An OAuth error response's `error` and `error_description`.
pub fn oauthError(allocator: mem.Allocator, body: []const u8) ?OAuthError {
    const root = json.parse(allocator, body) orelse return null;
    const code = json.str(&.{"error"}, root);
    if (code.len == 0) return null;
    return .{
        .code = cap(code),
        .description = cap(json.str(&.{"error_description"}, root)),
    };
}

/// The one-line message for an error response: the OAuth error when the body is
/// one, else the Status message; null when neither is there.
pub fn errorText(allocator: mem.Allocator, body: []const u8) !?[]const u8 {
    if (oauthError(allocator, body)) |e| {
        if (e.description.len == 0) return e.code;
        return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ e.code, e.description });
    }
    return statusMessage(allocator, body);
}

/// The token-exchange form body: the JWT bearer grant, the assertion and the
/// scope, URL-encoded. The scope is the credentials' own, else the default.
pub fn tokenForm(allocator: mem.Allocator, assertion: []const u8, scope: ?[]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    try w.writeAll("grant_type=");
    try formEncode(w, jwt_bearer_grant);
    try w.writeAll("&assertion=");
    try formEncode(w, assertion);
    try w.writeAll("&scope=");
    try formEncode(w, scope orelse default_scope);
    return aw.toOwnedSlice();
}

/// application/x-www-form-urlencoded: unreserved characters as they are, every
/// other byte as %XX.
pub fn formEncode(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or mem.indexOfScalar(u8, "-._~", c) != null) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

pub const Token = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
};

/// A token response. The token type defaults to Bearer, the lifetime to 0.
pub fn parseToken(allocator: mem.Allocator, body: []const u8) !Token {
    const root = json.parse(allocator, body) orelse return error.BadJson;
    const tok = json.str(&.{"access_token"}, root);
    if (tok.len == 0) return error.NoToken;
    const ty = json.str(&.{"token_type"}, root);
    const expires: i64 = switch (json.at(&.{"expires_in"}, root)) {
        .integer => |n| n,
        else => 0,
    };
    return .{
        .access_token = tok,
        .token_type = if (ty.len == 0) "Bearer" else ty,
        .expires_in = expires,
    };
}

/// The `token_endpoint` of an OIDC discovery document.
pub fn tokenEndpoint(allocator: mem.Allocator, body: []const u8) ![]const u8 {
    const root = json.parse(allocator, body) orelse return error.BadJson;
    const e = json.str(&.{"token_endpoint"}, root);
    if (e.len == 0) return error.NoEndpoint;
    return e;
}

test "requireHttps accepts an https URL with a host and refuses the rest" {
    const u = try requireHttps("HTTPS://api.datum.net/x");
    try std.testing.expectEqualStrings("HTTPS", u.scheme);
    try std.testing.expectError(error.NotHttps, requireHttps("http://api.datum.net"));
    try std.testing.expectError(error.NotHttps, requireHttps("ftp://api.datum.net"));
    try std.testing.expectError(error.BadUrl, requireHttps("https://"));
    try std.testing.expectError(error.BadUrl, requireHttps("api.datum.net"));
}

test "sameOrigin compares scheme, host (any case) and effective port" {
    const base = try std.Uri.parse("https://Auth.Example/oauth");
    try std.testing.expect(sameOrigin(base, try std.Uri.parse("https://auth.example:443/token")));
    try std.testing.expect(!sameOrigin(base, try std.Uri.parse("https://auth.example:8443/token")));
    try std.testing.expect(!sameOrigin(base, try std.Uri.parse("https://api.example/token")));
    try std.testing.expect(!sameOrigin(base, try std.Uri.parse("http://auth.example/token")));
}

test "cap cuts at max_message and never inside a UTF-8 sequence" {
    const short = "short";
    try std.testing.expectEqualStrings(short, cap(short));
    // 'é' is two bytes (0xC3 0xA9) starting at byte 255: a cut at 256 would split it.
    var split: [257]u8 = undefined;
    @memset(split[0..255], 'a');
    split[255..257].* = "é".*;
    try std.testing.expectEqual(@as(usize, 255), cap(&split).len);
    // The same character ending at byte 256 is kept whole.
    var whole: [258]u8 = undefined;
    @memset(whole[0..254], 'a');
    whole[254..256].* = "é".*;
    @memset(whole[256..], 'x');
    try std.testing.expectEqual(@as(usize, 256), cap(&whole).len);
}

/// An RFC 4122 version 4 UUID text from 16 random bytes.
pub fn uuidV4(bytes: [16]u8) [36]u8 {
    var b = bytes;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var o: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[byte >> 4];
        out[o + 1] = hex[byte & 0x0f];
        o += 2;
    }
    return out;
}

test "object and collection URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "https://api.datum.net/apis/resourcemanager.miloapis.com/v1alpha1/projects/p-test/control-plane/api/v1/namespaces/default/secrets",
        try collectionUrl(a, default_api, "p-test", .secret),
    );
    try std.testing.expectEqualStrings(
        "https://api.example/apis/resourcemanager.miloapis.com/v1alpha1/projects/p-test/control-plane/api/v1/namespaces/default/configmaps/yolo-box",
        try objectUrl(a, "https://api.example/", "p-test", .plain, "yolo-box"),
    );
}

test "patch body: a Secret value is base64, a ConfigMap value is an escaped string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "{\"data\":{\"k\":\"aGk=\"}}",
        try patchBody(a, .secret, "k", "hi"),
    );
    try std.testing.expectEqualStrings(
        "{\"data\":{\"k\":\"a\\nb\\\"c\"}}",
        try patchBody(a, .plain, "k", "a\nb\"c"),
    );
}

test "create body for a Secret and for a ConfigMap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"type\":\"Opaque\",\"metadata\":{\"name\":\"p-test\"},\"data\":{\"k\":\"aGk=\"}}",
        try createBody(a, .secret, "p-test", "k", "hi"),
    );
    try std.testing.expectEqualStrings(
        "{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"p-test\"},\"data\":{\"k\":\"v\"}}",
        try createBody(a, .plain, "p-test", "k", "v"),
    );
}

test "plain values must be UTF-8" {
    try checkValue(.plain, "héllo");
    try checkValue(.secret, "\xff\x00");
    try std.testing.expectError(error.NotUtf8, checkValue(.plain, "\xff"));
}

test "dataValue reads a key, decoding a Secret's base64" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("v\nw", (try dataValue(a, "{\"data\":{\"k\":\"v\\nw\"}}", .plain, "k")).?);
    try std.testing.expectEqualStrings("hi", (try dataValue(a, "{\"data\":{\"k\":\"aGk=\"}}", .secret, "k")).?);
    try std.testing.expect((try dataValue(a, "{\"data\":{\"k\":\"aGk=\"}}", .secret, "other")) == null);
    try std.testing.expect((try dataValue(a, "{}", .secret, "k")) == null);
    try std.testing.expect((try dataValue(a, "{\"data\":null}", .plain, "k")) == null);
    try std.testing.expectError(error.BadData, dataValue(a, "{\"data\":{\"k\":\"!!\"}}", .secret, "k"));
    try std.testing.expectError(error.BadData, dataValue(a, "{\"data\":{\"k\":5}}", .plain, "k"));
    try std.testing.expectError(error.NotAnObject, dataValue(a, "[1]", .plain, "k"));
    try std.testing.expectError(error.BadJson, dataValue(a, "<html>", .plain, "k"));
}

test "dataKeys lists the valid keys, sorted; missing data is empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const keys = try dataKeys(a, "{\"data\":{\"b\":\"1\",\"a\":\"2\",\"not ok\":\"3\"}}");
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("b", keys[1]);
    try std.testing.expectEqual(@as(usize, 0), (try dataKeys(a, "{}")).len);
}

test "error messages come from Status and OAuth bodies only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "forbidden: nope",
        (statusMessage(a, "{\"kind\":\"Status\",\"code\":403,\"message\":\"forbidden: nope\"}")).?,
    );
    try std.testing.expect(statusMessage(a, "<html>") == null);
    try std.testing.expectEqualStrings(
        "invalid_grant: expired",
        (try errorText(a, "{\"error\":\"invalid_grant\",\"error_description\":\"expired\"}")).?,
    );
    try std.testing.expectEqualStrings(
        "forbidden: x",
        (try errorText(a, "{\"message\":\"forbidden: x\"}")).?,
    );
    try std.testing.expect((try errorText(a, "{}")) == null);
}

test "token form is URL-encoded with the default or the credentials' scope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=a.b-c_d~e%2Bf&scope=openid%20profile%20email%20offline_access",
        try tokenForm(a, "a.b-c_d~e+f", null),
    );
    try std.testing.expect(mem.endsWith(u8, try tokenForm(a, "x", "x y"), "&scope=x%20y"));
}

test "token response and OIDC discovery parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = try parseToken(a, "{\"access_token\":\"tok\",\"token_type\":\"Bearer\",\"expires_in\":43199}");
    try std.testing.expectEqualStrings("tok", t.access_token);
    try std.testing.expectEqualStrings("Bearer", t.token_type);
    try std.testing.expectEqual(@as(i64, 43199), t.expires_in);
    try std.testing.expectError(error.NoToken, parseToken(a, "{\"error\":\"x\"}"));
    try std.testing.expectEqualStrings(
        "https://auth.example/oauth/v2/token",
        try tokenEndpoint(a, "{\"token_endpoint\":\"https://auth.example/oauth/v2/token\"}"),
    );
    try std.testing.expectError(error.NoEndpoint, tokenEndpoint(a, "{}"));
}

test "uuidV4 sets the version and variant bits" {
    const zero: [16]u8 = @splat(0);
    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", &uuidV4(zero));
    const ones: [16]u8 = @splat(0xff);
    try std.testing.expectEqualStrings("ffffffff-ffff-4fff-bfff-ffffffffffff", &uuidV4(ones));
}

// ---------------------------------------------------------------------------
// IO boundary
// ---------------------------------------------------------------------------

const Response = struct {
    status: u16,
    body: []u8,
};

fn apiBase(ctx: Ctx) []const u8 {
    const v = mem.trimEnd(u8, ctx.opt("DATUM_API", default_api), "/");
    _ = requireHttps(v) catch util.die("cfg: YOLO_DATUM_API must be an https:// URL");
    return v;
}

fn authBase(ctx: Ctx) []const u8 {
    const v = mem.trimEnd(u8, ctx.opt("DATUM_AUTH", default_auth), "/");
    _ = requireHttps(v) catch util.die("cfg: YOLO_DATUM_AUTH must be an https:// URL");
    return v;
}

/// Use the CA bundle that SSL_CERT_FILE (else NIX_SSL_CERT_FILE) names. std's
/// client ignores those variables and always rescans the system's bundle. Once
/// `now` is set the client keeps the bundle it was given instead of rescanning.
fn configureCa(ctx: Ctx, client: *std.http.Client) void {
    const path = ctx.envNonEmpty("SSL_CERT_FILE") orelse ctx.envNonEmpty("NIX_SSL_CERT_FILE") orelse return;
    const now = util.realNow(ctx);
    var cb: std.crypto.Certificate.Bundle = .empty;
    cb.addCertsFromFilePath(ctx.gpa, ctx.io, now, std.Io.Dir.cwd(), path) catch |e|
        util.dief("cfg: can't load the CA bundle {s}: {t}", .{ path, e });
    client.ca_bundle = cb;
    client.now = now;
}

/// One HTTP request. The body is capped at max_body; the call dies on a
/// transport error, and the caller checks the status.
fn send(
    ctx: Ctx,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    token: ?[]const u8,
    content_type: ?[]const u8,
    payload: ?[]const u8,
) Response {
    const buf = ctx.arena.alloc(u8, max_body) catch util.die("out of memory");
    var w: std.Io.Writer = .fixed(buf);

    // std sends only `extra_headers` on the first request (`privileged_headers`
    // are kept for redirects, which are off here), so the bearer goes there.
    var extra: [3]std.http.Header = undefined;
    var n_extra: usize = 0;
    var auth_value: []u8 = &.{};
    if (token) |t| {
        auth_value = std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{t}) catch util.die("out of memory");
        extra[n_extra] = .{ .name = "authorization", .value = auth_value };
        n_extra += 1;
    }
    extra[n_extra] = .{ .name = "accept", .value = json_type };
    n_extra += 1;
    if (content_type) |ct| {
        extra[n_extra] = .{ .name = "content-type", .value = ct };
        n_extra += 1;
    }

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &w,
        .redirect_behavior = .unhandled,
        .extra_headers = extra[0..n_extra],
    }) catch |e| switch (e) {
        error.WriteFailed => util.dief("cfg: {s} response is larger than {d} bytes", .{ @tagName(method), max_body }),
        else => util.dief("cfg: {s} request failed: {t}", .{ @tagName(method), e }),
    };
    if (auth_value.len != 0) std.crypto.secureZero(u8, auth_value);
    return .{ .status = @intCast(@backingInt(res.status)), .body = w.buffered() };
}

/// Where the bearer token comes from: the service account file when
/// YOLO_DATUM_CREDENTIALS names one, else datumctl.
fn bearer(ctx: Ctx, client: *std.http.Client) []const u8 {
    const creds = ctx.opt("DATUM_CREDENTIALS", "");
    if (creds.len == 0) return datumctlToken(ctx);
    return serviceAccountToken(ctx, client, creds);
}

fn datumctlToken(ctx: Ctx) []const u8 {
    const r = util.capture(ctx, &.{ "datumctl", "auth", "get-token", "-o", "token" }, .{ .timeout_ms = 30_000 }) catch
        util.die("cfg: can't run datumctl (it must be on PATH, or set YOLO_DATUM_CREDENTIALS)");
    if (r.term != .exited or r.code != 0)
        util.die("cfg: datumctl auth get-token failed: run `datumctl login`, or set YOLO_DATUM_CREDENTIALS");
    const tok = util.trim(r.stdout);
    if (tok.len == 0) util.die("cfg: datumctl gave no token");
    return tok;
}

/// Refuse a credentials file that others can read or write, as ssh does for keys.
fn requirePrivate(ctx: Ctx, path: []const u8) void {
    const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch |e|
        util.dief("cfg: can't stat the credentials file {s}: {t}", .{ path, e });
    if (st.kind != .file) util.dief("cfg: {s} isn't a regular file", .{path});
    const mode = st.permissions.toMode() & 0o777;
    if (mode & 0o077 != 0)
        util.dief("cfg: {s} is readable or writable by others (mode {o:0>3}); chmod 600 it", .{ path, mode });
}

/// The token exchange for a service account: sign an RS256 JWT with the
/// credentials, POST it to the token endpoint, and return the access token.
/// The credentials text and the assertion are wiped after use.
fn serviceAccountToken(ctx: Ctx, client: *std.http.Client, path: []const u8) []const u8 {
    requirePrivate(ctx, path);
    const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(max_credentials)) catch |e|
        util.dief("cfg: can't read the credentials file {s}: {t}", .{ path, e });
    defer std.crypto.secureZero(u8, raw);
    const creds = jwt.parseCredentials(ctx.arena, raw) catch |e|
        util.dief("cfg: {s} isn't a Datum service account credentials file ({t})", .{ path, e });

    const auth = authBase(ctx);
    const discovery_url = std.fmt.allocPrint(ctx.arena, "{s}/.well-known/openid-configuration", .{auth}) catch
        util.die("out of memory");
    const disc = send(ctx, client, .GET, discovery_url, null, null, null);
    if (disc.status != 200) util.dief("cfg: OIDC discovery at {s} failed: HTTP {d}", .{ auth, disc.status });
    const endpoint = tokenEndpoint(ctx.arena, disc.body) catch
        util.die("cfg: the OIDC discovery document has no token_endpoint");
    // The assertion is a credential: send it only to the auth server's own origin.
    const on_auth_origin = blk: {
        const e = requireHttps(endpoint) catch break :blk false;
        const a = requireHttps(auth) catch break :blk false;
        break :blk sameOrigin(e, a);
    };
    if (!on_auth_origin)
        util.dief("cfg: the token endpoint from {s} isn't on that server; refusing to send the assertion there", .{auth});

    var jti_bytes: [16]u8 = undefined;
    util.randomBytes(ctx, &jti_bytes) catch util.die("cfg: can't read random bytes for the token request");
    const jti = uuidV4(jti_bytes);
    const iat = util.realNow(ctx).toSeconds();
    const assertion = jwt.mint(ctx.arena, creds, auth, iat, &jti) catch |e|
        util.dief("cfg: can't sign the token request ({t}); check {s}", .{ e, path });
    defer std.crypto.secureZero(u8, assertion);
    const form = tokenForm(ctx.arena, assertion, creds.scope) catch util.die("out of memory");

    const r = send(ctx, client, .POST, endpoint, null, form_type, form);
    if (r.status != 200) failStatus(ctx, "token exchange", r);
    const tok = parseToken(ctx.arena, r.body) catch
        util.die("cfg: the token response has no access_token");
    const out = ctx.arena.dupe(u8, tok.access_token) catch util.die("out of memory");
    std.crypto.secureZero(u8, r.body);
    return out;
}

fn credentialHint(ctx: Ctx) []const u8 {
    if (ctx.opt("DATUM_CREDENTIALS", "").len != 0)
        return " (check the service account in YOLO_DATUM_CREDENTIALS and its role bindings)";
    return " (check `datumctl whoami` and the active project, or set YOLO_DATUM_CREDENTIALS)";
}

/// The operation, the status and the server's own message, for a failed
/// response. The body is never echoed.
fn failText(ctx: Ctx, what: []const u8, r: Response) []const u8 {
    const text = errorText(ctx.arena, r.body) catch null;
    const hint: []const u8 = if (r.status == 401 or r.status == 403) credentialHint(ctx) else "";
    if (text) |t| {
        return std.fmt.allocPrint(ctx.arena, "cfg: {s} failed: HTTP {d}: {s}{s}", .{ what, r.status, t, hint }) catch "cfg: request failed";
    }
    return std.fmt.allocPrint(ctx.arena, "cfg: {s} failed: HTTP {d}{s}", .{ what, r.status, hint }) catch "cfg: request failed";
}

/// Die with the failed response's text (`failText`).
fn failStatus(ctx: Ctx, what: []const u8, r: Response) noreturn {
    util.die(failText(ctx, what, r));
}

/// A new client with its CA bundle configured. The caller deinits it.
fn prepare(ctx: Ctx, client: *std.http.Client) []const u8 {
    // Checked before any token is fetched: datumctl runs below.
    _ = apiBase(ctx);
    client.* = .{ .allocator = ctx.gpa, .io = ctx.io };
    configureCa(ctx, client);
    return bearer(ctx, client);
}

/// The object's response, or null when the object doesn't exist.
fn fetchObject(ctx: Ctx, client: *std.http.Client, token: []const u8, project: []const u8, name: []const u8, kind: Kind) ?Response {
    const url = objectUrl(ctx.arena, apiBase(ctx), project, kind, name) catch util.die("out of memory");
    const r = send(ctx, client, .GET, url, token, null, null);
    if (r.status == 404) return null;
    if (r.status != 200) {
        const what = std.fmt.allocPrint(ctx.arena, "read {s} {s}", .{ kindName(kind), name }) catch util.die("out of memory");
        failStatus(ctx, what, r);
    }
    return r;
}

/// `yolo cfg get`: the raw value of one entry.
pub fn get(ctx: Ctx, project: []const u8, name: []const u8, kind: Kind, key: []const u8) u8 {
    var client: std.http.Client = undefined;
    defer client.deinit();
    const token = prepare(ctx, &client);
    const r = fetchObject(ctx, &client, token, project, name, kind) orelse
        util.dief("cfg: no {s} entry {s}", .{ kind.dirName(), key });
    const found = dataValue(ctx.arena, r.body, kind, key) catch
        util.dief("cfg: can't read {s} {s}: not the JSON the API sends", .{ kindName(kind), name });
    const value = found orelse util.dief("cfg: no {s} entry {s}", .{ kind.dirName(), key });
    util.outRaw(value);
    return 0;
}

/// `yolo cfg put`: set one entry, creating the object when it doesn't exist.
/// The value is never printed.
pub fn put(ctx: Ctx, project: []const u8, name: []const u8, kind: Kind, key: []const u8, value: []const u8) u8 {
    checkValue(kind, value) catch
        util.die("cfg: a plain entry must be valid UTF-8; use --secret for binary values");
    if (tryPut(ctx, project, name, kind, key, value)) |msg| util.die(msg);
    return 0;
}

/// `put` that returns its failure text instead of dying, for a caller that
/// must clean up first. Null on success. The text never carries the value.
pub fn tryPut(ctx: Ctx, project: []const u8, name: []const u8, kind: Kind, key: []const u8, value: []const u8) ?[]const u8 {
    checkValue(kind, value) catch return "cfg: a plain entry must be valid UTF-8";
    var client: std.http.Client = undefined;
    defer client.deinit();
    const token = prepare(ctx, &client);
    const url = objectUrl(ctx.arena, apiBase(ctx), project, kind, name) catch util.die("out of memory");
    const patch = patchBody(ctx.arena, kind, key, value) catch util.die("out of memory");

    var r = send(ctx, &client, .PATCH, url, token, merge_patch_type, patch);
    if (r.status == 404) {
        const coll = collectionUrl(ctx.arena, apiBase(ctx), project, kind) catch util.die("out of memory");
        const create = createBody(ctx.arena, kind, name, key, value) catch util.die("out of memory");
        r = send(ctx, &client, .POST, coll, token, json_type, create);
        // Another writer created it between the PATCH and the POST: patch it once more.
        if (r.status == 409) r = send(ctx, &client, .PATCH, url, token, merge_patch_type, patch);
    }
    if (r.status < 200 or r.status > 299) {
        const what = std.fmt.allocPrint(ctx.arena, "write {s} {s}", .{ kindName(kind), name }) catch util.die("out of memory");
        return failText(ctx, what, r);
    }
    return null;
}

/// `yolo cfg list`: the sorted keys of one kind. A missing object lists nothing.
pub fn list(ctx: Ctx, project: []const u8, name: []const u8, kind: Kind) u8 {
    var client: std.http.Client = undefined;
    defer client.deinit();
    const token = prepare(ctx, &client);
    const r = fetchObject(ctx, &client, token, project, name, kind) orelse return 0;
    const keys = dataKeys(ctx.arena, r.body) catch
        util.dief("cfg: can't read {s} {s}: not the JSON the API sends", .{ kindName(kind), name });
    for (keys) |k| util.say(k);
    return 0;
}
