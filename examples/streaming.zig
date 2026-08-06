//! Streaming CRC-32: feed a buffer through a `Digest` in chunks.

const std = @import("std");
const crc32 = @import("crc32");

pub fn main() !void {
    var h = crc32.newIEEE();

    const data = "The quick brown fox jumps over the lazy dog";

    // Simulate reading a stream in fixed-size chunks.
    const chunk_size: usize = 10;
    var i: usize = 0;
    while (i < data.len) {
        const end = @min(i + chunk_size, data.len);
        _ = h.write(data[i..end]);
        i = end;
    }

    const streamed = h.sum32();
    const one_shot = crc32.checksumIEEE(data);

    std.debug.print("streamed crc32 = 0x{x:0>8}\n", .{streamed});
    std.debug.print("one-shot  crc32 = 0x{x:0>8}\n", .{one_shot});
    std.debug.print("match          = {}\n", .{streamed == one_shot});

    // reset() returns the digest to its initial state.
    h.reset();
    std.debug.print("after reset    = 0x{x:0>8}\n", .{h.sum32()});
}
