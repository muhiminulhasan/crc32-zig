//! Marshaling a `Digest`: checkpoint state and resume it elsewhere.

const std = @import("std");
const crc32 = @import("crc32");

pub fn main() !void {
    // Compute a partial checksum...
    var h = crc32.newIEEE();
    _ = h.write("the quick brown fox");
    std.debug.print("checkpoint crc32 = 0x{x:0>8}\n", .{h.sum32()});

    // ...serialize the state into a 12-byte buffer...
    const state = h.marshalBinary();
    std.debug.print("marshaled ({d} bytes): ", .{state.len});
    for (state) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\n", .{});

    // ...and resume it in a fresh digest.
    var resumed = crc32.newIEEE();
    try resumed.unmarshalBinary(&state);
    _ = resumed.write(" jumps over the lazy dog");

    const final = resumed.sum32();
    const one_shot = crc32.checksumIEEE("the quick brown fox jumps over the lazy dog");

    std.debug.print("resumed   crc32 = 0x{x:0>8}\n", .{final});
    std.debug.print("one-shot  crc32 = 0x{x:0>8}\n", .{one_shot});
    std.debug.print("match          = {}\n", .{final == one_shot});
}
