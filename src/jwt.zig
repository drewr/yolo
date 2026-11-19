//! RS256 JWTs for Datum service-account login: the credentials file, the RSA
//! private key in PEM (PKCS#1 or PKCS#8), RSASSA-PKCS1-v1_5 with SHA-256, and
//! the compact JWT that the token exchange sends.
//!
//! Pure: no network, no clock, no randomness. The caller passes `iat`, the
//! `jti` and the credentials text; the HTTP exchange lives elsewhere. Nothing
//! here prints, and every error is a plain tag, so a key's bytes never reach an
//! error message.

const std = @import("std");
const json = @import("json.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

/// std.crypto.ff's fixed-width field: 4096 bits is the largest modulus accepted
/// (`parsePkcs1` refuses more), so every modulus fits.
const Mod = std.crypto.ff.Modulus(4096);
const Fe = Mod.Fe;
const max_modulus_bytes = 512;

pub const datum_credentials_type = "datum_service_account";

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// The fields of a Datum service-account credentials file that login uses.
/// Slices point into the parsed JSON, which the caller's allocator owns.
pub const Credentials = struct {
    client_id: []const u8,
    private_key_id: []const u8,
    private_key: []const u8,
    client_email: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    token_uri: ?[]const u8 = null,
    api_endpoint: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
};

pub const CredentialsError = error{
    BadJson,
    NotAnObject,
    WrongCredentialsType,
    MissingField,
    WrongType,
};

/// Parse a Datum service-account credentials file. `type` must be
/// `datum_service_account`; `client_id`, `private_key_id` and `private_key` must
/// be non-empty strings. The optional fields may be absent or null.
pub fn parseCredentials(allocator: Allocator, text: []const u8) CredentialsError!Credentials {
    const root = json.parse(allocator, text) orelse return error.BadJson;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const kind = try requiredString(obj, "type");
    if (!std.mem.eql(u8, kind, datum_credentials_type)) return error.WrongCredentialsType;
    return .{
        .client_id = try requiredString(obj, "client_id"),
        .private_key_id = try requiredString(obj, "private_key_id"),
        .private_key = try requiredString(obj, "private_key"),
        .client_email = try optionalString(obj, "client_email"),
        .scope = try optionalString(obj, "scope"),
        .token_uri = try optionalString(obj, "token_uri"),
        .api_endpoint = try optionalString(obj, "api_endpoint"),
        .project_id = try optionalString(obj, "project_id"),
    };
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8) CredentialsError![]const u8 {
    const s = (try optionalString(obj, key)) orelse return error.MissingField;
    if (s.len == 0) return error.MissingField;
    return s;
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) CredentialsError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => error.WrongType,
    };
}

/// Errors from reading DER. The reader accepts only definite, minimal lengths
/// and positive, minimally encoded INTEGERs, and never reads past its input.
pub const DerError = error{
    Truncated,
    UnexpectedTag,
    IndefiniteLength,
    NonMinimalLength,
    LengthTooLong,
    EmptyInteger,
    NegativeInteger,
    NonMinimalInteger,
    ZeroInteger,
    TrailingData,
};

const tag_integer: u8 = 0x02;
const tag_octet_string: u8 = 0x04;
const tag_null: u8 = 0x05;
const tag_oid: u8 = 0x06;
const tag_sequence: u8 = 0x30;

/// rsaEncryption, 1.2.840.113549.1.1.1 (the OID's content bytes).
const rsa_encryption_oid = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

/// A cursor over DER bytes. A length is the short form (under 128) or the
/// minimal long form of at most four octets; indefinite lengths are refused.
pub const DerReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn atEnd(r: DerReader) bool {
        return r.pos == r.bytes.len;
    }

    /// The content of the next element, which must carry `tag`.
    pub fn tlv(r: *DerReader, tag: u8) DerError![]const u8 {
        if (r.pos >= r.bytes.len) return error.Truncated;
        if (r.bytes[r.pos] != tag) return error.UnexpectedTag;
        r.pos += 1;
        const len = try r.length();
        if (len > r.bytes.len - r.pos) return error.Truncated;
        const content = r.bytes[r.pos..][0..len];
        r.pos += len;
        return content;
    }

    /// The magnitude of the next INTEGER, big-endian and without its sign byte.
    /// Negative values, and a leading zero that does not clear the sign bit, are
    /// refused. Zero comes back as the single byte 0.
    pub fn integer(r: *DerReader) DerError![]const u8 {
        const c = try r.tlv(tag_integer);
        if (c.len == 0) return error.EmptyInteger;
        if ((c[0] & 0x80) != 0) return error.NegativeInteger;
        if (c[0] == 0 and c.len > 1) {
            if ((c[1] & 0x80) == 0) return error.NonMinimalInteger;
            return c[1..];
        }
        return c;
    }

    /// Like `integer`, but zero is refused too.
    pub fn positive(r: *DerReader) DerError![]const u8 {
        const v = try r.integer();
        if (isZeroInteger(v)) return error.ZeroInteger;
        return v;
    }

    fn length(r: *DerReader) DerError!usize {
        if (r.pos >= r.bytes.len) return error.Truncated;
        const first = r.bytes[r.pos];
        r.pos += 1;
        if (first < 0x80) return first;
        if (first == 0x80) return error.IndefiniteLength;
        const n: usize = first & 0x7f;
        if (n > 4) return error.LengthTooLong;
        if (n > r.bytes.len - r.pos) return error.Truncated;
        const octets = r.bytes[r.pos..][0..n];
        r.pos += n;
        if (octets[0] == 0) return error.NonMinimalLength;
        var len: usize = 0;
        for (octets) |b| len = (len << 8) | b;
        if (len < 0x80) return error.NonMinimalLength;
        return len;
    }
};

fn isZeroInteger(v: []const u8) bool {
    return v.len == 1 and v[0] == 0;
}

/// The parts of an RSAPrivateKey (PKCS#1). Each slice is a big-endian magnitude
/// pointing into the DER it was parsed from. `bits` is the modulus length.
pub const RsaKey = struct {
    n: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
    bits: usize,
};

