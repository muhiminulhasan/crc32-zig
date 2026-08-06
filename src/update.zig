//! Fold-constant derivation, the reflected 128->32 reduction, and the
//! `update` dispatch. The fold constants depend only on the IEEE polynomial, so
//! they are computed at comptime - no runtime init.

const std = @import("std");

const fold = @import("fold.zig");
const scalar = @import("scalar.zig");
const kernel = @import("kernel.zig");
const crc32 = @import("crc32.zig");

const FoldConstants = fold.FoldConstants;

/// `min_bulk` is the smallest input for which the CLMUL kernel is engaged.
/// Below it the per-call setup (the 128->32 reduction and the scalar tail)
/// outweighs the fold's throughput advantage, so the scalar table path is used.
/// It must be at least 128 (the fold-by-eight kernel seeds eight 128-bit lanes
/// from the first 128 bytes). It is a `var` so tests can lower it to drive the
/// kernel on small deterministic inputs.
pub var min_bulk: usize = 512;

// The IEEE CRC-32 generator: `poly_ref` is the reflected form (as used by the
// reflected bit-serial reduction), `poly_norm` the normal-order form (with the
// implicit x^32 term) used by the polynomial-remainder fold math.
pub const poly_ref: u32 = 0xedb88320;
pub const poly_norm: u32 = 0x04c11db7;

/// `polyOf` recovers the reflected polynomial from a table. In a reflected
/// table, entry 128 shifts its single set bit down to bit 0 over the eight
/// inner iterations and XORs the polynomial exactly once, so `tab[128] == poly`
/// for every polynomial. The kernel is only valid for IEEE, so this is how
/// `update` decides whether to fold or defer to the scalar path.
pub fn polyOf(tab: *const crc32.Table) u32 {
    return tab[128];
}

/// `xnModP` returns x^n mod P in normal bit order (a value of degree < 32),
/// where P is the degree-32 IEEE generator. Used to derive the reflected fold
/// constants.
pub fn xnModP(n: usize) u32 {
    @setEvalBranchQuota(100000);
    var rem: u32 = 1; // x^0
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const msb = rem >> 31;
        rem <<= 1;
        if (msb == 1) rem ^= poly_norm;
    }
    return rem;
}

/// `foldK` returns the (lo, hi) constant pair that folds a 128-bit accumulator
/// forward by `dist` bits. For a reflected fold the low word uses
/// `reflect(x^(dist+63) mod P)` and the high word `reflect(x^(dist-1) mod P)`;
/// because each remainder is a degree-<32 value, the reflected constant is
/// `reverse32(rem)` placed in the high half of the 64-bit lane.
pub fn foldK(dist: usize) struct { lo: u64, hi: u64 } {
    return .{
        .lo = @as(u64, @bitReverse(xnModP(dist + 63))) << 32,
        .hi = @as(u64, @bitReverse(xnModP(dist - 1))) << 32,
    };
}

/// `makeConstants` builds the reflected fold constants for the IEEE polynomial,
/// one (lo, hi) pair for every fold distance 128, 256, ... nLanes*128. The
/// largest (nLanes*128 = 1024) drives the fold-by-eight main loop; the smaller
/// distances collapse the eight lanes to one (128 also folds the single-lane
/// 16-byte remainder).
pub fn makeConstants() FoldConstants {
    var c: FoldConstants = [_]u64{0} ** fold.num_const;
    var k: usize = 0;
    while (k < fold.n_lanes) : (k += 1) {
        const dist = (k + 1) * fold.dist_step;
        const r = foldK(dist);
        c[fold.off(dist)] = r.lo;
        c[fold.off(dist) + 1] = r.hi;
    }
    return c;
}

/// `fold_consts` is the precomputed constant pair set for the IEEE polynomial.
/// Computed at comptime from the polynomial itself (`reflect(x^(d+63) mod P)`
/// and `reflect(x^(d-1) mod P)`); there are no copied magic numbers.
pub const fold_consts: FoldConstants = makeConstants();

/// `reduce128` reduces the reflected 128-bit accumulator `(hi:lo)` to the
/// reflected 32-bit CRC remainder. It runs once per `update` call on a fixed
/// 128 bits, so the straightforward reflected bit-serial form is used: it is
/// provably correct and entirely outside the hot fold loop. Bits are consumed
/// LSB-first from `lo` then `hi`, exactly as the reflected CRC processes the
/// input stream.
pub fn reduce128(hi: u64, lo: u64) u32 {
    var crc: u32 = 0;
    {
        var i: u8 = 0;
        while (i < 64) : (i += 1) {
            const bit: u32 = @as(u32, @truncate((lo >> @intCast(i)) & 1)) ^ (crc & 1);
            crc >>= 1;
            if (bit == 1) crc ^= poly_ref;
        }
    }
    {
        var i: u8 = 0;
        while (i < 64) : (i += 1) {
            const bit: u32 = @as(u32, @truncate((hi >> @intCast(i)) & 1)) ^ (crc & 1);
            crc >>= 1;
            if (bit == 1) crc ^= poly_ref;
        }
    }
    return crc;
}

/// `update` returns the result of adding the bytes in `p` to the CRC-32 value
/// `crc`. For the IEEE polynomial, large inputs on a CPU with a hardware CLMUL
/// unit are folded through the carryless-multiply kernel; every other
/// polynomial, small inputs, the sub-16-byte tail, and any CPU without a CLMUL
/// unit use the scalar table.
pub fn update(crc: u32, tab: *const crc32.Table, p: []const u8) u32 {
    if (!kernel.isEnabled() or p.len < min_bulk or polyOf(tab) != crc32.IEEE) {
        return scalar.update(crc, tab, p);
    }

    const blocks = p.len / 16;
    const bulk_len = blocks * 16;

    // The kernel XORs `init` into the low word of the first 16-byte block. `crc`
    // is the finalized value; the running CRC state is its ones-complement.
    const init: u64 = @as(u64, ~crc);

    const r = fold.foldKernel(p[0..bulk_len], init, &fold_consts);
    var res: u32 = ~reduce128(r.hi, r.lo);

    if (p.len > bulk_len) {
        res = scalar.update(res, tab, p[bulk_len..]);
    }
    return res;
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

const naiveRef = fold.naiveRef;
const naiveIeee = fold.naiveIeee;

test "xnModP identity" {
    // xnModP(0) == 1 (x^0).
    try std.testing.expectEqual(@as(u32, 1), xnModP(0));
}

test "fold constants nonzero and stable" {
    const c = makeConstants();
    try std.testing.expectEqual(fold_consts, c);
    for (c) |v| try std.testing.expect(v != 0);
}

test "reduce128 + foldKernelSoft reproduces IEEE checksum" {
    // Uses the software fold so the fold math is exercised on any CPU,
    // independent of whether a hardware CLMUL unit is present. The naive
    // reflected CRC below is an independent oracle.
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    for ([_]usize{ 128, 129, 144, 160, 256, 4096, 65536 }) |n| {
        const buf = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(buf);
        rng.bytes(buf);

        const bulk = (n / 16) * 16;
        const r = fold.foldKernelSoft(buf[0..bulk], @as(u64, ~@as(u32, 0)), &fold_consts);
        var res: u32 = ~reduce128(r.hi, r.lo);
        if (n > bulk) res = naiveRef(0xedb88320, res, buf[bulk..]);

        try std.testing.expectEqual(naiveIeee(buf), res);
    }
}
