//! Test-only key material, built at runtime so that no private key is written
//! into the source. Only the test code in jwt.zig imports this file.
//!
//! The RSA key comes from a fixed seed, so every run gets the same key. Primes
//! come from trial division and Miller-Rabin with fixed bases. That is
//! variable-time, which is fine for test keys. Nothing here is for real use.
//! The DER and PEM writers are only what the tests need.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;
const Random = std.Random;

/// The public exponent of every generated key: F4, 65537.
pub const public_exponent: u32 = 65537;
/// The same exponent as big-endian bytes, as parsePkcs1 returns it.
pub const public_exponent_bytes = [_]u8{ 0x01, 0x00, 0x01 };

const seed_label = "yolo jwt test rsa key v1";
const mr_bases = [_]u32{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71 };
const sieve_limit = 1000;

/// Primes below `sieve_limit`, computed at compile time.
const small_primes = blk: {
    @setEvalBranchQuota(100_000);
    var composite: [sieve_limit]bool = @splat(false);
    var list: [sieve_limit]u32 = undefined;
    var count: usize = 0;
    for (2..sieve_limit) |i| {
        if (composite[i]) continue;
        list[count] = @intCast(i);
        count += 1;
        var j = i * i;
        while (j < sieve_limit) : (j += i) composite[j] = true;
    }
    break :blk list[0..count].*;
};

const tag_integer: u8 = 0x02;
const tag_octet_string: u8 = 0x04;
const tag_null: u8 = 0x05;
const tag_oid: u8 = 0x06;
const tag_sequence: u8 = 0x30;
const tag_explicit_0: u8 = 0xa0;

const oid_rsa_encryption = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
const oid_ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const oid_prime256v1 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const oid_ed25519 = [_]u8{ 0x2b, 0x65, 0x70 };

/// The RSAPrivateKey fields, as big-endian magnitudes (e is the fixed exponent).
const RsaParts = struct {
    n: []const u8,
    d: []const u8,
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
};

// ---------------------------------------------------------------------------
// Pure: DER and PEM writers. Each takes an allocator that the caller resets or
// frees, since the intermediate slices are not freed one by one.
// ---------------------------------------------------------------------------

fn encodeLength(buf: *[5]u8, len: usize) []const u8 {
    if (len < 0x80) {
        buf[0] = @intCast(len);
        return buf[0..1];
    }
    var octets: usize = 0;
    var rest = len;
    while (rest != 0) : (rest >>= 8) octets += 1;
    buf[0] = @intCast(0x80 | octets);
    for (0..octets) |i| {
        const shift: u6 = @intCast(8 * (octets - 1 - i));
        buf[1 + i] = @truncate(len >> shift);
    }
    return buf[0 .. 1 + octets];
}

fn tlv(a: Allocator, tag: u8, content: []const u8) Allocator.Error![]u8 {
    var len_buf: [5]u8 = undefined;
    const len = encodeLength(&len_buf, content.len);
    const out = try a.alloc(u8, 1 + len.len + content.len);
    out[0] = tag;
    @memcpy(out[1 .. 1 + len.len], len);
    @memcpy(out[1 + len.len ..], content);
    return out;
}

fn sequence(a: Allocator, parts: []const []const u8) ![]u8 {
    return tlv(a, tag_sequence, try std.mem.concat(a, u8, parts));
}

/// A minimal INTEGER for a big-endian magnitude: leading zeros dropped, and a
/// zero byte added when the top bit is set, so the value stays positive.
fn integer(a: Allocator, magnitude: []const u8) ![]u8 {
    var m = magnitude;
    while (m.len > 1 and m[0] == 0) m = m[1..];
    if (m.len == 0 or (m[0] & 0x80) != 0) {
        const zero = [_]u8{0};
        return tlv(a, tag_integer, try std.mem.concat(a, u8, &.{ zero[0..], m }));
    }
    return tlv(a, tag_integer, m);
}

/// RSAPrivateKey (RFC 8017 A.1.2), version 0.
fn pkcs1Encode(a: Allocator, parts: RsaParts) ![]u8 {
    return sequence(a, &.{
        try integer(a, &.{0}),
        try integer(a, parts.n),
        try integer(a, &public_exponent_bytes),
        try integer(a, parts.d),
        try integer(a, parts.p),
        try integer(a, parts.q),
        try integer(a, parts.dp),
        try integer(a, parts.dq),
        try integer(a, parts.qinv),
    });
}

/// PKCS#8 PrivateKeyInfo for rsaEncryption, with NULL parameters.
fn pkcs8Wrap(a: Allocator, pkcs1_der: []const u8) ![]u8 {
    const alg = try sequence(a, &.{
        try tlv(a, tag_oid, &oid_rsa_encryption),
        try tlv(a, tag_null, ""),
    });
    return sequence(a, &.{
        try integer(a, &.{0}),
        alg,
        try tlv(a, tag_octet_string, pkcs1_der),
    });
}

