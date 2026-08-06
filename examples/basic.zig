//! One-shot CRC-32 of a string and of a larger synthetic buffer.

const std = @import("std");
const crc32 = @import("crc32");

pub fn main() !void {
    const data = "The quick brown fox jumps over the lazy dog";

    // Simplest path: a single call for the IEEE polynomial.
    const sum = crc32.checksumIEEE(data);
    std.debug.print("crc32(\"{s}\") = 0x{x:0>8}\n", .{ data, sum });

    // The same call via an explicit table.
    const tab = crc32.makeTable(crc32.IEEE);
    const sum2 = crc32.checksum(data, &tab);
    std.debug.print("via table             = 0x{x:0>8}\n", .{sum2});

    // `update` lets you fold bytes into a running CRC; starting from 0 it is
    // the same as `checksum`.
    const sum3 = crc32.update(0, &tab, data);
    std.debug.print("via update            = 0x{x:0>8}\n", .{sum3});
}
