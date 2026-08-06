//! Carryless-multiply fold for the IEEE polynomial. The fold splits the input
//! into eight independent 128-bit accumulators and folds them forward 128 bytes
//! per iteration using a 64x64 -> 128 carryless multiply.
//!
//! ## CLMUL backends
//!
//! `clmul64` is the carryless-multiply primitive. It has two implementations:
//!
//! * `clmul64Soft` - portable bit-serial, always available, always correct.
//! * `clmul64Hw` - the host's hardware CLMUL unit (`PCLMULQDQ` on x86_64,
//!   `PMULL`/`PMULL2` on aarch64), emitted only on those arches.
//!
//! On every other architecture, and on x86_64/aarch64 cores that lack the
//! instruction at runtime, `update` routes to the scalar table instead (see
//! `kernel.zig` and `update.zig`), so the package is correct on any CPU.
//!
//! `foldKernel` is the fold using the arch-default clmul (the production
//! path); `foldKernelSoft` is the same loop driven by the software clmul and
//! exists so the fold math can be exercised on any host.

const std = @import("std");
const builtin = @import("builtin");

pub const n_lanes: usize = 8;
pub const dist_step: usize = 128; // bits per accumulator block

pub const k_fold128_lo: usize = 0;
pub const k_fold1024_lo: usize = 2 * (n_lanes - 1); // main-loop distance = nLanes*128 = 1024
pub const num_const: usize = 2 * n_lanes;

pub const FoldConstants = [num_const]u64;
pub const FoldResult = struct { hi: u64, lo: u64 };
pub const ClmulFn = *const fn (u64, u64) FoldResult;

/// `off` returns the index of the low constant for a fold distance of
/// `dist_bits` bits (`dist_bits` a positive multiple of 128).
pub fn off(dist_bits: usize) usize {
    return 2 * (dist_bits / dist_step - 1);
}

/// `clmul64Soft` is the portable 64x64 -> 128 carryless product. Always
/// available; the exact specification the hardware paths reproduce.
pub fn clmul64Soft(a: u64, b: u64) FoldResult {
    var hi: u64 = 0;
    var lo: u64 = 0;
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        if (((b >> @intCast(i)) & 1) == 0) continue;
        if (i == 0) {
            lo ^= a;
        } else {
            lo ^= a << @intCast(i);
            hi ^= a >> @as(u6, @intCast(64 - i));
        }
    }
    return .{ .hi = hi, .lo = lo };
}

/// Whether the current compilation target emits a hardware CLMUL instruction.
///
/// `pclmulqdq` (x86_64) and `pmull` (aarch64) each require their target to
/// advertise the corresponding feature before the assembler will accept the
/// mnemonic, so the instruction is emitted only when the comptime target has
/// it. A default `zig build` targets the native CPU and so advertises the
/// feature on any modern host; a generic/baseline target falls back to the
/// software clmul (still correct). Build with `-Dcpu=native` to be explicit.
pub const arch_has_clmul: bool = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crypto),
    else => false,
};

/// `clmul64` returns the 128-bit carryless product of `a` and `b`. Uses the
/// hardware CLMUL unit where the target advertises one (x86_64 always; aarch64
/// when built with the `crypto` feature); the bit-serial reference otherwise.
/// Both implementations agree bit for bit (asserted by tests). The hardware
/// assembly is inlined under the comptime gate so the dead branch (and its
/// feature-requiring instruction) is never analyzed when the feature is absent.
pub fn clmul64(a: u64, b: u64) FoldResult {
    if (comptime arch_has_clmul) {
        if (comptime builtin.cpu.arch == .x86_64) {
            // PCLMULQDQ with imm=0 carries out the 64x64->128 carryless product
            // of the low halves of both xmm operands; the result fills the
            // 128-bit destination. `u128` maps little-endian onto the xmm
            // register. Execution is gated at runtime by CPUID (kernel.zig).
            var av: u128 = @as(u128, a);
            const bv: u128 = @as(u128, b);
            asm ("pclmulqdq $0, %[b], %[a]"
                : [a] "+x" (av)
                : [b] "x" (bv));
            return .{ .hi = @truncate(av >> 64), .lo = @truncate(av) };
        } else { // aarch64 + crypto
            // PMULL Vd.1Q, Vn.1D, Vm.1D : 64-bit polynomial multiply of the low
            // halves, producing the full 128-bit result.
            const av: u128 = @as(u128, a);
            const bv: u128 = @as(u128, b);
            var out: u128 = undefined;
            asm ("pmull %[o].1q, %[a].1d, %[b].1d"
                : [o] "=w" (out)
                : [a] "w" (av),
                  [b] "w" (bv));
            return .{ .hi = @truncate(out >> 64), .lo = @truncate(out) };
        }
    }
    return clmul64Soft(a, b);
}

