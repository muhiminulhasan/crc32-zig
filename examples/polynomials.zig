//! CRC-32 under the IEEE, Castagnoli and Koopman polynomials.

const std = @import("std");
const crc32 = @import("crc32");

pub fn main() !void {
    const data = "123456789";

    const ieee_tab = crc32.makeTable(crc32.IEEE);
    const cast_tab = crc32.makeTable(crc32.Castagnoli);
    const koop_tab = crc32.makeTable(crc32.Koopman);

    std.debug.print("IEEE       (CRC-32)  : 0x{x:0>8}\n", .{crc32.checksum(data, &ieee_tab)});
    std.debug.print("Castagnoli (CRC-32C) : 0x{x:0>8}\n", .{crc32.checksum(data, &cast_tab)});
    std.debug.print("Koopman    (CRC-32K) : 0x{x:0>8}\n", .{crc32.checksum(data, &koop_tab)});

    // A custom reflected polynomial works the same way (scalar path).
    const custom = crc32.makeTable(0x04C11DB7); // non-reflected IEEE, as an example
    std.debug.print("custom poly          : 0x{x:0>8}\n", .{crc32.checksum(data, &custom)});
}
