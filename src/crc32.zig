//! CRC-32 checksumming with SIMD acceleration.
//!
//! This package computes the standard reflected CRC-32 for the IEEE, Castagnoli
//! and Koopman polynomials (and any custom polynomial). For the IEEE polynomial
//! on inputs at or above `update.min_bulk`, the bulk is folded through the
//! host's hardware carryless-multiply unit (`PCLMULQDQ` on x86_64, `PMULL` on
//! aarch64); everything else - other polynomials, small inputs, the sub-16-byte
//! tail, and any CPU without a CLMUL unit - uses a scalar table. The result is
//! the standard CRC-32 in every case, bit for bit.
//!
//! ## Usage
//!
//! ```zig
//! const crc32 = @import("crc32");
//!
//! // Convenience helpers for the IEEE polynomial.
//! const sum: u32 = crc32.checksumIEEE(data);
//!
//! // Or the full table-based API.
//! var tab = crc32.makeTable(crc32.IEEE);
//! const s = crc32.checksum(data, &tab);
//! const c = crc32.update(0, &tab, data);
//!
//! var h = crc32.newIEEE();
//! _ = h.write(data);
//! const finalized = h.sum32();
//! ```
//!
//! The API surface mirrors the conventional CRC-32 hash interface: `checksum`,
//! `checksumIEEE`, `update`, `new`, `newIEEE`, `makeTable`, the `ieee_table`,
//! the `IEEE`/`Castagnoli`/`Koopman` constants, `size`, the `Table` type, and
//! the `Digest` hash object (including binary marshal/unmarshal).

const std = @import("std");

const scalar = @import("scalar.zig");
const update_mod = @import("update.zig");
const kernel = @import("kernel.zig");
const fold = @import("fold.zig");
pub const errors = @import("errors.zig");

/// Size of a CRC-32 checksum in bytes.
pub const size: usize = 4;
const size_bytes: usize = size;

/// Predefined reflected polynomials.
pub const IEEE: u32 = 0xedb88320;
pub const Castagnoli: u32 = 0x82F63B78;
pub const Koopman: u32 = 0xEB31D82E;

/// `Table` is the 256-word reflected table used for efficient processing.
pub const Table = [256]u32;

/// `ieee_table` is the reflected table for the IEEE polynomial, precomputed at
/// comptime.
pub const ieee_table: Table = scalar.makeTable(IEEE);

/// `IEEETable` is a pointer to `ieee_table`.
pub const IEEETable: *const Table = &ieee_table;

/// `makeTable` returns a reflected table constructed from `poly`.
pub fn makeTable(poly: u32) Table {
    return scalar.makeTable(poly);
}

/// `update` returns the result of adding the bytes in `p` to `crc`.
pub fn update(crc: u32, tab: *const Table, p: []const u8) u32 {
    return update_mod.update(crc, tab, p);
}

/// `checksum` returns the CRC-32 checksum of `data` using `tab`.
pub fn checksum(data: []const u8, tab: *const Table) u32 {
    return update_mod.update(0, tab, data);
}

/// `checksumIEEE` returns the CRC-32 checksum of `data` using the IEEE polynomial.
pub fn checksumIEEE(data: []const u8) u32 {
    return update_mod.update(0, IEEETable, data);
}

// ---------------------------------------------------------------------------
// Marshaled-state format.
//
// `magic` prefixes the marshaled digest so an unmarshal can sanity-check it.
// The 4-byte magic + 4-byte table fingerprint + 4-byte crc = 12 bytes total.
// The table fingerprint is the IEEE checksum of the table's 1024 big-endian
// bytes, so a state marshaled under one polynomial refuses to unmarshal under
// another.
// ---------------------------------------------------------------------------

const magic = [_]u8{ 'c', 'r', 'c', 0x01 };
pub const marshaled_size: usize = magic.len + 4 + 4;

fn appendU32(out: []u8, v: u32) void {
    out[0] = @truncate(v >> 24);
    out[1] = @truncate(v >> 16);
    out[2] = @truncate(v >> 8);
    out[3] = @truncate(v);
}

