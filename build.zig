const std = @import("std");

const InputPattern = struct {
    name: []const u8,
    seed: u64,
    n_statements: u32,
    max_statement_depth: u16,
    random_depths: bool,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bytecode = b.createModule(.{ .root_source_file = b.path("bytecode/format.zig") });

    _ = setupAssembler(b, target, optimize, bytecode);
    _ = setupDisassembler(b, target, optimize, bytecode);
    const generator = setupGenerator(b, target, optimize, bytecode);

    // execution benchmark
    try setupBenchmark(
        b,
        generator,
        "exec",
        try setupImplementations(b, target, optimize, bytecode, &.{
            .{ b.path("impls/oop.zig"), "oop", &.{
                .{ "use_arena", false },
                .{ "count_var_refs", false },
            } },
            .{ b.path("impls/oop.zig"), "oop-arena", &.{
                .{ "use_arena", true },
                .{ "count_var_refs", false },
            } },
            .{ b.path("impls/dod.zig"), "aos", &.{
                .{ "use_multiarraylist", false },
                .{ "use_u64", true },
                .{ "count_var_refs", false },
            } },
            .{ b.path("impls/dod.zig"), "soa", &.{
                .{ "use_multiarraylist", true },
                .{ "use_u64", true },
                .{ "count_var_refs", false },
            } },
            .{ b.path("impls/dod.zig"), "aos-compact", &.{
                .{ "use_multiarraylist", false },
                .{ "use_u64", false },
                .{ "count_var_refs", false },
            } },
        }),
        &.{
            .{
                // avg depth: 2.54
                .name = "small-exprs",
                .seed = 394852010190109754,
                .n_statements = 1_000_000,
                .max_statement_depth = 4,
                .random_depths = true,
            },
            .{
                // avg depth: 12.6
                .name = "random-depths",
                .seed = 592532456724845655,
                .n_statements = 100_000,
                .max_statement_depth = 512,
                .random_depths = true,
            },
            .{
                .name = "lots-of-exprs",
                .seed = 1674846731856312,
                .n_statements = 10_000_000,
                .max_statement_depth = 3,
                .random_depths = false,
            },
            .{
                .name = "large-exprs",
                .seed = 4278276976286587,
                .n_statements = 8,
                .max_statement_depth = 26,
                .random_depths = false,
            },
        },
    );

    // var ref count benchmark
    try setupBenchmark(
        b,
        generator,
        "vars",
        try setupImplementations(b, target, optimize, bytecode, &.{
            .{ b.path("impls/oop.zig"), "oop-counter", &.{
                .{ "use_arena", false },
                .{ "count_var_refs", true },
            } },
            .{ b.path("impls/oop.zig"), "oop-arena-counter", &.{
                .{ "use_arena", true },
                .{ "count_var_refs", true },
            } },
            .{ b.path("impls/dod.zig"), "aos-counter", &.{
                .{ "use_multiarraylist", false },
                .{ "use_u64", true },
                .{ "count_var_refs", true },
            } },
            .{ b.path("impls/dod.zig"), "soa-counter", &.{
                .{ "use_multiarraylist", true },
                .{ "use_u64", true },
                .{ "count_var_refs", true },
            } },
            .{ b.path("impls/dod.zig"), "aos-compact-counter", &.{
                .{ "use_multiarraylist", false },
                .{ "use_u64", false },
                .{ "count_var_refs", true },
            } },
        }),
        &.{
            .{
                .name = "lots",
                .seed = 1674846731856312,
                .n_statements = 4_000_000,
                .max_statement_depth = 3,
                .random_depths = false,
            },
            .{
                .name = "large",
                .seed = 4278276976286587,
                .n_statements = 6,
                .max_statement_depth = 30,
                .random_depths = false,
            },
        },
    );
}