/// `foldKernelImpl` is the eight-lane fold parameterized over its carryless
/// multiplier. Specialized at comptime, so there is zero indirect-call overhead
/// in the hot loop. `foldKernel` uses the arch-default clmul; `foldKernelSoft`
/// uses the software reference so the fold can be exercised on any CPU.
fn foldKernelImpl(
    comptime clmul: ClmulFn,
    p_in: []const u8,
    init: u64,
    c: *const FoldConstants,
) FoldResult {
    var p = p_in;
    var xh: [n_lanes]u64 = undefined;
    var xl: [n_lanes]u64 = undefined;
    {
        var i: usize = 0;
        while (i < n_lanes) : (i += 1) {
            xl[i] = le64(p[i * 16 ..][0..8]);
            xh[i] = le64(p[i * 16 + 8 ..][0..8]);
        }
    }
    xl[0] ^= init;
    p = p[n_lanes * 16 ..];

    while (p.len >= n_lanes * 16) {
        var i: usize = 0;
        while (i < n_lanes) : (i += 1) {
            const nh = le64(p[i * 16 + 8 ..][0..8]);
            const nl = le64(p[i * 16 ..][0..8]);
            const r = foldPair(clmul, c, k_fold1024_lo, xh[i], xl[i], nh, nl);
            xh[i] = r.hi;
            xl[i] = r.lo;
        }
        p = p[n_lanes * 16 ..];
    }

    // Collapse the lanes into one: the last lane is newest; fold lane i by
    // (nLanes-1-i) blocks and XOR into the accumulator.
    var ah = xh[n_lanes - 1];
    var al = xl[n_lanes - 1];
    {
        var i: usize = 0;
        while (i < n_lanes - 1) : (i += 1) {
            const r = foldPair(clmul, c, off((n_lanes - 1 - i) * dist_step), xh[i], xl[i], ah, al);
            ah = r.hi;
            al = r.lo;
        }
    }

    // Fold any remaining whole 16-byte blocks single-lane (distance 128).
    while (p.len >= 16) {
        const nh = le64(p[8..][0..8]);
        const nl = le64(p[0..][0..8]);
        const r = foldPair(clmul, c, k_fold128_lo, ah, al, nh, nl);
        ah = r.hi;
        al = r.lo;
        p = p[16..];
    }
    return .{ .hi = ah, .lo = al };
}

/// `foldPair` folds the 128-bit accumulator `(ah:al)` by the distance whose low
/// constant sits at index `o`, then XORs in `(nh:nl)`:
///   acc = clmul(al, c[o]) ^ clmul(ah, c[o+1]) ^ (nh:nl)
fn foldPair(
    comptime clmul: ClmulFn,
    c: *const FoldConstants,
    o: usize,
    ah: u64,
    al: u64,
    nh: u64,
    nl: u64,
) FoldResult {
    const x = clmul(al, c[o]);
    const y = clmul(ah, c[o + 1]);
    return .{ .hi = x.hi ^ y.hi ^ nh, .lo = x.lo ^ y.lo ^ nl };
}