fn beU32(in: []const u8) u32 {
    return (@as(u32, in[0]) << 24) |
        (@as(u32, in[1]) << 16) |
        (@as(u32, in[2]) << 8) |
        @as(u32, in[3]);
}

/// `tableSum` returns the IEEE checksum of `tab`'s 1024 big-endian bytes - the
/// fingerprint stored in a marshaled digest. `null` maps to the checksum of an
/// empty message.
pub fn tableSum(tab: ?*const Table) u32 {
    if (tab == null) return checksumIEEE(&[0]u8{});
    const t = tab.?;
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        appendU32(buf[i * 4 ..][0..4], t[i]);
    }
    return checksumIEEE(&buf);
}

// ---------------------------------------------------------------------------
// Digest: a streaming CRC-32 hash object.
// ---------------------------------------------------------------------------

/// `Digest` is a streaming CRC-32 hasher over a fixed polynomial table. The
/// table is referenced by pointer; the caller must keep it alive for the
/// digest's lifetime (`newIEEE` uses the package-global `ieee_table`, which is
/// always valid).
pub const Digest = struct {
    crc: u32 = 0,
    tab: *const Table,

    /// `write` folds `p` into the running CRC and returns the number of bytes
    /// consumed (always `p.len`).
    pub fn write(self: *Digest, p: []const u8) usize {
        self.crc = update_mod.update(self.crc, self.tab, p);
        return p.len;
    }

    pub fn sum32(self: *const Digest) u32 {
        return self.crc;
    }

    /// `size` returns the checksum size in bytes (4).
    pub fn size(_: *const Digest) usize {
        return size_bytes;
    }

    /// `blockSize` returns the hash's block size in bytes (1 - CRC processes
    /// input one byte at a time at the logical level).
    pub fn blockSize(_: *const Digest) usize {
        return 1;
    }

    pub fn reset(self: *Digest) void {
        self.crc = 0;
    }

    /// `sum` appends the big-endian encoding of the current CRC to `in`, writing
    /// into `out` (which must have room for `in.len + 4` bytes) and returning
    /// the number of bytes written.
    pub fn sum(self: *const Digest, in: []const u8, out: []u8) usize {
        @memcpy(out[0..in.len], in);
        const s = self.sum32();
        out[in.len + 0] = @truncate(s >> 24);
        out[in.len + 1] = @truncate(s >> 16);
        out[in.len + 2] = @truncate(s >> 8);
        out[in.len + 3] = @truncate(s);
        return in.len + 4;
    }

    /// `marshalBinary` writes the digest's state into a fixed 12-byte buffer.
    pub fn marshalBinary(self: *const Digest) [marshaled_size]u8 {
        var b: [marshaled_size]u8 = undefined;
        @memcpy(b[0..magic.len], &magic);
        appendU32(b[magic.len..][0..4], tableSum(self.tab));
        appendU32(b[magic.len + 4 ..][0..4], self.crc);
        return b;
    }

    /// `unmarshalBinary` restores the digest's state from `b`. Returns
    /// `error.InvalidIdentifier`, `error.InvalidSize` or `error.TablesMismatch`
    /// on a malformed or incompatible buffer.
    pub fn unmarshalBinary(self: *Digest, b: []const u8) errors.Error!void {
        if (b.len < magic.len or !std.mem.eql(u8, b[0..magic.len], &magic)) {
            return error.InvalidIdentifier;
        }
        if (b.len != marshaled_size) return error.InvalidSize;
        if (tableSum(self.tab) != beU32(b[magic.len..][0..4])) {
            return error.TablesMismatch;
        }
        self.crc = beU32(b[magic.len + 4 ..][0..4]);
    }
};

/// `new` returns a `Digest` over `tab`.
pub fn new(tab: *const Table) Digest {
    return .{ .crc = 0, .tab = tab };
}

/// `newIEEE` returns a `Digest` over the IEEE polynomial.
pub fn newIEEE() Digest {
    return new(IEEETable);
}

// ---------------------------------------------------------------------------
// Public-API tests.
// ---------------------------------------------------------------------------

const naiveIeee = fold.naiveIeee;
const naiveRef = fold.naiveRef;

