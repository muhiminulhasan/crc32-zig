//! Test root. References every source file so its colocated `test` blocks are
//! compiled in, and adds the cross-cutting integration tests (dispatch over the
//! fold/scalar branches, seeded and incremental updates).

const std = @import("std");
const crc32 = @import("crc32.zig");
const fold = @import("fold.zig");
const update = @import("update.zig");
const kernel = @import("kernel.zig");
const scalar = @import("scalar.zig");

// Pull in colocated test blocks from every module.
comptime {
    _ = @import("errors.zig");
    _ = @import("scalar.zig");
    _ = @import("fold.zig");
    _ = @import("update.zig");
    _ = @import("kernel.zig");
    _ = @import("crc32.zig");
}

const naiveIeee = fold.naiveIeee;
const naiveRef = fold.naiveRef;

// `std` IEEE CRC-32 as an independent cross-oracle for the IEEE polynomial.
fn stdIeee(data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    return hasher.final();
}

fn randBytes(buf: []u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
}

test "integration: IEEE matches std.hash.Crc32 across lengths" {
    var n: usize = 0;
    while (n <= 700) : (n += 1) {
        const buf = std.testing.allocator.alloc(u8, n) catch unreachable;
        defer std.testing.allocator.free(buf);
        randBytes(buf, n);
        try std.testing.expectEqual(stdIeee(buf), crc32.checksumIEEE(buf));
    }
    for ([_]usize{ 1024, 4096, 65537, 1 << 16 + 13, 200000 }) |ln| {
        const buf = try std.testing.allocator.alloc(u8, ln);
        defer std.testing.allocator.free(buf);
        randBytes(buf, ln + 1);
        try std.testing.expectEqual(stdIeee(buf), crc32.checksumIEEE(buf));
    }
}

test "integration: all polynomials match naive oracle" {
    const polys = [_]struct { name: []const u8, poly: u32 }{
        .{ .name = "IEEE", .poly = crc32.IEEE },
        .{ .name = "Castagnoli", .poly = crc32.Castagnoli },
        .{ .name = "Koopman", .poly = crc32.Koopman },
    };
    for (polys) |p| {
        var tab = crc32.makeTable(p.poly);
        var n: usize = 0;
        while (n <= 600) : (n += 1) {
            const buf = try std.testing.allocator.alloc(u8, n);
            defer std.testing.allocator.free(buf);
            randBytes(buf, n * 31 +% @as(u64, p.poly));
            try std.testing.expectEqual(
                naiveRef(p.poly, 0, buf),
                crc32.checksum(buf, &tab),
            );
        }
    }
}

test "integration: seeded update" {
    const seeds = [_]u32{ 0, 1, 0xffffffff, 0xdeadbeef, 12345 };
    var prng = std.Random.DefaultPrng.init(2);
    const rng = prng.random();
    for ([_]usize{ 0, 8, 16, 100, 511, 512, 513, 4096, 70000 }) |n| {
        const buf = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(buf);
        rng.bytes(buf);
        for (seeds) |seed| {
            const got = crc32.update(seed, crc32.IEEETable, buf);
            const want = naiveRef(crc32.IEEE, seed, buf);
            try std.testing.expectEqual(want, got);
        }
    }
}

test "integration: chunked incremental update" {
    const polys = [_]u32{ crc32.IEEE, crc32.Castagnoli, crc32.Koopman };
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    for (polys) |poly| {
        var tab = crc32.makeTable(poly);
        const data = try std.testing.allocator.alloc(u8, 5000);
        defer std.testing.allocator.free(data);
        rng.bytes(data);

        var crc: u32 = 0;
        var i: usize = 0;
        while (i < data.len) {
            var step = 1 + rng.uintLessThan(usize, 258);
            if (i + step > data.len) step = data.len - i;
            crc = crc32.update(crc, &tab, data[i .. i + step]);
            i += step;
        }
        try std.testing.expectEqual(naiveRef(poly, 0, data), crc);
    }
}

test "integration: dispatch both branches (fold vs scalar)" {
    // Drive both the SIMD fold path and the scalar fallback, confirming each
    // matches the naive oracle. Only run the forced-fold branch when the host
    // actually has a usable CLMUL unit (forcing it elsewhere would execute an
    // unsupported instruction).
    const saved = kernel.has_kernel;
    defer kernel.has_kernel = saved;

    var prng = std.Random.DefaultPrng.init(12);
    const rng = prng.random();
    const check = struct {
        fn run(rng_: std.Random) !void {
            for ([_]usize{ 64, 128, 129, 160, 511, 512, 513, 1000, 4096, 70000 }) |n| {
                const buf = try std.testing.allocator.alloc(u8, n);
                defer std.testing.allocator.free(buf);
                rng_.bytes(buf);
                const got = crc32.checksumIEEE(buf);
                try std.testing.expectEqual(naiveIeee(buf), got);
            }
        }
    }.run;

    kernel.has_kernel = false;
    try check(rng);
    if (kernel.detectHardware()) {
        kernel.has_kernel = true;
        try check(rng);
    }
}

test "integration: force kernel on small inputs (hardware only)" {
    // Mirrors the small-input kernel sweep with a lowered `min_bulk`, covering
    // the no-tail and with-tail branches deterministically. Requires the
    // hardware CLMUL path; skipped on hosts without one.
    if (!kernel.detectHardware()) return error.SkipZigTest;

    const saved_min = update.min_bulk;
    const saved_k = kernel.has_kernel;
    defer {
        update.min_bulk = saved_min;
        kernel.has_kernel = saved_k;
    }
    update.min_bulk = 128;
    kernel.has_kernel = true;

    var prng = std.Random.DefaultPrng.init(4);
    const rng = prng.random();
    for ([_]usize{ 128, 129, 143, 144, 160, 255, 256, 257, 4095, 4096 }) |n| {
        const buf = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(buf);
        rng.bytes(buf);
        for ([_]u32{ 0, 0xabcdef01 }) |seed| {
            const got = crc32.update(seed, crc32.IEEETable, buf);
            try std.testing.expectEqual(naiveRef(crc32.IEEE, seed, buf), got);
        }
    }
}

test "integration: fold kernel equals software fold (any host)" {
    // On a host with hardware CLMUL this proves the SIMD fold matches the
    // software reference bit for bit; on any other host both sides run the
    // software clmul and the comparison is trivially exact.
    const c = update.fold_consts;
    var prng = std.Random.DefaultPrng.init(13);
    const rng = prng.random();
    for ([_]usize{ 128, 144, 160, 256, 4096, 65536 }) |n| {
        const buf = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(buf);
        rng.bytes(buf);
        const init = rng.int(u64);
        const a = fold.foldKernel(buf, init, &c);
        const b = fold.foldKernelSoft(buf, init, &c);
        try std.testing.expectEqual(b, a);
    }
}