pub const KeyError = DerError || error{
    NotPem,
    BadPem,
    BadBase64,
    EncryptedKey,
    UnsupportedKey,
    UnsupportedVersion,
    BadModulusSize,
    BadExponent,
    OutOfMemory,
};

/// Parse a PKCS#1 RSAPrivateKey (RFC 8017 A.1.2). Only version 0 (two-prime) is
/// accepted: a multi-prime key (version 1) has more fields and is refused. The
/// modulus must be 2048 to 4096 bits, and the public exponent odd, at least 3,
/// and at most 32 bits.
pub fn parsePkcs1(der: []const u8) KeyError!RsaKey {
    var outer: DerReader = .{ .bytes = der };
    const body = try outer.tlv(tag_sequence);
    if (!outer.atEnd()) return error.TrailingData;
    var r: DerReader = .{ .bytes = body };
    const version = try r.integer();
    if (!isZeroInteger(version)) return error.UnsupportedVersion;
    const n = try r.positive();
    const e = try r.positive();
    const d = try r.positive();
    const p = try r.positive();
    const q = try r.positive();
    const dp = try r.positive();
    const dq = try r.positive();
    const qinv = try r.positive();
    if (!r.atEnd()) return error.TrailingData;
    const bits = try modulusBits(n);
    try checkExponent(e);
    return .{ .n = n, .e = e, .d = d, .p = p, .q = q, .dp = dp, .dq = dq, .qinv = qinv, .bits = bits };
}

fn modulusBits(n: []const u8) KeyError!usize {
    // A positive magnitude has no leading zero byte, so n[0] != 0.
    const top: usize = 8 - @as(usize, @clz(n[0]));
    const bits = (n.len - 1) * 8 + top;
    if (bits < 2048 or bits > 4096) return error.BadModulusSize;
    return bits;
}

fn checkExponent(e: []const u8) KeyError!void {
    if (e.len > 4) return error.BadExponent;
    if ((e[e.len - 1] & 1) == 0) return error.BadExponent;
    if (e.len == 1 and e[0] < 3) return error.BadExponent;
}

/// The PKCS#1 RSAPrivateKey inside a PKCS#8 PrivateKeyInfo for rsaEncryption.
/// Any other algorithm (EC, Ed25519, ...) is refused, as are version 1 and
/// trailing data.
pub fn unwrapPkcs8(der: []const u8) KeyError![]const u8 {
    var outer: DerReader = .{ .bytes = der };
    const body = try outer.tlv(tag_sequence);
    if (!outer.atEnd()) return error.TrailingData;
    var r: DerReader = .{ .bytes = body };
    const version = try r.integer();
    if (!isZeroInteger(version)) return error.UnsupportedVersion;
    const alg = try r.tlv(tag_sequence);
    var a: DerReader = .{ .bytes = alg };
    const oid = try a.tlv(tag_oid);
    if (!std.mem.eql(u8, oid, &rsa_encryption_oid)) return error.UnsupportedKey;
    _ = try a.tlv(tag_null);
    if (!a.atEnd()) return error.TrailingData;
    const inner = try r.tlv(tag_octet_string);
    if (!r.atEnd()) return error.TrailingData;
    return inner;
}

pub const PemKind = enum { pkcs1, pkcs8 };

/// A decoded PEM block. `der` is owned by the caller: `wipe` it when done.
pub const PemBlock = struct {
    kind: PemKind,
    der: []u8,
};

/// Decode a single PEM block. Accepted labels are `RSA PRIVATE KEY` (PKCS#1)
/// and `PRIVATE KEY` (PKCS#8). An encrypted key (`ENCRYPTED PRIVATE KEY`, or a
/// `Proc-Type`/`DEK-Info` header) gets `EncryptedKey`. Other labels get
/// `UnsupportedKey`. Text after the END line is refused.
pub fn decodePem(allocator: Allocator, text: []const u8) KeyError!PemBlock {
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '\n');
    const first = trimLine(lines.next() orelse return error.NotPem);
    const label = pemLabel(first, "BEGIN") orelse return error.NotPem;
    const kind = try pemKind(label);

    var body: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, body.items);
        body.deinit(allocator);
    }
    var ended = false;
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (pemLabel(line, "END")) |end| {
            if (!std.mem.eql(u8, end, label)) return error.BadPem;
            ended = true;
            break;
        }
        if (std.mem.indexOfScalar(u8, line, ':') != null) {
            // Header lines (Proc-Type, DEK-Info) only appear on encrypted keys.
            if (std.mem.indexOf(u8, line, "ENCRYPTED") != null) return error.EncryptedKey;
            return error.BadPem;
        }
        for (line) |c| {
            if (!isSpace(c)) try body.append(allocator, c);
        }
    }
    if (!ended) return error.BadPem;
    while (lines.next()) |rest| {
        if (trimLine(rest).len != 0) return error.TrailingData;
    }

    const size = std.base64.standard.Decoder.calcSizeForSlice(body.items) catch return error.BadBase64;
    const der = try allocator.alloc(u8, size);
    errdefer wipe(allocator, der);
    std.base64.standard.Decoder.decode(der, body.items) catch return error.BadBase64;
    return .{ .kind = kind, .der = der };
}

/// `-----<kind> LABEL-----` on one trimmed line: the LABEL, or null.
fn pemLabel(line: []const u8, comptime kind: []const u8) ?[]const u8 {
    const head = "-----" ++ kind ++ " ";
    if (line.len < head.len + 5) return null;
    if (!std.mem.startsWith(u8, line, head) or !std.mem.endsWith(u8, line, "-----")) return null;
    return line[head.len .. line.len - 5];
}

fn pemKind(label: []const u8) KeyError!PemKind {
    if (std.mem.eql(u8, label, "RSA PRIVATE KEY")) return .pkcs1;
    if (std.mem.eql(u8, label, "PRIVATE KEY")) return .pkcs8;
    if (std.mem.eql(u8, label, "ENCRYPTED PRIVATE KEY")) return error.EncryptedKey;
    return error.UnsupportedKey;
}

