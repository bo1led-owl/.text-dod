const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const preprocess = b.addExecutable(.{
        .name = "preprocess",
        .root_module = b.createModule(.{
            .root_source_file = b.path("preprocess.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const preprocess_installation = b.addInstallArtifact(preprocess, .{});
    b.getInstallStep().dependOn(&preprocess_installation.step);

    const run_preprocess_step = b.step("preprocess", "Run preprocessing");
    const preprocess_cmd = b.addRunArtifact(preprocess);
    run_preprocess_step.dependOn(&preprocess_cmd.step);
    preprocess_cmd.addPassthruArgs();

    const dod = setupExecutable(b, target, optimize, "dod", "the data-oriented implementation");
    const oop = setupExecutable(b, target, optimize, "oop", "the object-oriented implementation");

    const internal_preprocess_cmd = b.addRunArtifact(preprocess);
    internal_preprocess_cmd.addFileArg2(b.path("input"), .{});
    const preprocessed_input = internal_preprocess_cmd.addOutputFileArg2("input-preprocessed", .{});

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
    bench_cmd.addFileArg2(preprocessed_input, .{});

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
