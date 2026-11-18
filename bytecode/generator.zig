const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("bytecode");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

pub const help_msg =
    \\Usage: generator [options...] <outfile> <seed> <n_statements> <max_statement_depth>
    \\
    \\Options:
    \\  -h, --help             Print this message and exit
    \\  -r, --random-depth     Generate expression depths randomly
++ "\n";

pub fn main(init: std.process.Init.Minimal) u8 {
    var allocator = switch (builtin.optimize) {
        .debug => std.heap.DebugAllocator(.{}){},
        .safe => std.heap.SafeAllocator.init(std.heap.page_allocator, .{}),
        else => struct {
            pub fn allocator(_: @This()) std.mem.Allocator {
                return if (builtin.single_threaded) std.heap.brk_allocator else std.heap.smp_allocator;
            }
            pub fn deinit(_: @This()) void {}
        }{},
    };

    const gpa = allocator.allocator();
    defer _ = allocator.deinit();

    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const args = Args.parse(init.args) catch |err| {
        std.log.err("failed to parse arguments: {s}", .{@errorName(err)});
        return 2;
    };

    switch (args) {
        .help => {
            std.Io.File.stdout().writeStreamingAll(io, help_msg) catch return 1;
            return 0;
        },
        .full => |full_args| return mainArgs(io, gpa, full_args),
    }
}

fn mainArgs(io: std.Io, gpa: std.mem.Allocator, args: Args.Full) u8 {
    var outfile = std.Io.Dir.cwd().createFile(io, args.output_path, .{}) catch |err| {
        std.log.err("failed to open output file: {s}", .{@errorName(err)});
        return 1;
    };
    defer outfile.close(io);

    var outfile_writer = outfile.writerStreaming(io, &out_buffer);
    const encoder: bytecode.Encoder = .{ .writer = &outfile_writer.interface };

    const avg_depth = generate(gpa, encoder, args) catch |err| {
        const err_msg = switch (err) {
            error.WriteFailed => @errorName(outfile_writer.err.?),
            else => |e| @errorName(e),
        };
        std.log.err("failed to generate: {s}", .{err_msg});
        return 1;
    };

    outfile_writer.flush() catch {
        std.log.err("failed to flush: {s}", .{@errorName(outfile_writer.err.?)});
        return 1;
    };

    if (args.random_depths) {
        var w = std.Io.File.stdout().writerStreaming(io, &.{});
        w.interface.print("avg depth: {d}\n", .{avg_depth}) catch return 1;
        w.flush() catch return 1;
    }

    return 0;
}

pub fn generate(gpa: std.mem.Allocator, encoder: bytecode.Encoder, args: Args.Full) !f32 {
    var prng = std.Random.DefaultPrng.init(args.seed);

    var generator: Generator = .{
        .gpa = gpa,
        .encoder = encoder,
        .rng = prng.random(),
        .random_depths = args.random_depths,
    };
    defer generator.deinit();
    return try generator.run(args.max_statement_depth, args.n_statements);
}