fn trimLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Zero a secret buffer, then free it.
fn wipe(allocator: Allocator, buf: []u8) void {
    std.crypto.secureZero(u8, buf);
    allocator.free(buf);
}

/// A parsed private key. `rsa`'s slices point into `der`, the PKCS#1 DER (or
/// the PKCS#8 wrapper of it). `deinit` zeroes and frees `der`.
pub const PrivateKey = struct {
    der: []u8,
    rsa: RsaKey,

    pub fn deinit(key: PrivateKey, allocator: Allocator) void {
        wipe(allocator, key.der);
    }
};

/// PEM text (either PKCS#1 or PKCS#8) to a parsed RSA private key.
pub fn loadPrivateKey(allocator: Allocator, pem_text: []const u8) KeyError!PrivateKey {
    const block = try decodePem(allocator, pem_text);
    errdefer wipe(allocator, block.der);
    const pkcs1 = switch (block.kind) {
        .pkcs1 => block.der,
        .pkcs8 => try unwrapPkcs8(block.der),
    };
    const rsa = try parsePkcs1(pkcs1);
    return .{ .der = block.der, .rsa = rsa };
}

/// DigestInfo for SHA-256 (RFC 8017 section 9.2 note 1): 3031300d060960864801650304020105000420.
pub const sha256_digest_info = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};

/// EMSA-PKCS1-v1_5 encoding (RFC 8017 section 9.2) of `msg` with SHA-256, into
/// `em`, which is the modulus length in bytes.
pub fn encodeEmsaSha256(em: []u8, msg: []const u8) error{ModulusTooShort}!void {
    const t_len = sha256_digest_info.len + Sha256.digest_length;
    if (em.len < t_len + 11) return error.ModulusTooShort;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(msg, &digest, .{});
    const ps_len = em.len - t_len - 3;
    em[0] = 0x00;
    em[1] = 0x01;
    @memset(em[2 .. 2 + ps_len], 0xff);
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len ..][0..sha256_digest_info.len], &sha256_digest_info);
    @memcpy(em[3 + ps_len + sha256_digest_info.len ..], &digest);
}

pub const SignError = error{
    BadPrivateKey,
    ModulusTooShort,
    SignatureCheckFailed,
    OutOfMemory,
};

/// RSASSA-PKCS1-v1_5 signature of `msg` with SHA-256 (RFC 8017 section 8.2.1).
///
/// The private exponent is the secret. It goes through `powWithEncodedExponent`,
/// which std documents as constant time: "Unless side-channels mitigations are
/// explicitly disabled, operations are designed to be constant-time" (the
/// `Uint` doc comment), and the windowed table lookups are selected with
/// constant-time moves when the default `side_channels_mitigations` is in
/// effect. The exponent is read as bytes, so no copy of `d` is made here.
///
/// Before returning, the signature is raised to the public exponent and must
/// give back EM. A fault during the private operation therefore never leaves
/// this function as a signature.
pub fn signRs256(allocator: Allocator, key: RsaKey, msg: []const u8) SignError![]u8 {
    const k = (key.bits + 7) / 8;
    if (k > max_modulus_bytes) return error.BadPrivateKey;
    const em = try allocator.alloc(u8, k);
    defer allocator.free(em);
    try encodeEmsaSha256(em, msg);

    const n = Mod.fromBytes(key.n, .big) catch return error.BadPrivateKey;
    const m = Fe.fromBytes(n, em, .big) catch return error.BadPrivateKey;
    const s = n.powWithEncodedExponent(m, key.d, .big) catch return error.BadPrivateKey;
    const sig = try allocator.alloc(u8, k);
    errdefer allocator.free(sig);
    s.toBytes(sig, .big) catch return error.BadPrivateKey;

    // Fault check: the signature must verify under the public key, that is
    // s^e mod n == EM. The exponent is public, so verifyRs256 takes the
    // variable-time public path.
    if (!verifyRs256(key.n, key.e, msg, sig)) return error.SignatureCheckFailed;
    return sig;
}

/// RSASSA-PKCS1-v1_5 verification with SHA-256 (RFC 8017 section 8.2.2) against
/// the public key `n`, `e` (big-endian magnitudes). `sig` must be exactly the
/// modulus length in bytes. Every failure, including a signature at or above
/// the modulus, is `false`.
pub fn verifyRs256(n_bytes: []const u8, e_bytes: []const u8, msg: []const u8, sig: []const u8) bool {
    const k = n_bytes.len;
    if (k == 0 or k > max_modulus_bytes or sig.len != k) return false;
    var em: [max_modulus_bytes]u8 = undefined;
    encodeEmsaSha256(em[0..k], msg) catch return false;
    const n = Mod.fromBytes(n_bytes, .big) catch return false;
    const s = Fe.fromBytes(n, sig, .big) catch return false;
    const v = n.powWithEncodedPublicExponent(s, e_bytes, .big) catch return false;
    var check: [max_modulus_bytes]u8 = undefined;
    v.toBytes(check[0..k], .big) catch return false;
    return constantTimeEql(check[0..k], em[0..k]);
}

/// Equality of two byte strings in time that depends only on their length.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
}

const Header = struct {
    alg: []const u8,
    kid: []const u8,
    typ: []const u8,
};

const Claims = struct {
    aud: []const u8,
    exp: i64,
    iat: i64,
    iss: []const u8,
    jti: []const u8,
    sub: []const u8,
};

pub const MintError = KeyError || SignError || error{BadTime};