fn setupAssembler(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    bytecode: *std.Build.Module,
) *std.Build.Step.Compile {
    const assembler = b.addExecutable(.{
        .name = "assembler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bytecode/assembler.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{.{ .name = "bytecode", .module = bytecode }},
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

fn setupDisassembler(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    bytecode: *std.Build.Module,
) *std.Build.Step.Compile {
    const disassembler = b.addExecutable(.{
        .name = "disassembler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bytecode/disassembler.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{.{ .name = "bytecode", .module = bytecode }},
        }),
    });

    const disassembler_installation = b.addInstallArtifact(disassembler, .{});
    b.getInstallStep().dependOn(&disassembler_installation.step);

    const run_disassembler_step = b.step("disassemble", "Run disassembler");
    const disassembler_cmd = b.addRunArtifact(disassembler);
    run_disassembler_step.dependOn(&disassembler_cmd.step);
    disassembler_cmd.addPassthruArgs();

    return disassembler;
}

fn setupGenerator(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    bytecode: *std.Build.Module,
) *std.Build.Step.Compile {
    const generator = b.addExecutable(.{
        .name = "generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bytecode/generator.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{.{ .name = "bytecode", .module = bytecode }},
        }),
    });

    const generator_installation = b.addInstallArtifact(generator, .{});
    b.getInstallStep().dependOn(&generator_installation.step);

    const run_generator_step = b.step("generate", "Run generator");
    const generator_cmd = b.addRunArtifact(generator);
    run_generator_step.dependOn(&generator_cmd.step);
    generator_cmd.addPassthruArgs();

    return generator;
}

fn setupBenchmark(
    b: *std.Build,
    generator: *std.Build.Step.Compile,
    name: []const u8,
    impls: []const *std.Build.Step.Compile,
    patterns: []const InputPattern,
) !void {
    const metrics: []const []const u8 = &.{"time_wall_clock"};

    for (patterns) |pattern| {
        if (std.mem.findAny(u8, pattern.name, &std.ascii.whitespace) != null) {
            @panic("invalid pattern name: contains spaces");
        }

        const generator_cmd = b.addRunArtifact(generator);
        const input = generator_cmd.addOutputFileArg2(pattern.name, .{});
        generator_cmd.addArgs(&.{
            b.fmt("{d}", .{pattern.seed}),
            b.fmt("{d}", .{pattern.n_statements}),
            b.fmt("{d}", .{pattern.max_statement_depth}),
        });
        if (pattern.random_depths) {
            generator_cmd.addArg("-r");
        }

        const install_input = b.addInstallFile(input, b.pathJoin(&.{ "inputs", pattern.name }));
        b.getInstallStep().dependOn(&install_input.step);

        const bench_step = b.step(
            b.fmt("bench-{s}-{s}", .{ name, pattern.name }),
            b.fmt("Run benchmark '{s}' on input '{s}'", .{ name, pattern.name }),
        );

        const bench_cmd = b.addSystemCommand(&.{
            "hyperfine", "-N",
            "--metrics", try std.mem.join(b.allocator, ",", metrics),
        });
        bench_step.dependOn(&bench_cmd.step);
        bench_step.dependOn(&generator_cmd.step);
        bench_step.dependOn(&install_input.step);

        for (impls) |impl| {
            bench_cmd.addArgs(&.{ "-n", impl.name });
            bench_cmd.addArtifactArg2(impl, .{});
            bench_step.dependOn(&impl.step);
        }
        bench_cmd.addArg("--input");
        bench_cmd.addFileArg2(input, .{});
    }
}

fn setupImplementations(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    bytecode: *std.Build.Module,
    impls: []const struct {
        std.Build.LazyPath,
        []const u8,
        []const struct { []const u8, bool },
    },
) ![]const *std.Build.Step.Compile {
    var res: std.ArrayList(*std.Build.Step.Compile) = .empty;

    for (impls) |impl| {
        const source_file, const name, const flags = impl;

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = source_file,
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
                .imports = &.{.{ .name = "bytecode", .module = bytecode }},
            }),
        });

        const options: *std.Build.Step.Options = .create(b);
        for (flags) |flag| {
            options.addOption(bool, flag.@"0", flag.@"1");
        }
        exe.root_module.addOptions("config", options);

        const installation = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&installation.step);

        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run implementation '{s}'", .{name}));
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(&installation.step);
        run_cmd.addPassthruArgs();

        try res.append(b.allocator, exe);
    }

    return try res.toOwnedSlice(b.allocator);
}
