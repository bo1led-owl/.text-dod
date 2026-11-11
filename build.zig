const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const assembler = setupAssembler(b, target, optimize);

    try setupBench(b, assembler, &.{ "time_wall_clock", "cache_misses" }, &.{
        setupExecutable(b, target, optimize, b.path("dod.zig"), "dod-aos", &.{
            .{ "use_multiarraylist", false },
            .{ "use_u64", false },
        }),
        setupExecutable(b, target, optimize, b.path("dod.zig"), "dod-soa", &.{
            .{ "use_multiarraylist", true },
            .{ "use_u64", true },
        }),
        setupExecutable(b, target, optimize, b.path("dod.zig"), "dod-aos-naive", &.{
            .{ "use_multiarraylist", false },
            .{ "use_u64", true },
        }),
        setupExecutable(b, target, optimize, b.path("oop.zig"), "oop-arena", &.{
            .{ "use_arena", true },
        }),
        setupExecutable(b, target, optimize, b.path("oop.zig"), "oop", &.{
            .{ "use_arena", false },
        }),
    });
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
            .single_threaded = true,
        }),
    });

    const assembler_installation = b.addInstallArtifact(assembler, .{});
    b.getInstallStep().dependOn(&assembler_installation.step);

    const run_assembler_step = b.step("assemble", "Run assembler");
    const assembler_cmd = b.addRunArtifact(assembler);
    run_assembler_step.dependOn(&assembler_cmd.step);
    assembler_cmd.addPassthruArgs();

    return assembler;
}

fn setupBench(
    b: *std.Build,
    assembler: *std.Build.Step.Compile,
    metrics: []const []const u8,
    impls: []const *std.Build.Step.Compile,
) !void {
    const internal_assembler_cmd = b.addRunArtifact(assembler);
    internal_assembler_cmd.addFileArg2(b.path("benchmark-input"), .{});
    const assembled_input = internal_assembler_cmd.addOutputFileArg2("benchmark-input-assembled", .{});

    const bench_step = b.step("bench", "Run benchmarks");

    const bench_cmd = b.addSystemCommand(&.{
        "hyperfine", "-N",
        "--metrics", try std.mem.join(b.allocator, ",", metrics),
    });

    for (impls) |impl| {
        bench_cmd.addArgs(&.{ "-n", impl.name });
        bench_cmd.addArtifactArg2(impl, .{});
    }
    bench_cmd.addArg("--input");
    bench_cmd.addFileArg2(assembled_input, .{});

    bench_step.dependOn(&bench_cmd.step);
    for (impls) |impl| {
        bench_step.dependOn(&impl.step);
    }
}

fn setupExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    source_file: std.Build.LazyPath,
    name: []const u8,
    flags: []const struct { []const u8, bool },
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = source_file,
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        }),
    });

    const options: *std.Build.Step.Options = .create(b);
    for (flags) |flag| {
        options.addOption(bool, flag.@"0", flag.@"1");
    }
    exe.root_module.addOptions("config", options);

    const installation = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&installation.step);

    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name}));
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(&installation.step);
    run_cmd.addPassthruArgs();

    return exe;
}