/// An RS256 JWT for the service account in `creds`, as `header.claims.signature`
/// in base64url without padding. The header is `{"alg":"RS256","kid":...,"typ":"JWT"}`
/// and the claims are `{"aud","exp","iat","iss","jti","sub"}` in that order,
/// with `iss` and `sub` set to the client_id and `exp` = `iat` + 60. String
/// values are JSON-escaped. The caller owns the result.
pub fn mint(allocator: Allocator, creds: Credentials, aud: []const u8, iat: i64, jti: []const u8) MintError![]u8 {
    const exp = std.math.add(i64, iat, 60) catch return error.BadTime;
    const header = try std.json.Stringify.valueAlloc(allocator, Header{
        .alg = "RS256",
        .kid = creds.private_key_id,
        .typ = "JWT",
    }, .{});
    defer allocator.free(header);
    const claims = try std.json.Stringify.valueAlloc(allocator, Claims{
        .aud = aud,
        .exp = exp,
        .iat = iat,
        .iss = creds.client_id,
        .jti = jti,
        .sub = creds.client_id,
    }, .{});
    defer allocator.free(claims);

    const h64 = try b64Alloc(allocator, header);
    defer allocator.free(h64);
    const c64 = try b64Alloc(allocator, claims);
    defer allocator.free(c64);
    const signing_input = try std.mem.join(allocator, ".", &.{ h64, c64 });
    defer allocator.free(signing_input);

    var key = try loadPrivateKey(allocator, creds.private_key);
    defer key.deinit(allocator);
    const sig = try signRs256(allocator, key.rsa, signing_input);
    defer allocator.free(sig);
    const s64 = try b64Alloc(allocator, sig);
    defer allocator.free(s64);
    return std.mem.join(allocator, ".", &.{ signing_input, s64 });
}

fn b64Alloc(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, b64.Encoder.calcSize(bytes.len));
    _ = b64.Encoder.encode(out, bytes);
    return out;
}

// ---------------------------------------------------------------------------
// Tests. No private key is written in this file: the RSA and EC keys are built
// at runtime by rsa_testkey.zig from a fixed seed. The openssl vectors below
// carry public keys and signatures only; the key that made them was shredded.
// ---------------------------------------------------------------------------

const testing = std.testing;
const rsa_testkey = @import("rsa_testkey.zig");

const label_rsa = "RSA PRIVATE KEY";
const begin_rsa = "-----BEGIN " ++ label_rsa ++ "-----\n";

/// openssl vectors: a throwaway 2048-bit and 4096-bit key, its public modulus
/// (hex), and RSASSA-PKCS1-v1_5 SHA-256 signatures (hex). e = 65537.
const kat_n_2048 = "d7d4233b73a74a951273ba9bb71a318173291e8f3e4f6e36c243185121a76318bd9094b2f7303ba9c39fbf34e80489691dbb78d566ba76d0addf746b0700b84098d5fe3224c871201c18b3b43bbb6e8e7dc35afe127ce42c462c1d88e837a6640e232812f20fb35430297a8cc61275978be55abb79b606196e1e02059165e3622b42d002000eee72ca6e850e2668c8591045fa483bb8dc0d6a97b2cf7c670f8c08784a449a5c17029231b11a3e1d7e8cf1ead8f2d57a9dccc8178cec9ebb92c2822f12dfb9e5af859c83f1b5f8a75cd57a9ea3deab65ecfd80108d42015209c9338deff9b0175557c8651645dcf93b6df21fd0a6c722736e0e42907f18f142d1";
const kat_sig_empty_2048 = "987d201b8fd2eb2c5b982b0648c0cf79c420b3c076bee7c51f30ff21113b5489ff5e3ddb32be11bf42d372f12eb2d303c37d9b4f15c41c12005edfc3b4c908b9bfdb574873dfb91f2c4f138150826ffbb344a3064956296e9f16efce01a12eacdbac08b3734f18e52146b00b592748457e36f124999ce3d0553cc2d7d9a25b7877186e76d7371304a0094eb993960290807f6c011d9c774321ee2cdf1efb146ef362c4b300192fab7214615fdcd444cb53d21a798bcbf81d8a003ba63c8ba53fffc6f603a5a72a03ac736c804f5ef4cf74f1b7d48c41a27708146d59243b6d8d772b5ef19295ea537a857b3c9347ce762eacdfbe89dcba5d4aebd5f5679588b3";
const kat_sig_abc_2048 = "2c5d9208c4d217defd97120d6d9ff5f3414b4e737c72d1c6376fa03de72856c7a06a9c335ba34cae862ada95c718229052615afb118171480dc049a2d05855dfc848a4569859a5d7920f2c2b2655e5aa1304c7870956934d6769706b471633fb0b15e016cea0dbf4ee2c04982c9e2460536044a6b7469afa05af95b3ba46a21865c5824c8ab9c05ab321dcdccbd3fc7df51d10c88951b864308046d8943c93511a0734aaa0e37cfd62907964c5232dbd9a4a52dc314ffd1cec450cc05c6cbb979c3daf451fed6836f9a2587177b1134258870cb6270a99b91fece6253fca0472b1a3cb18511cd8d5456d8120d6114f08e05644c420c623e6fbe0b42638726971";
const kat_sig_jwt_2048 = "cec9779b4e5b5c61a0a9872dbfb3992fb29ea361072226004221eed9675f3c81d4a2e34411076872e821a04d27003da96b6fa2cb1578ac9920c5f4bf33858117c99ce95bff507375a16c3eeba68aa5301e284a58e37775fab4155437f7845b382a7c7b43cc717683b296ff6fc5f96508fc0aaf6e06c44d9ace5a1a1ee506b8038f099abc03d8b2614ad5c48d10edf490eade5e2bf398090a4952c81cbee0f0ccbe625e0aa600602c517af9623b26dcda824cc9c23b31f5a00088129acef59dbd02f58768155dace04b1410decd351a79d31c5673adc39f956ff436ded4563f2316abc501d2cdd78b3bdb043bd3024954aab0f29fd5b92144b4a66ca0d3a4ff6b";
const kat_n_4096 = "e23c048387741241268ac7797765c5f17e0530ff46deaba0f8326552f80c4f79ad7f0818b544e06eb7e6dd7e1db20caa091ebc3326128dd5bc2640ebd78d5575068e555751e1ecc3a1ea1286f04620a8393715f77fa9e933a31bf99cf0cefdc6e13d62fe066214d351ac76ae5621423f55448ce9ab392b414361040c9a4a4c7045f39fd15a85490e816dddd7185325e1858424188658227e9499bc6f7c9cf7c310da145ed2775505f2c74c5fbb5768138b50ddc88d238316696e5d4c3ddacda4797f092b70f2dbbb727d88922cecc18bfc31659b035d727c4d60f1f76381011548be01a4fc662900789f9058af27dcc33a0166d409ea657da266466538e13e5c8651e9998db2beaf4e3b0b4ee675bf34a84f0c5a617b7947335a114484caa183506f2729a6d2804d389f736afbe49e113108e1b13532adf30cbd8b9aed5e4fa3db656508c909c58c6535f90b7e7fa55b68b15048ca0f11599ae75c531721c963724440e49409f80ed05235e021a8a4e411450ff322ecf2cb312471f1f7bc9992f70b14b31d3be59985959313dcf343231b5b7dd8428907f407fe49692bf6963400755cc061409480dbbff888ea506d56c45b124ed7eea9679b218a34473e671fbcb6d7b32915c4279d65f5d32acc401ffca1ad5d2f680e89468128feb77045b86ba672c69ba744f7090b0d0a567f69a37042b1ad15d5f94a47e4926848c08569";
const kat_sig_abc_4096 = "a251650b09ec14d94220504620e97f0160e9903cd9741b4ecb4cf58ffb394518e6d5ac447ef7afbdaa17e878d85a3be31da6210621a420a82e63fd28b742338f921415623c76dd57e97cf88ce3855d5e20c3ddbff70882cc14ea88f52d9af96d4a9dd33b82fe32f715cf986e935e8f9a1b7013802501c74b959af3c890410708c91302928eec422f4888c4845ad61f9d5844e074574140c2ee5ddc6d180172fe33ea31a15c44aeb5780e14c1a392bbe8d2132b8bb47e1eb48369eea4bedff0dbdf982357a5a1fd826682539bf7d37822966ca8fa9ca1ea70d512cae379f64fc355cee7e0b09df466127bc29dcef455e31c150d9059aab701b8cf4e42aad12072d628242eb50117359815d3bd253a297642a19543ee61d6595460f3225cfc204b85ed5b4561ddff7fbae4784121670c3c3b28ddbe440381022c09b0deab360708fe22d188cae03e024891421a68418235fdae10bd125f7b56b4ad7fa4bdb154e7fe65199de7c0e329ddcc7a946c22c85501f6da2660e7199657abab5eafa13b580baac290f875773725d8bc3c4796e547f47a0048a4ff735462994c96dc55d893c59d4852bf1c457c69fe3837111830a23ce8b123dfeed979fdb67bbbba77c55ca5a614df938a4e1efb697a013c37ef9e9a80a61bb79703657a636f1370f7310885ea522e6024abda46ef827f0064513a2a3c98e7bb3f95f17d61494b7efe38f9";
const kat_e = rsa_testkey.public_exponent_bytes;

