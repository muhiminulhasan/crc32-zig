# crc32

SIMD-accelerated CRC-32 for Zig, correct on every CPU.

`crc32` computes the standard reflected CRC-32 for the **IEEE**, **Castagnoli**
and **Koopman** polynomials (and any custom polynomial), producing bit-identical
checksums in every case. For the **IEEE** polynomial on inputs at or above
`update.min_bulk` (512 B), the bulk is folded through the host's hardware
carryless-multiply unit - **`PCLMULQDQ`** on x86_64, **`PMULL`** on aarch64 -
instead of the scalar byte table. Everything else (other polynomials, small
inputs, the sub-16-byte tail, and any CPU without a CLMUL unit) uses a scalar
table. The result is always the standard CRC-32.

## Why carryless multiply

The reflected CRC is a polynomial remainder over GF(2). Folding 16 bytes at a
time through a 64×64→128 carryless multiply turns the per-byte table lookup into
a wide, dependency-light operation: eight independent 128-bit accumulators are
folded forward 128 bytes per iteration, hiding the multiply latency across eight
dependency chains. On an input large enough to fill them, this is an order of
magnitude faster than the scalar table. The fold constants are derived from the
IEEE polynomial itself (`reflect(x^(d+63) mod P)` and `reflect(x^(d-1) mod P)`)
there are no copied magic numbers.

## Works on any CPU

The library builds and produces correct checksums on every target Zig supports.
The hardware fold is compiled in only when the build target advertises the
relevant feature (`pclmul` on x86_64, `crypto` on aarch64); a default
`zig build` targets the native CPU and so enables SIMD automatically on any
modern host. On a generic/baseline target, or any architecture without a CLMUL
instruction, `update` transparently uses the scalar table - same result, no
surprises. At runtime the CPU is probed (CPUID on x86_64, AT_HWCAP on aarch64
Linux, unconditional on Apple Silicon) so a correctly compiled binary never
executes an unsupported instruction.

| Arch    | IEEE bulk path                          | When                                   |
|---------|-----------------------------------------|----------------------------------------|
| x86_64  | `PCLMULQDQ` fold-by-eight (this package)| native/baseline+ feature, gated on CPUID|
| aarch64 | `PMULL`/`PMULL2` fold-by-eight          | `crypto` feature, gated on HWCAP       |
| others  | scalar table                            | always                                 |

Non-IEEE polynomials (Castagnoli, Koopman, custom) always use the scalar table -
the fold constants are derived for the IEEE polynomial.

## Usage

```zig
const crc32 = @import("crc32");

pub fn main() !void {
    const data = "the quick brown fox jumps over the lazy dog";

    // Convenience helpers for the IEEE polynomial.
    const sum: u32 = crc32.checksumIEEE(data);

    // Or the full table-based API.
    var tab = crc32.makeTable(crc32.IEEE);
    const s = crc32.checksum(data, &tab);
    const c = crc32.update(0, &tab, data);

    // Streaming hasher.
    var h = crc32.newIEEE();
    _ = h.write(data[0..20]);
    _ = h.write(data[20..]);
    std.debug.print("{x}\n", .{h.sum32()});
    _ = sum; _ = s; _ = c;
}
```

The API surface: `checksum`, `checksumIEEE`, `update`, `new`, `newIEEE`,
`makeTable`, the `ieee_table` / `IEEETable`, the `IEEE`/`Castagnoli`/`Koopman`
constants, `size`, the `Table` type, and the `Digest` streaming hasher (with
binary `marshalBinary`/`unmarshalBinary`).

A table built with `makeTable` is returned by value; keep it in a `var` and pass
`&tab` to `new`/`update`/`checksum`. `newIEEE` uses the package-global
`ieee_table` and needs no lifetime management.

## Building & testing

```sh
zig build test          # run the full suite (unit + integration)
zig build bench         # build the throughput self-check
./zig-out/bin/crc32-bench
```

For best performance, compile with the native CPU so the CLMUL feature is
advertised (this is what `zig build` does by default):

```sh
zig build -Doptimize=ReleaseFast
```

Indicative throughput on an 8 MiB buffer (your numbers will vary):

```
      scalar:    8.000 MB in  16.7 ms  ( 0.47 GB/s)
  clmul fold:    8.000 MB in   0.9 ms  ( 8.3 GB/s)
all checksums agree: d8c5b150
```

## How it works

For the IEEE polynomial and inputs at or above `min_bulk`, the data is folded
16 bytes at a time into eight independent 128-bit reflected accumulators using
carryless multiplication - eight dependency chains hide the multiply latency.
The lanes are then collapsed to one and reduced to the 32-bit CRC. The fold
constants are derived from the IEEE polynomial; the short tail (< 16 bytes) and
every non-IEEE polynomial use the scalar table, so the result is guaranteed
identical everywhere.

The carryless-multiply primitive has two implementations: a portable bit-serial
reference (`clmul64Soft`, always available) and the hardware instruction
(`pclmulqdq`/`pmull`). A dispatch test asserts they agree bit for bit, and that
both equal an independent textbook reflected-CRC oracle across exhaustive length
sweeps and all three polynomials.

## Layout

| File              | Responsibility                                              |
|-------------------|-------------------------------------------------------------|
| `src/crc32.zig`   | Public API, `Digest`, marshaled state                       |
| `src/scalar.zig`  | Scalar reflected table CRC (the universal fallback)         |
| `src/fold.zig`    | Carryless multiply + eight-lane fold                        |
| `src/update.zig`  | Fold-constant derivation, 128→32 reduction, `update` dispatch|
| `src/kernel.zig`  | Hardware CLMUL detection (CPUID / HWCAP)                    |
| `src/errors.zig`  | Marshal/unmarshal errors                                    |
| `src/tests.zig`   | Test root + cross-cutting integration tests                 |
| `src/bench.zig`   | Throughput self-check executable                            |

## License

MIT. See [LICENSE](LICENSE).