const Generator = struct {
    gpa: std.mem.Allocator,
    encoder: bytecode.Encoder,
    rng: std.Random,
    random_depths: bool,
    defined_vars: std.ArrayList(u64) = .empty,
    n_names: u64 = 0,

    pub fn deinit(g: *Generator) void {
        defer g.* = undefined;
        g.defined_vars.deinit(g.gpa);
    }

    pub fn run(g: *Generator, max_depth: u16, n: u32) !f32 {
        var depths_sum: u64 = 0;
        for (0..n) |_| {
            depths_sum += try g.genExpr(max_depth);
        }

        const avg_depth = @as(f32, @floatFromInt(depths_sum)) / @as(f32, @floatFromInt(n));
        return avg_depth;
    }

    fn nextVar(g: *Generator) u64 {
        defer g.n_names += 1;
        return g.n_names;
    }

    fn pickVar(g: *Generator) ?u64 {
        if (g.defined_vars.items.len == 0) {
            return null;
        }

        const i = g.rng.uintLessThan(usize, @intCast(g.defined_vars.items.len));
        return g.defined_vars.items[i];
    }

    fn writeName(g: *Generator, name: u64) !void {
        try g.encoder.writeVarName(name);
    }

    fn nextDepth(g: Generator, depth: u16) u16 {
        if (g.random_depths) {
            return g.rng.uintLessThan(u16, depth);
        } else {
            return depth - 1;
        }
    }

    fn genExpr(g: *Generator, depth: u16) !u16 {
        if (depth == 0) {
            try g.genLeaf();
            return 0;
        }

        const opcodes = [_]bytecode.Opcode{ .add, .sub, .mul, .div, .assign, .print };
        const opcode = opcodes[g.rng.uintLessThan(u3, 6)];
        try g.encoder.writeOpcode(opcode);
        switch (opcode) {
            .add, .sub, .mul, .div => {
                const lhs_depth = try g.genExpr(g.nextDepth(depth));
                const rhs_depth = try g.genExpr(g.nextDepth(depth));
                return @max(lhs_depth, rhs_depth) + 1;
            },
            .assign => {
                const name, const is_new =
                    if (g.defined_vars.items.len > 0 and g.rng.boolean())
                        .{ g.pickVar().?, false }
                    else
                        .{ g.nextVar(), true };

                try g.encoder.writeOpcode(.var_ref);
                try g.writeName(name);
                const src_depth = try g.genExpr(g.nextDepth(depth));

                if (is_new) {
                    try g.defined_vars.append(g.gpa, name);
                }

                return src_depth + 1;
            },
            .print => return (try g.genExpr(g.nextDepth(depth))) + 1,
            else => unreachable,
        }
    }

    fn genLeaf(g: *Generator) !void {
        if (g.defined_vars.items.len > 0 and g.rng.boolean()) {
            try g.encoder.writeOpcode(.var_ref);
            try g.writeName(g.pickVar().?);
        } else {
            try g.encoder.writeOpcode(.number);
            try g.encoder.writeNumber(g.rng.uintAtMost(u64, std.math.maxInt(u64)));
        }
    }
};

pub const Args = union(enum) {
    pub const ParseError = error{
        TooFewArguments,
        TooManyArguments,
        UnknownOption,
        MissingOptionValue,
        InvalidOptionValue,
    };

    pub const Full = struct {
        output_path: []const u8,
        seed: u64,
        n_statements: u32,
        max_statement_depth: u16,
        random_depths: bool,
    };

    help,
    full: Full,

    pub fn parse(args: std.process.Args) ParseError!Args {
        const Next = enum(u8) {
            output_path = 0,
            seed = 1,
            n_statements = 2,
            max_statement_depth = 3,
            none = 4,
        };

        var next: Next = @fromBackingInt(0);

        var seed: u64 = undefined;
        var n_statements: u32 = undefined;
        var max_statement_depth: u16 = undefined;
        var random_depths = false;
        var output_path: []const u8 = undefined;

        var iter = args.iterate();
        _ = iter.next(); // skip program name

        while (iter.next()) |arg| {
            if (flag(arg, 'h', "help")) {
                return .help;
            } else if (flag(arg, 'r', "random")) {
                random_depths = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return ParseError.UnknownOption;
            } else {
                switch (next) {
                    .output_path => output_path = arg,
                    .seed => seed = std.fmt.parseUnsigned(u64, arg, 10) catch
                        return ParseError.InvalidOptionValue,
                    .n_statements => n_statements = std.fmt.parseUnsigned(u32, arg, 10) catch
                        return ParseError.InvalidOptionValue,
                    .max_statement_depth => max_statement_depth = std.fmt.parseUnsigned(u16, arg, 10) catch
                        return ParseError.InvalidOptionValue,
                    .none => return ParseError.TooManyArguments,
                }
                next = @fromBackingInt(@backingInt(next) + 1);
            }
        }

        if (next != .none) {
            return ParseError.TooFewArguments;
        }

        return .{ .full = .{
            .output_path = output_path,
            .seed = seed,
            .n_statements = n_statements,
            .max_statement_depth = max_statement_depth,
            .random_depths = random_depths,
        } };
    }

    fn flag(arg: [:0]const u8, comptime short: ?u8, comptime long: ?[]const u8) bool {
        if (short) |s| {
            if (std.mem.eql(u8, arg, std.fmt.comptimePrint("-{c}", .{s}))) {
                return true;
            }
        }

        if (long) |l| {
            if (std.mem.eql(u8, arg, "--" ++ l)) {
                return true;
            }
        }

        return false;
    }
};