/// The signing input (header.claims, base64url) that mint produces for the
/// claims of the mint tests.
const mint_signing_input = "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2lkLTEiLCJ0eXAiOiJKV1QifQ.eyJhdWQiOiJodHRwczovL2V4YW1wbGUuaW52YWxpZC90b2tlbiIsImV4cCI6MTcwMDAwMDA2MCwiaWF0IjoxNzAwMDAwMDAwLCJpc3MiOiJleGFtcGxlLWNsaWVudCIsImp0aSI6Imp0aS0xIiwic3ViIjoiZXhhbXBsZS1jbGllbnQifQ";

fn pkcs1Pem2048(gpa: std.mem.Allocator) ![]u8 {
    return rsa_testkey.pkcs1Pem(gpa, try rsa_testkey.pkcs1Der2048());
}

fn pkcs8Pem2048(gpa: std.mem.Allocator) ![]u8 {
    return rsa_testkey.pkcs8Pem(gpa, try rsa_testkey.pkcs1Der2048());
}

fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

fn readTlv(bytes: []const u8) DerError![]const u8 {
    var r: DerReader = .{ .bytes = bytes };
    return r.tlv(tag_sequence);
}

fn readInteger(bytes: []const u8) DerError![]const u8 {
    var r: DerReader = .{ .bytes = bytes };
    return r.integer();
}

test "EMSA-PKCS1-v1_5 SHA-256 prefix is the RFC 8017 DigestInfo" {
    const want = hexBytes("3031300d060960864801650304020105000420");
    try testing.expectEqualSlices(u8, &want, &sha256_digest_info);
}

test "DER: lengths must be definite and minimal" {
    try testing.expectError(error.IndefiniteLength, readTlv(&.{ 0x30, 0x80 }));
    try testing.expectError(error.NonMinimalLength, readTlv(&.{ 0x30, 0x81, 0x05, 0, 0, 0, 0, 0 }));
    try testing.expectError(error.LengthTooLong, readTlv(&.{ 0x30, 0x85, 0, 0, 0, 0, 1 }));
    try testing.expectError(error.Truncated, readTlv(&.{ 0x30, 0x05, 0x01 }));
    try testing.expectError(error.Truncated, readTlv(&.{ 0x30, 0x82, 0x01 }));
    try testing.expectError(error.Truncated, readTlv(&.{0x30}));
    try testing.expectError(error.UnexpectedTag, readTlv(&.{ 0x31, 0x00 }));
    try testing.expectEqual(@as(usize, 0), (try readTlv(&.{ 0x30, 0x00 })).len);
    // 0x80 is the smallest length that needs the long form: 0x81 0x80.
    var long: [3 + 0x80]u8 = @splat(0);
    long[0] = 0x30;
    long[1] = 0x81;
    long[2] = 0x80;
    try testing.expectEqual(@as(usize, 0x80), (try readTlv(&long)).len);
}

