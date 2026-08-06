//! Benchmark and self-check executable. Allocates a synthetic buffer, hashes it
//! with the scalar path and the CLMUL-fold path, asserts the two agree, and
//! prints throughput for each. Run with `zig build bench && ./zig-out/bin/crc32-bench`.

const std = @import("std");
const builtin = @import("builtin");
const crc32 = @import("crc32.zig");
const kernel = @import("kernel.zig");
const scalar = @import("scalar.zig");

/// Monotonic time in nanoseconds. `std.time` no longer exposes a timer in
/// 0.16, so we read the OS high-resolution clock directly.
fn nowNs() i128 {
    if (comptime builtin.os.tag == .windows) {
        var freq: std.os.windows.LARGE_INTEGER = 0;
        var count: std.os.windows.LARGE_INTEGER = 0;
        _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq);
        _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&count);
        return @divFloor(@as(i128, count) * 1_000_000_000, @as(i128, freq));
    } else {
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(.MONOTONIC, &ts) catch return 0;
        return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const N: usize = 8 * 1024 * 1024;
    const buf = try alloc.alloc(u8, N);
    defer alloc.free(buf);
    var prng = std.Random.DefaultPrng.init(0xC32);
    prng.random().bytes(buf);

    // Enable the hardware CLMUL path if present.
    const hw = kernel.detectHardware();
    kernel.has_kernel = hw;

    const expect = crc32.checksumIEEE(buf);

    // Scalar baseline (always available).
    var t0 = nowNs();
    const scalar_sum = scalar.update(0, crc32.IEEETable, buf);
    var t1 = nowNs();
    if (scalar_sum != expect) {
        std.debug.print("SCALAR MISMATCH: {x} != {x}\n", .{ scalar_sum, expect });
        std.process.exit(1);
    }
    printRow("scalar", buf.len, t1 - t0);

    if (hw) {
        // CLMUL fold path.
        t0 = nowNs();
        const fold_sum = crc32.update(0, crc32.IEEETable, buf);
        t1 = nowNs();
        if (fold_sum != expect) {
            std.debug.print("FOLD MISMATCH: {x} != {x}\n", .{ fold_sum, expect });
            std.process.exit(1);
        }
        printRow("clmul fold", buf.len, t1 - t0);
    } else {
        std.debug.print("clmul fold: (no hardware CLMUL unit on this CPU; using scalar)\n", .{});
    }

    std.debug.print("all checksums agree: {x}\n", .{expect});
}

fn printRow(label: []const u8, bytes: usize, ns: i128) void {
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    std.debug.print("{s:>12}: {d:8.3} MB in {d:7.3} ms  ({d:6.2} GB/s)\n", .{
        label,
        @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0),
        secs * 1000.0,
        gb / secs,
    });
}

