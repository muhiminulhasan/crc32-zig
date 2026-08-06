//! Scalar table-based reflected CRC-32. This is the universal fallback path
//! used for non-IEEE polynomials, small inputs and the sub-16-byte tail, and on
//! any CPU without a hardware carryless-multiply unit. It produces the standard
//! reflected CRC-32 (the form used by Ethernet/gzip/zip/png, iSCSI, etc.).

const std = @import("std");
const Table = @import("crc32.zig").Table;

/// `update` returns the result of adding the bytes in `p` to `crc` using the
/// reflected table `tab`.
pub fn update(crc_in: u32, tab: *const Table, p: []const u8) u32 {
    var crc = ~crc_in;
    for (p) |b| {
        const idx: u8 = @truncate((crc ^ @as(u32, b)) & 0xff);
        crc = tab[idx] ^ (crc >> 8);
    }
    return ~crc;
}

/// `makeTable` builds the 256-word reflected table for `poly`. Returns the
/// table by value (no allocator).
pub fn makeTable(poly: u32) Table {
    @setEvalBranchQuota(10000);
    var t: Table = undefined;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var crc = i;
        var j: u32 = 0;
        while (j < 8) : (j += 1) {
            if ((crc & 1) == 1) {
                crc = (crc >> 1) ^ poly;
            } else {
                crc >>= 1;
            }
        }
        t[i] = crc;
    }
    return t;
}