test "DER: integers must be positive and minimally encoded" {
    try testing.expectError(error.NegativeInteger, readInteger(&.{ 0x02, 0x01, 0x80 }));
    try testing.expectError(error.NonMinimalInteger, readInteger(&.{ 0x02, 0x02, 0x00, 0x7f }));
    try testing.expectError(error.EmptyInteger, readInteger(&.{ 0x02, 0x00 }));
    try testing.expectError(error.UnexpectedTag, readInteger(&.{ 0x04, 0x01, 0x01 }));
    try testing.expectEqualSlices(u8, &.{0x80}, try readInteger(&.{ 0x02, 0x02, 0x00, 0x80 }));
    try testing.expectEqualSlices(u8, &.{0x00}, try readInteger(&.{ 0x02, 0x01, 0x00 }));
    var r: DerReader = .{ .bytes = &.{ 0x02, 0x01, 0x00 } };
    try testing.expectError(error.ZeroInteger, r.positive());
}

test "PKCS#1 2048-bit key parses; PKCS#8 wraps the same key; CRLF is accepted" {
    const gpa = testing.allocator;
    const pem1 = try pkcs1Pem2048(gpa);
    defer gpa.free(pem1);
    const pem8 = try pkcs8Pem2048(gpa);
    defer gpa.free(pem8);
    var k1 = try loadPrivateKey(gpa, pem1);
    defer k1.deinit(gpa);
    var k8 = try loadPrivateKey(gpa, pem8);
    defer k8.deinit(gpa);
    try testing.expectEqual(@as(usize, 2048), k1.rsa.bits);
    try testing.expectEqualSlices(u8, &kat_e, k1.rsa.e);
    try testing.expectEqualSlices(u8, k1.rsa.n, k8.rsa.n);
    try testing.expectEqualSlices(u8, k1.rsa.d, k8.rsa.d);

    const crlf = try std.mem.replaceOwned(u8, gpa, pem1, "\n", "\r\n");
    defer gpa.free(crlf);
    var kc = try loadPrivateKey(gpa, crlf);
    defer kc.deinit(gpa);
    try testing.expectEqualSlices(u8, k1.rsa.n, kc.rsa.n);
}

test "PEM: wrong labels, encryption and extra text are refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotPem, loadPrivateKey(gpa, "hello"));

    const pem1 = try pkcs1Pem2048(gpa);
    defer gpa.free(pem1);
    const pem8 = try pkcs8Pem2048(gpa);
    defer gpa.free(pem8);

    const pub_label = try std.mem.replaceOwned(u8, gpa, pem1, label_rsa, "PUBLIC KEY");
    defer gpa.free(pub_label);
    try testing.expectError(error.UnsupportedKey, loadPrivateKey(gpa, pub_label));

    const enc_label = try std.mem.replaceOwned(u8, gpa, pem8, "PRIVATE KEY", "ENCRYPTED PRIVATE KEY");
    defer gpa.free(enc_label);
    try testing.expectError(error.EncryptedKey, loadPrivateKey(gpa, enc_label));

    const proc = try std.mem.replaceOwned(
        u8,
        gpa,
        pem1,
        begin_rsa,
        begin_rsa ++ "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,00112233445566778899AABBCCDDEEFF\n\n",
    );
    defer gpa.free(proc);
    try testing.expectError(error.EncryptedKey, loadPrivateKey(gpa, proc));

    // The PEM ends with a newline, so the extra text starts on its own line.
    const junk = try std.fmt.allocPrint(gpa, "{s}junk\n", .{pem1});
    defer gpa.free(junk);
    try testing.expectError(error.TrailingData, loadPrivateKey(gpa, junk));

    const two = try std.fmt.allocPrint(gpa, "{s}{s}", .{ pem1, pem1 });
    defer gpa.free(two);
    try testing.expectError(error.TrailingData, loadPrivateKey(gpa, two));
}

test "PKCS#1 DER: every truncation, trailing bytes, multi-prime and 1024-bit are refused" {
    const gpa = testing.allocator;
    const der = try rsa_testkey.pkcs1Der2048();
    for (0..der.len) |i| {
        if (parsePkcs1(der[0..i])) |_| return error.TestUnexpectedResult else |_| {}
    }

    const extra = try std.mem.concat(gpa, u8, &.{ der, &.{0x00} });
    defer wipe(gpa, extra);
    try testing.expectError(error.TrailingData, parsePkcs1(extra));

    const mp = try gpa.dupe(u8, der);
    defer wipe(gpa, mp);
    const at = std.mem.indexOf(u8, mp, &.{ 0x02, 0x01, 0x00 }) orelse return error.TestUnexpectedResult;
    mp[at + 2] = 0x01;
    try testing.expectError(error.UnsupportedVersion, parsePkcs1(mp));

    const small = try rsa_testkey.structuralPkcs1Der(gpa, 1024);
    defer wipe(gpa, small);
    try testing.expectError(error.BadModulusSize, parsePkcs1(small));
    const small_pem = try rsa_testkey.pkcs1Pem(gpa, small);
    defer gpa.free(small_pem);
    try testing.expectError(error.BadModulusSize, loadPrivateKey(gpa, small_pem));
}

test "modulus bounds: 2048 to 4096 bits are accepted, 2047 and 4097 are refused" {
    const gpa = testing.allocator;
    const floor = try rsa_testkey.structuralPkcs1Der(gpa, 2048);
    defer gpa.free(floor);
    try testing.expectEqual(@as(usize, 2048), (try parsePkcs1(floor)).bits);
    const top = try rsa_testkey.structuralPkcs1Der(gpa, 4096);
    defer gpa.free(top);
    try testing.expectEqual(@as(usize, 4096), (try parsePkcs1(top)).bits);
    const over = try rsa_testkey.structuralPkcs1Der(gpa, 4097);
    defer gpa.free(over);
    try testing.expectError(error.BadModulusSize, parsePkcs1(over));
    const under = try rsa_testkey.structuralPkcs1Der(gpa, 2047);
    defer gpa.free(under);
    try testing.expectError(error.BadModulusSize, parsePkcs1(under));
}