/// PEM armour: the label, base64 in 64-character lines, and the END line.
pub fn pemEncode(gpa: Allocator, label: []const u8, der: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const b64 = try arena.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(der.len));
    _ = std.base64.standard.Encoder.encode(b64, der);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "-----BEGIN ");
    try out.appendSlice(gpa, label);
    try out.appendSlice(gpa, "-----\n");
    var i: usize = 0;
    while (i < b64.len) : (i += 64) {
        try out.appendSlice(gpa, b64[i..@min(i + 64, b64.len)]);
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "-----END ");
    try out.appendSlice(gpa, label);
    try out.appendSlice(gpa, "-----\n");
    return out.toOwnedSlice(gpa);
}

/// A PKCS#1 RSA PRIVATE KEY PEM for `der`.
pub fn pkcs1Pem(gpa: Allocator, der: []const u8) ![]u8 {
    return pemEncode(gpa, "RSA PRIVATE KEY", der);
}

/// A PKCS#8 PRIVATE KEY PEM wrapping the PKCS#1 `pkcs1_der`.
pub fn pkcs8Pem(gpa: Allocator, pkcs1_der: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const wrapped = try pkcs8Wrap(arena.allocator(), pkcs1_der);
    return pemEncode(gpa, "PRIVATE KEY", wrapped);
}

/// A PKCS#1 RSAPrivateKey of `bits` bits in the modulus, with a structurally
/// valid body and no real primes. parsePkcs1 checks the modulus length and the
/// exponent and nothing else, so this exercises the size bounds without the
/// cost of generating a key. The caller frees the result.
pub fn structuralPkcs1Der(gpa: Allocator, bits: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nbytes = (bits + 7) / 8;
    const n = try a.alloc(u8, nbytes);
    @memset(n, 0xa5);
    n[0] = @as(u8, 1) << @intCast((bits - 1) % 8);
    const one = [_]u8{1};
    const der = try pkcs1Encode(a, .{ .n = n, .d = &one, .p = &one, .q = &one, .dp = &one, .dq = &one, .qinv = &one });
    return gpa.dupe(u8, der);
}

/// SEC1 `EC PRIVATE KEY` for P-256, with random scalar bytes. The parser refuses
/// it by its label, so the scalar is never checked.
pub fn ecSec1Pem(gpa: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const scalar = randomBytes32("ec p-256 test scalar");
    const der = try sequence(a, &.{
        try integer(a, &.{1}),
        try tlv(a, tag_octet_string, &scalar),
        try tlv(a, tag_explicit_0, try tlv(a, tag_oid, &oid_prime256v1)),
    });
    return pemEncode(gpa, "EC PRIVATE KEY", der);
}

/// PKCS#8 PRIVATE KEY for P-256 (id-ecPublicKey), with random scalar bytes.
pub fn ecPkcs8Pem(gpa: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const scalar = randomBytes32("ec p-256 test scalar");
    const alg = try sequence(a, &.{
        try tlv(a, tag_oid, &oid_ec_public_key),
        try tlv(a, tag_oid, &oid_prime256v1),
    });
    const inner = try sequence(a, &.{
        try integer(a, &.{1}),
        try tlv(a, tag_octet_string, &scalar),
    });
    const der = try sequence(a, &.{
        try integer(a, &.{0}),
        alg,
        try tlv(a, tag_octet_string, inner),
    });
    return pemEncode(gpa, "PRIVATE KEY", der);
}

/// PKCS#8 PRIVATE KEY for Ed25519 (RFC 8410), with a random seed.
pub fn ed25519Pkcs8Pem(gpa: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const seed = randomBytes32("ed25519 test seed");
    const alg = try sequence(a, &.{try tlv(a, tag_oid, &oid_ed25519)});
    const der = try sequence(a, &.{
        try integer(a, &.{0}),
        alg,
        try tlv(a, tag_octet_string, try tlv(a, tag_octet_string, &seed)),
    });
    return pemEncode(gpa, "PRIVATE KEY", der);
}

fn seedFor(label: []const u8) [32]u8 {
    var seed: [32]u8 = @splat(0);
    const n = @min(label.len, seed.len);
    @memcpy(seed[0..n], label[0..n]);
    return seed;
}

fn randomBytes32(label: []const u8) [32]u8 {
    var prng = Random.DefaultCsprng.init(seedFor(label));
    var out: [32]u8 = undefined;
    prng.random().bytes(&out);
    return out;
}

// ---------------------------------------------------------------------------
// Big-integer helpers over std.math.big.int.Managed. Values are arena-owned.
// ---------------------------------------------------------------------------