test "checksumIEEE known vectors" {
    try std.testing.expectEqual(@as(u32, 0x00000000), checksumIEEE(""));
    try std.testing.expectEqual(@as(u32, 0xcbf43926), checksumIEEE("123456789"));
    try std.testing.expectEqual(@as(u32, 0x414fa339), checksumIEEE("The quick brown fox jumps over the lazy dog"));
}

test "checksum matches naive oracle across lengths" {
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    var n: usize = 0;
    while (n <= 600) : (n += 1) {
        const buf = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(buf);
        rng.bytes(buf);
        try std.testing.expectEqual(naiveIeee(buf), checksum(buf, IEEETable));
    }
}

test "checksum for Castagnoli and Koopman matches naive oracle" {
    var cast = makeTable(Castagnoli);
    var koop = makeTable(Koopman);
    var prng = std.Random.DefaultPrng.init(11);
    const rng = prng.random();
    for ([_]usize{ 0, 1, 9, 100, 1000, 4096 }) |n| {
        const buf = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(buf);
        rng.bytes(buf);
        try std.testing.expectEqual(naiveRef(Castagnoli, 0, buf), checksum(buf, &cast));
        try std.testing.expectEqual(naiveRef(Koopman, 0, buf), checksum(buf, &koop));
    }
    // Catalogue check values for "123456789".
    try std.testing.expectEqual(@as(u32, 0xe3069283), checksum("123456789", &cast));
    try std.testing.expectEqual(@as(u32, 0x2d3dd0ae), checksum("123456789", &koop));
}

test "digest write/sum/reset" {
    var h = newIEEE();
    try std.testing.expectEqual(@as(usize, 4), h.size());
    try std.testing.expectEqual(@as(usize, 1), h.blockSize());
    const data = "the quick brown fox jumps over the lazy dog";
    _ = h.write(data[0..20]);
    _ = h.write(data[20..]);
    try std.testing.expectEqual(naiveIeee(data), h.sum32());

    // Sum appends big-endian.
    var out: [4]u8 = undefined;
    const m = h.sum("", &out);
    try std.testing.expectEqual(@as(usize, 4), m);
    const rebuilt: u32 =
        (@as(u32, out[0]) << 24) |
        (@as(u32, out[1]) << 16) |
        (@as(u32, out[2]) << 8) |
        @as(u32, out[3]);
    try std.testing.expectEqual(h.sum32(), rebuilt);

    // Sum(prefix) preserves the prefix.
    var out2: [7]u8 = undefined;
    const m2 = h.sum("pre", &out2);
    try std.testing.expectEqual(@as(usize, 7), m2);
    try std.testing.expectEqualSlices(u8, "pre", out2[0..3]);

    h.reset();
    try std.testing.expectEqual(@as(u32, 0), h.sum32());
}

test "marshal/unmarshal round trip" {
    var cast = makeTable(Castagnoli);
    var h = new(&cast);
    _ = h.write("the quick brown fox jumps over the lazy dog, repeatedly!!");
    const want = h.sum32();

    const state = h.marshalBinary();
    try std.testing.expectEqual(@as(usize, marshaled_size), state.len);

    var h2 = new(&cast);
    try h2.unmarshalBinary(&state);
    try std.testing.expectEqual(want, h2.sum32());
}

test "unmarshal rejects bad input" {
    var h = newIEEE();
    // short / bad magic
    try std.testing.expectError(error.InvalidIdentifier, h.unmarshalBinary("xx"));
    // good magic, wrong size
    var bad: [6]u8 = undefined;
    @memcpy(bad[0..magic.len], &magic);
    bad[4] = 's';
    bad[5] = 'h';
    try std.testing.expectError(error.InvalidSize, h.unmarshalBinary(&bad));
    // correct size & magic, wrong table fingerprint (Castagnoli state into an
    // IEEE digest).
    var cast = makeTable(Castagnoli);
    var other = new(&cast);
    const wrong = other.marshalBinary();
    try std.testing.expectError(error.TablesMismatch, h.unmarshalBinary(&wrong));
}

test "tableSum of nil is IEEE of empty" {
    try std.testing.expectEqual(checksumIEEE(&[0]u8{}), tableSum(null));
}