test "PKCS#8: the wrapped key is the PKCS#1 DER; trailing bytes are refused" {
    const gpa = testing.allocator;
    const pem8 = try pkcs8Pem2048(gpa);
    defer gpa.free(pem8);
    const block = try decodePem(gpa, pem8);
    defer wipe(gpa, block.der);
    try testing.expectEqualSlices(u8, try rsa_testkey.pkcs1Der2048(), try unwrapPkcs8(block.der));

    const extra = try std.mem.concat(gpa, u8, &.{ block.der, &.{0x00} });
    defer wipe(gpa, extra);
    try testing.expectError(error.TrailingData, unwrapPkcs8(extra));
}

test "non-RSA keys are refused: EC (SEC1 and PKCS#8) and Ed25519" {
    const gpa = testing.allocator;
    const ec1 = try rsa_testkey.ecSec1Pem(gpa);
    defer gpa.free(ec1);
    const ec8 = try rsa_testkey.ecPkcs8Pem(gpa);
    defer gpa.free(ec8);
    const ed = try rsa_testkey.ed25519Pkcs8Pem(gpa);
    defer gpa.free(ed);
    try testing.expectError(error.UnsupportedKey, loadPrivateKey(gpa, ec1));
    try testing.expectError(error.UnsupportedKey, loadPrivateKey(gpa, ec8));
    try testing.expectError(error.UnsupportedKey, loadPrivateKey(gpa, ed));
}

test "RS256 verifies openssl's signatures under their public keys (2048 and 4096 bits)" {
    const n2 = hexBytes(kat_n_2048);
    const sig_empty = hexBytes(kat_sig_empty_2048);
    const sig_abc = hexBytes(kat_sig_abc_2048);
    const sig_jwt = hexBytes(kat_sig_jwt_2048);
    try testing.expect(verifyRs256(&n2, &kat_e, "", &sig_empty));
    try testing.expect(verifyRs256(&n2, &kat_e, "abc", &sig_abc));
    try testing.expect(verifyRs256(&n2, &kat_e, mint_signing_input, &sig_jwt));

    // A different message, a flipped bit, a short signature and s >= n all fail.
    try testing.expect(!verifyRs256(&n2, &kat_e, "abd", &sig_abc));
    try testing.expect(!verifyRs256(&n2, &kat_e, "", &sig_abc));
    var flipped = sig_abc;
    flipped[17] ^= 0x01;
    try testing.expect(!verifyRs256(&n2, &kat_e, "abc", &flipped));
    try testing.expect(!verifyRs256(&n2, &kat_e, "abc", sig_abc[0..255]));
    const all_ff: [256]u8 = @splat(0xff);
    try testing.expect(!verifyRs256(&n2, &kat_e, "abc", &all_ff));

    const n4 = hexBytes(kat_n_4096);
    const sig4 = hexBytes(kat_sig_abc_4096);
    try testing.expect(verifyRs256(&n4, &kat_e, "abc", &sig4));
    try testing.expect(!verifyRs256(&n4, &kat_e, "abd", &sig4));
    // The 4096-bit signature is the wrong length for the 2048-bit key.
    try testing.expect(!verifyRs256(&n2, &kat_e, "abc", &sig4));
}

test "RS256 with a runtime 2048-bit key: deterministic, verifies, and binds the message" {
    const gpa = testing.allocator;
    const pem = try pkcs1Pem2048(gpa);
    defer gpa.free(pem);
    var key = try loadPrivateKey(gpa, pem);
    defer key.deinit(gpa);

    const msgs = [_][]const u8{ "", "abc", mint_signing_input };
    for (msgs, 0..) |msg, i| {
        const sig = try signRs256(gpa, key.rsa, msg);
        defer gpa.free(sig);
        const again = try signRs256(gpa, key.rsa, msg);
        defer gpa.free(again);
        try testing.expectEqual(@as(usize, 256), sig.len);
        try testing.expectEqualSlices(u8, sig, again);
        try testing.expect(verifyRs256(key.rsa.n, key.rsa.e, msg, sig));
        try testing.expect(!verifyRs256(key.rsa.n, key.rsa.e, msgs[(i + 1) % msgs.len], sig));
    }
}

test "PKCS#1 and PKCS#8 of one runtime key sign identically" {
    const gpa = testing.allocator;
    const pem8 = try pkcs8Pem2048(gpa);
    defer gpa.free(pem8);
    const pem1 = try pkcs1Pem2048(gpa);
    defer gpa.free(pem1);
    var k8 = try loadPrivateKey(gpa, pem8);
    defer k8.deinit(gpa);
    var k1 = try loadPrivateKey(gpa, pem1);
    defer k1.deinit(gpa);
    const got8 = try signRs256(gpa, k8.rsa, "abc");
    defer gpa.free(got8);
    const got1 = try signRs256(gpa, k1.rsa, "abc");
    defer gpa.free(got1);
    try testing.expectEqualSlices(u8, got1, got8);
}

test "a corrupted private exponent is caught by the verify step" {
    const gpa = testing.allocator;
    const pem = try pkcs1Pem2048(gpa);
    defer gpa.free(pem);
    var key = try loadPrivateKey(gpa, pem);
    defer key.deinit(gpa);
    const bad_d = try gpa.dupe(u8, key.rsa.d);
    defer wipe(gpa, bad_d);
    bad_d[bad_d.len - 1] ^= 1;
    var bad = key.rsa;
    bad.d = bad_d;
    try testing.expectError(error.SignatureCheckFailed, signRs256(gpa, bad, "abc"));
}

const TestCreds = struct {
    type: []const u8,
    client_id: []const u8,
    private_key_id: []const u8,
    private_key: []const u8,
    token_uri: ?[]const u8,
};