/// A big-endian byte string as a non-negative Managed.
fn fromBe(a: Allocator, be: []const u8) !Managed {
    const hex = try std.fmt.allocPrint(a, "{x}", .{be});
    var m = try Managed.init(a);
    try m.setString(16, hex);
    return m;
}

/// A non-negative Managed as minimal big-endian bytes.
fn toBe(a: Allocator, m: *const Managed) ![]u8 {
    const hex = try m.toConst().toStringAlloc(a, 16, .lower);
    const padded = if (hex.len % 2 == 0) hex else try std.fmt.allocPrint(a, "0{s}", .{hex});
    const out = try a.alloc(u8, padded.len / 2);
    _ = std.fmt.hexToBytes(out, padded) catch unreachable;
    return out;
}

fn copyOf(a: Allocator, x: *const Managed) !Managed {
    var c = try Managed.init(a);
    try c.copy(x.toConst());
    return c;
}

fn mulManaged(a: Allocator, x: *const Managed, y: *const Managed) !Managed {
    var r = try Managed.init(a);
    try r.mul(x, y);
    return r;
}

fn subManaged(a: Allocator, x: *const Managed, y: *const Managed) !Managed {
    var r = try Managed.init(a);
    try r.sub(x, y);
    return r;
}

fn subOne(a: Allocator, x: *const Managed) !Managed {
    const one = try Managed.initSet(a, 1);
    return subManaged(a, x, &one);
}

/// x mod m, non-negative for a positive m (floor division).
fn reduceMod(a: Allocator, x: *const Managed, m: *const Managed) !Managed {
    var q = try Managed.init(a);
    var r = try Managed.init(a);
    try q.divFloor(&r, x, m);
    return r;
}

fn mulMod(a: Allocator, x: *const Managed, y: *const Managed, m: *const Managed) !Managed {
    const prod = try mulManaged(a, x, y);
    return reduceMod(a, &prod, m);
}

fn eqlM(x: *const Managed, y: *const Managed) bool {
    return x.toConst().eql(y.toConst());
}

/// x^e mod m with e as big-endian bytes, by left-to-right square and multiply.
fn powMod(a: Allocator, base: *const Managed, exp: []const u8, m: *const Managed) !Managed {
    var acc = try Managed.initSet(a, 1);
    for (exp) |byte| {
        for (0..8) |i| {
            const shift: u3 = @intCast(7 - i);
            acc = try mulMod(a, &acc, &acc, m);
            if ((byte >> shift) & 1 == 1) acc = try mulMod(a, &acc, base, m);
        }
    }
    return acc;
}

/// The inverse of x mod m, by the extended Euclidean algorithm, or null when
/// gcd(x, m) is not 1.
fn modInverse(a: Allocator, x: *const Managed, m: *const Managed) !?Managed {
    var old_r = try copyOf(a, m);
    var r = try reduceMod(a, x, m);
    var old_s = try Managed.initSet(a, 0);
    var s = try Managed.initSet(a, 1);
    while (!r.toConst().eqlZero()) {
        var q = try Managed.init(a);
        var rem = try Managed.init(a);
        try q.divFloor(&rem, &old_r, &r);
        const qs = try mulManaged(a, &q, &s);
        const next_s = try subManaged(a, &old_s, &qs);
        old_r = r;
        r = rem;
        old_s = s;
        s = next_s;
    }
    const one = try Managed.initSet(a, 1);
    if (!old_r.toConst().eql(one.toConst())) return null;
    return try reduceMod(a, &old_s, m);
}

/// Trial division: the value is divisible by p.
fn remainderBe(be: []const u8, p: u32) u32 {
    var r: u64 = 0;
    for (be) |b| r = (r * 256 + b) % p;
    return @intCast(r);
}

fn hasSmallFactor(be: []const u8) bool {
    for (small_primes) |p| {
        if (remainderBe(be, p) == 0) return true;
    }
    return false;
}

/// Miller-Rabin over the fixed bases in `mr_bases`. For a random odd n of this
/// size, 20 fixed bases leave the error far below anything a test could hit.
fn isProbablePrime(a: Allocator, n: *const Managed) !bool {
    const one = try Managed.initSet(a, 1);
    const n1 = try subOne(a, n);
    var d = try copyOf(a, &n1);
    var s: usize = 0;
    while (!d.toConst().isOdd()) {
        var half = try Managed.init(a);
        try half.shiftRight(&d, 1);
        d = half;
        s += 1;
    }
    const d_bytes = try toBe(a, &d);
    for (mr_bases) |b| {
        const base = try Managed.initSet(a, b);
        var x = try powMod(a, &base, d_bytes, n);
        if (eqlM(&x, &one) or eqlM(&x, &n1)) continue;
        var composite = true;
        for (1..s) |_| {
            x = try mulMod(a, &x, &x, n);
            if (eqlM(&x, &n1)) {
                composite = false;
                break;
            }
        }
        if (composite) return false;
    }
    return true;
}

