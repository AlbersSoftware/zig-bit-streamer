const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module — also imported by the example below, and by any
    // other project depending on this one via build.zig.zon.
    const bit_reader_module = b.addModule("bit_reader", .{
        .root_source_file = b.path("src/bit_reader.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test` — runs the tests embedded in src/bit_reader.zig.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bit_reader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build run` — builds and runs examples/example.zig, which
    // @imports the library as "bit_reader" and prints a small demo.
    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/example.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("bit_reader", bit_reader_module);

    const example_exe = b.addExecutable(.{
        .name = "example",
        .root_module = example_module,
    });
    const run_example = b.addRunArtifact(example_exe);
    const run_step = b.step("run", "Run the usage example");
    run_step.dependOn(&run_example.step);
}