test "mint: header and claims are byte-exact, and the signature verifies under the key" {
    const gpa = testing.allocator;
    const pem = try pkcs1Pem2048(gpa);
    defer gpa.free(pem);
    const creds_json = try std.json.Stringify.valueAlloc(gpa, TestCreds{
        .type = datum_credentials_type,
        .client_id = "example-client",
        .private_key_id = "test-kid-1",
        .private_key = pem,
        .token_uri = null,
    }, .{});
    defer gpa.free(creds_json);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const creds = try parseCredentials(a, creds_json);

    const jwt = try mint(gpa, creds, "https://example.invalid/token", 1700000000, "jti-1");
    defer gpa.free(jwt);
    const dot = std.mem.lastIndexOfScalar(u8, jwt, '.') orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(mint_signing_input, jwt[0..dot]);

    var key = try loadPrivateKey(gpa, pem);
    defer key.deinit(gpa);
    const sig = try b64Decode(a, jwt[dot + 1 ..]);
    try testing.expectEqual(@as(usize, 256), sig.len);
    try testing.expect(verifyRs256(key.rsa.n, key.rsa.e, jwt[0..dot], sig));
}

test "mint: string values are JSON-escaped and the claims round-trip" {
    const gpa = testing.allocator;
    const pem = try pkcs1Pem2048(gpa);
    defer gpa.free(pem);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const creds = try parseCredentials(a, "{\"type\":\"datum_service_account\",\"client_id\":\"c\\\"1\",\"private_key_id\":\"k\",\"private_key\":\"x\"}");
    try testing.expectEqualStrings("c\"1", creds.client_id);

    const jti = "a\"b\\c\n";
    const jwt = try mint(gpa, .{
        .client_id = "c\"1",
        .private_key_id = "k",
        .private_key = pem,
    }, "https://example.invalid/token", 1700000000, jti);
    defer gpa.free(jwt);

    var parts = std.mem.splitScalar(u8, jwt, '.');
    const header_b64 = parts.next() orelse return error.TestUnexpectedResult;
    const claims_b64 = parts.next() orelse return error.TestUnexpectedResult;
    const header = try b64Decode(a, header_b64);
    try testing.expectEqualStrings("{\"alg\":\"RS256\",\"kid\":\"k\",\"typ\":\"JWT\"}", header);
    const claims = try b64Decode(a, claims_b64);
    try testing.expect(std.mem.indexOf(u8, claims, "\"jti\":\"a\\\"b\\\\c\\n\"") != null);
    try testing.expect(std.mem.indexOf(u8, claims, "\"iss\":\"c\\\"1\",") != null);
    const parsed = json.parse(a, claims) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(jti, json.str(&.{"jti"}, parsed));
    try testing.expectEqual(@as(i64, 1700000060), json.at(&.{"exp"}, parsed).integer);
}

fn b64Decode(allocator: Allocator, s: []const u8) ![]u8 {
    const n = try b64.Decoder.calcSizeForSlice(s);
    const out = try allocator.alloc(u8, n);
    try b64.Decoder.decode(out, s);
    return out;
}

test "mint: exp is iat + 60; an overflowing iat and a bad key are refused" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const creds = try parseCredentials(arena.allocator(), "{\"type\":\"datum_service_account\",\"client_id\":\"c\",\"private_key_id\":\"k\",\"private_key\":\"not a key\"}");
    try testing.expectError(error.BadTime, mint(gpa, creds, "a", std.math.maxInt(i64), "j"));
    try testing.expectError(error.NotPem, mint(gpa, creds, "a", 1, "j"));
}

test "credentials: required and optional fields, and their types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A placeholder key: the header is built from its label, not written out.
    const label = "PRIVATE KEY";
    const full_json = try std.fmt.allocPrint(a,
        \\{{"type":"datum_service_account","client_id":"example-client","private_key_id":"kid-1",
        \\ "private_key":"-----BEGIN {s}-----\nxx\n-----END {s}-----\n",
        \\ "client_email":"svc@example.invalid","scope":"s","token_uri":null,
        \\ "api_endpoint":"https://example.invalid","project_id":"p"}}
    , .{ label, label });
    const full = try parseCredentials(a, full_json);
    try testing.expectEqualStrings("example-client", full.client_id);
    try testing.expectEqualStrings("kid-1", full.private_key_id);
    try testing.expect(std.mem.startsWith(u8, full.private_key, "-----BEGIN " ++ label ++ "-----"));
    try testing.expectEqualStrings("svc@example.invalid", full.client_email.?);
    try testing.expectEqualStrings("s", full.scope.?);
    try testing.expectEqual(@as(?[]const u8, null), full.token_uri);
    try testing.expectEqualStrings("https://example.invalid", full.api_endpoint.?);
    try testing.expectEqualStrings("p", full.project_id.?);

    const bare = try parseCredentials(a, "{\"type\":\"datum_service_account\",\"client_id\":\"c\",\"private_key_id\":\"k\",\"private_key\":\"p\"}");
    try testing.expectEqual(@as(?[]const u8, null), bare.scope);

    try testing.expectError(error.WrongCredentialsType, parseCredentials(a, "{\"type\":\"user\",\"client_id\":\"c\",\"private_key_id\":\"k\",\"private_key\":\"p\"}"));
    try testing.expectError(error.MissingField, parseCredentials(a, "{\"client_id\":\"c\",\"private_key_id\":\"k\",\"private_key\":\"p\"}"));
    try testing.expectError(error.MissingField, parseCredentials(a, "{\"type\":\"datum_service_account\",\"private_key_id\":\"k\",\"private_key\":\"p\"}"));
    try testing.expectError(error.MissingField, parseCredentials(a, "{\"type\":\"datum_service_account\",\"client_id\":\"c\",\"private_key\":\"p\"}"));
    try testing.expectError(error.MissingField, parseCredentials(a, "{\"type\":\"datum_service_account\",\"client_id\":\"c\",\"private_key_id\":\"k\"}"));
    try testing.expectError(error.MissingField, parseCredentials(a, "{\"type\":\"datum_service_account\",\"client_id\":\"\",\"private_key_id\":\"k\",\"private_key\":\"p\"}"));
    try testing.expectError(error.WrongType, parseCredentials(a, "{\"type\":\"datum_service_account\",\"client_id\":\"c\",\"private_key_id\":\"k\",\"private_key\":\"p\",\"scope\":5}"));
    try testing.expectError(error.BadJson, parseCredentials(a, "{"));
    try testing.expectError(error.NotAnObject, parseCredentials(a, "[]"));
}