/// `le64` reads a little-endian u64 from the first 8 bytes of `p`. The caller
/// guarantees `p.len >= 8`.
pub fn le64(p: []const u8) u64 {
    return @as(u64, p[0]) |
        (@as(u64, p[1]) << 8) |
        (@as(u64, p[2]) << 16) |
        (@as(u64, p[3]) << 24) |
        (@as(u64, p[4]) << 32) |
        (@as(u64, p[5]) << 40) |
        (@as(u64, p[6]) << 48) |
        (@as(u64, p[7]) << 56);
}

/// `foldKernel` is the production fold using the arch-default clmul (hardware
/// on x86_64/aarch64, software elsewhere). Consumes `p` (whole 16-byte blocks,
/// `len(p) >= 128`); merges `init` (=`^crc`) into the low word of the first
/// block.
pub fn foldKernel(p: []const u8, init: u64, c: *const FoldConstants) FoldResult {
    return foldKernelImpl(clmul64, p, init, c);
}

/// `foldKernelSoft` is the same fold driven by the software clmul. It exists so
/// the fold math can be exercised on any CPU, including ones without a hardware
/// CLMUL unit (where the production path instead uses the scalar table).
pub fn foldKernelSoft(p: []const u8, init: u64, c: *const FoldConstants) FoldResult {
    return foldKernelImpl(clmul64Soft, p, init, c);
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

test "clmul64 soft matches hardware" {
    // Asserts the hardware path (when present) is bit-identical to the
    // portable reference - the correctness contract the SIMD fold relies on.
    const cases = [_]struct { a: u64, b: u64 }{
        .{ .a = 3, .b = 3 },
        .{ .a = 0, .b = 0xffffffffffffffff },
        .{ .a = 1, .b = 1 },
        .{ .a = 0xffffffffffffffff, .b = 2 },
        .{ .a = 0x123456789abcdef0, .b = 0x0fedcba987654321 },
        .{ .a = 1 << 63, .b = 1 << 1 },
        .{ .a = 0xdeadbeefcafef00d, .b = 0x1111111111111111 },
    };
    for (cases) |c| {
        const s = clmul64Soft(c.a, c.b);
        const h = clmul64(c.a, c.b);
        try std.testing.expectEqual(s.hi, h.hi);
        try std.testing.expectEqual(s.lo, h.lo);
    }
}

test "clmul64 known values" {
    // (x+1)^2 = x^2 + 1  -> clmul(3,3) = 5
    const r0 = clmul64(3, 3);
    try std.testing.expectEqual(@as(u64, 0), r0.hi);
    try std.testing.expectEqual(@as(u64, 5), r0.lo);

    try std.testing.expectEqual(@as(u64, 0), clmul64(0, 0xffffffffffffffff).hi);
    try std.testing.expectEqual(@as(u64, 0), clmul64(0, 0xffffffffffffffff).lo);

    try std.testing.expectEqual(@as(u64, 0), clmul64(1, 1).hi);
    try std.testing.expectEqual(@as(u64, 1), clmul64(1, 1).lo);

    const r1 = clmul64(0xffffffffffffffff, 2);
    try std.testing.expectEqual(@as(u64, 1), r1.hi);
    try std.testing.expectEqual(@as(u64, 0xfffffffffffffffe), r1.lo);

    // high-bit carry: clmul(1<<63, 1<<1) sets hi bit 0.
    const r2 = clmul64(1 << 63, 1 << 1);
    try std.testing.expectEqual(@as(u64, 1), r2.hi);
    try std.testing.expectEqual(@as(u64, 0), r2.lo);
}

// naiveIeee / naiveRef are textbook reflected CRC-32 oracles, fully independent
// of the table/fold machinery - used as the authoritative reference in tests.
pub fn naiveIeee(data: []const u8) u32 {
    return naiveRef(0xedb88320, 0, data);
}

pub fn naiveRef(poly: u32, crc_init: u32, data: []const u8) u32 {
    var crc = ~crc_init;
    for (data) |b| {
        crc ^= @as(u32, b);
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            if ((crc & 1) == 1) {
                crc = (crc >> 1) ^ poly;
            } else {
                crc >>= 1;
            }
        }
    }
    return ~crc;
}
