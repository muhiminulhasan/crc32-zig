const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable library module. Consumers add this module via
    // `b.dependency("crc32", .{ ... }).artifact("crc32")` or `b.addModule` and
    // `@import("crc32")` in their code.
    _ = b.addModule("crc32", .{
        .root_source_file = b.path("src/crc32.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit + integration tests. `src/tests.zig` is the test root and pulls in
    // every source file so their colocated `test` blocks are compiled in.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);

    // Benchmark / sanity executable: prints CRC of a synthetic buffer using the
    // scalar path and the fold path and confirms they agree, plus throughput.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "crc32-bench",
        .root_module = bench_mod,
    });
    const install_bench = b.addInstallArtifact(bench, .{});
    const bench_step = b.step("bench", "Build the benchmark executable");
    bench_step.dependOn(&install_bench.step);
}
