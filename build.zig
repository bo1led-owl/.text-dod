const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const assembler = setupAssembler(b, target, optimize);

    const dod = setupExecutable(b, target, optimize, "dod", "the data-oriented implementation");
    const oop = setupExecutable(b, target, optimize, "oop", "the object-oriented implementation");

    setupBench(b, assembler, dod, oop);
}

fn setupAssembler(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const assembler = b.addExecutable(.{
        .name = "assembler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("assembler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const assembler_installation = b.addInstallArtifact(assembler, .{});
    b.getInstallStep().dependOn(&assembler_installation.step);

    const run_assembler_step = b.step("assemble", "Assemble a file");
    const assembler_cmd = b.addRunArtifact(assembler);
    run_assembler_step.dependOn(&assembler_cmd.step);
    assembler_cmd.addPassthruArgs();

    return assembler;
}

fn setupBench(
    b: *std.Build,
    assembler: *std.Build.Step.Compile,
    dod: *std.Build.Step.Compile,
    oop: *std.Build.Step.Compile,
) void {
    const internal_assembler_cmd = b.addRunArtifact(assembler);
    internal_assembler_cmd.addFileArg2(b.path("benchmark-input"), .{});
    const assemblered_input = internal_assembler_cmd.addOutputFileArg2("benchmark-input-assembled", .{});

    const bench_step = b.step("bench", "Run benchmarks");

    const bench_cmd = b.addSystemCommand(&.{
        "hyperfine", "-N",
        "--metrics", "time_wall_clock,memory_peak_resident,cache_misses",
        // "-w",         "10",
        // "--min-runs", "20",
    });
    bench_cmd.addArgs(&.{ "-n", "dod" });
    bench_cmd.addArtifactArg2(dod, .{});
    bench_cmd.addArgs(&.{ "-n", "oop" });
    bench_cmd.addArtifactArg2(oop, .{});
    bench_cmd.addArg("--input");
    bench_cmd.addFileArg2(assemblered_input, .{});

    bench_step.dependOn(&bench_cmd.step);
    bench_step.dependOn(b.getInstallStep());
}

fn setupExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    name: []const u8,
    desc: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        }),
    });

    const installation = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&installation.step);

    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{desc}));
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(&installation.step);
    run_cmd.addPassthruArgs();

    return exe;
}
