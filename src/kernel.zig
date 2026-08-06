//! Hardware CLMUL detection. The fold itself lives in `fold.zig`; this module
//! decides at runtime whether `update` may route IEEE bulk through it. The
//! detection result is cached; tests force a branch by setting `has_kernel`
//! directly.
//!
//! ## Per-arch detection
//!
//! * x86_64: `PCLMULQDQ` is probed with `CPUID.01H:ECX[bit 1]`. The probe is
//!   always safe to run and accurate, so the default build accelerates without
//!   any special flags.
//! * aarch64: `FEAT_PMULL` is present on Apple Silicon (always on) and on every
//!   contemporary aarch64 server core. On Linux with libc linked, the AT_HWCAP
//!   flag is checked at runtime; otherwise the comptime target feature is
//!   trusted (build with `-Dcpu=native` to enable).
//! * every other arch: no CLMUL path is emitted; `update` uses the scalar table
//!   and the package remains fully correct.

const std = @import("std");
const builtin = @import("builtin");
const fold = @import("fold.zig");

var detected: bool = false;
var detected_set: bool = false;

/// `has_kernel` overrides auto-detection when set. `null` (the default) means
/// "auto-detect on first use"; tests set it to `true`/`false` to force a branch.
pub var has_kernel: ?bool = null;

/// `isEnabled` reports whether `update` should route IEEE bulk through the CLMUL
/// fold. Honors an explicit `has_kernel` override; otherwise returns the cached
/// result of `detectHardware`.
pub fn isEnabled() bool {
    if (has_kernel) |v| return v;
    if (!detected_set) {
        detected = detectHardware();
        detected_set = true;
    }
    return detected;
}

/// `detectHardware` reports whether the running CPU supports the hardware CLMUL
/// instruction the fold was compiled with. `false` on any build where the
/// comptime target did not advertise a CLMUL feature (no hardware path is
/// compiled in, so the scalar table is used - correct, and faster than driving
/// the fold with the software clmul).
pub fn detectHardware() bool {
    if (comptime !fold.arch_has_clmul) return false;
    if (comptime builtin.cpu.arch == .x86_64) {
        return x86HasPclmul();
    } else if (comptime builtin.cpu.arch == .aarch64) {
        return aarch64HasPmull();
    } else {
        return false;
    }
}

fn x86HasPclmul() bool {
    // CPUID.01H:ECX.PCLMULQDQ[bit 1].
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (@as(u32, 1)));
    return (ecx & (1 << 1)) != 0;
}

fn aarch64HasPmull() bool {
    // Apple Silicon always has FEAT_PMULL.
    if (comptime builtin.os.tag == .macos or
        builtin.os.tag == .ios or
        builtin.os.tag == .tvos or
        builtin.os.tag == .watchos)
    {
        return true;
    }
    // On Linux with libc linked, probe AT_HWCAP (HWCAP_PMULL = bit 3).
    if (comptime builtin.os.tag == .linux and builtin.link_libc) {
        const hwcap = std.c.getauxval(std.elf.AT_HWCAP);
        const HWCAP_PMULL: usize = 1 << 3;
        return (hwcap & HWCAP_PMULL) != 0;
    }
    // Otherwise trust the comptime target feature (build with `-Dcpu=native`
    // to enable); fall back to scalar otherwise.
    return std.Target.aarch64.featureSetHas(builtin.cpu.features, .crypto);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "foldKernel is callable on the host" {
    // Smoke-test the production fold end-to-end at a few sizes. On a host with
    // a hardware CLMUL unit this exercises the SIMD path; elsewhere the same
    // loop runs on the software clmul. Either way the result equals the
    // software fold bit for bit.
    const c = @import("update.zig").fold_consts;
    var prng = std.Random.DefaultPrng.init(21);
    const rng = prng.random();
    for ([_]usize{ 128, 256, 512, 4096 }) |n| {
        const buf = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(buf);
        rng.bytes(buf);
        const init: u64 = 0x0123456789abcdef;
        const got = @import("fold.zig").foldKernel(buf, init, &c);
        const want = @import("fold.zig").foldKernelSoft(buf, init, &c);
        try std.testing.expectEqual(want, got);
    }
}

test "detectHardware is callable" {
    _ = detectHardware();
    _ = isEnabled();
}