/// A random prime of exactly `bits` bits: the top two bits are set, so the
/// product of two such primes has exactly twice that many bits.
fn randomPrime(a: Allocator, rng: Random, bits: usize) !Managed {
    const nbytes = bits / 8;
    const buf = try a.alloc(u8, nbytes);
    while (true) {
        rng.bytes(buf);
        buf[0] |= 0xc0;
        buf[nbytes - 1] |= 0x01;
        if (hasSmallFactor(buf)) continue;
        const cand = try fromBe(a, buf);
        if (try isProbablePrime(a, &cand)) return cand;
    }
}

/// Two-prime RSA parts for a modulus of `bits` bits, from the fixed seed.
fn generateParts(a: Allocator, bits: usize) !RsaParts {
    var prng = Random.DefaultCsprng.init(seedFor(seed_label));
    const rng = prng.random();
    const e = try Managed.initSet(a, public_exponent);
    while (true) {
        const p = try randomPrime(a, rng, bits / 2);
        const q = try randomPrime(a, rng, bits / 2);
        if (eqlM(&p, &q)) continue;
        const n = try mulManaged(a, &p, &q);
        const p1 = try subOne(a, &p);
        const q1 = try subOne(a, &q);
        const phi = try mulManaged(a, &p1, &q1);
        const d = (try modInverse(a, &e, &phi)) orelse continue;
        const dp = try reduceMod(a, &d, &p1);
        const dq = try reduceMod(a, &d, &q1);
        const qinv = (try modInverse(a, &q, &p)) orelse unreachable;
        return .{
            .n = try toBe(a, &n),
            .d = try toBe(a, &d),
            .p = try toBe(a, &p),
            .q = try toBe(a, &q),
            .dp = try toBe(a, &dp),
            .dq = try toBe(a, &dq),
            .qinv = try toBe(a, &qinv),
        };
    }
}

// ---------------------------------------------------------------------------
// IO boundary: the cached 2048-bit key. Generation takes a few seconds in a
// Debug build, so it happens once per test process, on page_allocator (the
// test allocator would report it as a leak).
// ---------------------------------------------------------------------------

var cached_2048: ?[]const u8 = null;

/// The PKCS#1 DER of the fixed 2048-bit test key. Generated on first use and
/// kept for the rest of the test process: the caller must not free it.
pub fn pkcs1Der2048() ![]const u8 {
    if (cached_2048) |der| return der;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const der = try pkcs1Encode(a, try generateParts(a, 2048));
    const owned = try std.heap.page_allocator.dupe(u8, der);
    cached_2048 = owned;
    return owned;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "integer: magnitudes get a sign byte only when the top bit is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x02, 0x00, 0x80 }, try integer(a, &.{0x80}));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x7f }, try integer(a, &.{ 0x00, 0x00, 0x7f }));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x00 }, try integer(a, &.{0}));
}

test "DER lengths: long form is minimal" {
    const a = std.testing.allocator;
    const short = try tlv(a, 0x04, &@as([0x7f]u8, @splat(1)));
    defer a.free(short);
    try std.testing.expectEqual(@as(u8, 0x7f), short[1]);
    const long = try tlv(a, 0x04, &@as([0x80]u8, @splat(1)));
    defer a.free(long);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x81, 0x80 }, long[0..3]);
    const longer = try tlv(a, 0x04, &@as([0x0100]u8, @splat(1)));
    defer a.free(longer);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x82, 0x01, 0x00 }, longer[0..4]);
}

test "small primes: the sieve has the 168 primes below 1000" {
    try std.testing.expectEqual(@as(usize, 168), small_primes.len);
    try std.testing.expectEqual(@as(u32, 997), small_primes[small_primes.len - 1]);
}

test "modular inverse and Miller-Rabin on small values" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // 17 * 2753 = 46801 = 15 * 3120 + 1, and 3120 = (61 - 1) * (53 - 1) for 3233 = 53 * 61.
    const m = try Managed.initSet(aa, 3120);
    const x = try Managed.initSet(aa, 17);
    const inv = (try modInverse(aa, &x, &m)).?;
    try std.testing.expect(eqlM(&inv, &(try Managed.initSet(aa, 2753))));
    const none = try Managed.initSet(aa, 3);
    try std.testing.expect((try modInverse(aa, &none, &m)) == null);
    try std.testing.expect(try isProbablePrime(aa, &(try Managed.initSet(aa, 1000003))));
    try std.testing.expect(!try isProbablePrime(aa, &(try Managed.initSet(aa, 1000001))));
}
