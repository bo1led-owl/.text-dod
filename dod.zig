const std = @import("std");
const builtin = @import("builtin");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
var in_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

const use_safe_allocator = builtin.mode == .debug or builtin.mode == .safe;
var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});

fn printElapsed(comptime title: []const u8, from: std.Io.Timestamp, to: std.Io.Timestamp) void {
    var fmt_buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&fmt_buffer);

    const duration = from.durationTo(to);
    duration.format(&writer) catch return;

    std.log.info(title ++ "\t{s}", .{writer.buffered()});
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };

    var io_impl = std.Io.Threaded.init(gpa, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer io_impl.deinit();

    const io = io_impl.io();

    const clock: std.Io.Clock = .real;
    const parsing_start = clock.now(io);

    var program: Program = parse: {
        const input_file = std.Io.Dir.cwd().openFile(io, "input", .{ .allow_directory = false }) catch |err| {
            std.log.err("failed to open input file: {s}", .{@errorName(err)});
            return 1;
        };
        defer input_file.close(io);

        var input_reader = input_file.readerStreaming(io, &in_buffer);

        var parser: Parser = .init(gpa, &input_reader.interface);
        defer parser.deinit();

        break :parse parser.run() catch |err| {
            std.log.err("failed to parse statement: {s}", .{@errorName(switch (err) {
                error.OutOfMemory, error.ReadFailed => if (err == error.ReadFailed) input_reader.err.? else err,
                else => err,
            })});
            return 1;
        };
    };
    defer program.deinit(gpa);
    printElapsed("parsing", parsing_start, clock.now(io));

    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writerStreaming(io, &out_buffer);
    defer stdout_writer.flush() catch {};

    var executor: Executor = .init(gpa, program, &stdout_writer.interface);
    defer executor.deinit();

    const execution_start = clock.now(io);
    for (program.top_level_expressions) |expr| {
        _ = executor.executeExpr(expr) catch |err| {
            std.log.err(
                "failed to execute statement: {s}",
                .{@errorName(switch (err) {
                    error.WriteFailed => stdout_writer.err.?,
                    else => err,
                })},
            );
            return 1;
        };
    }
    printElapsed("execution", execution_start, clock.now(io));

    return 0;
}

const Expr = struct {
    kind: Kind,
    data: Data,

    pub const Index = enum(u32) {
        _,

        pub fn toU32(self: Index) u32 {
            return @backingInt(self);
        }
    };

    pub const Kind = enum(u8) {
        number,
        var_ref,
        print,
        add,
        sub,
        mul,
        div,
        assign,
    };

    pub const Name = struct { begin: u32, len: u32 };
    pub const Binary = struct { lhs: Expr.Index, rhs: Expr.Index };

    pub const Data = union(enum) {
        number: u64,
        name: Name,
        unary: Expr.Index,
        binary: Binary,
    };
};

const Program = struct {
    names: []const u8,
    top_level_expressions: []const Expr.Index,
    expression_storage: std.MultiArrayList(Expr).Slice,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        gpa.free(self.names);
        gpa.free(self.top_level_expressions);
        self.expression_storage.deinit(gpa);
    }
};

const Parser = struct {
    gpa: std.mem.Allocator,
    name_arena: std.ArrayList(u8),
    expr_storage: std.MultiArrayList(Expr),
    reader: *std.Io.Reader,
    line_writer: std.Io.Writer.Allocating,

    pub const Error = error{
        NoWhitespace,
        NumberTooLarge,
        InvalidCharacter,
        IncompleteExpression,
        UnterminatedExpression,
    };

    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader) Parser {
        return .{
            .gpa = gpa,
            .name_arena = .empty,
            .expr_storage = .empty,
            .reader = reader,
            .line_writer = .init(gpa),
        };
    }

    pub fn deinit(self: *Parser) void {
        defer self.* = undefined;
        self.line_writer.deinit();
    }

    pub fn run(self: *Parser) (error{ OutOfMemory, ReadFailed } || Error)!Program {
        var top_level_expressions: std.ArrayList(Expr.Index) = .empty;
        while (true) {
            const parsed = try self.parseExpr() orelse break;
            try top_level_expressions.append(self.gpa, parsed);
        }

        return .{
            .names = try self.name_arena.toOwnedSlice(self.gpa),
            .top_level_expressions = try top_level_expressions.toOwnedSlice(self.gpa),
            .expression_storage = self.expr_storage.toOwnedSlice(),
        };
    }

    fn parseExpr(self: *Parser) (error{ OutOfMemory, ReadFailed } || Error)!?Expr.Index {
        self.line_writer.clearRetainingCapacity();

        _ = self.reader.streamDelimiter(&self.line_writer.writer, ';') catch |err|
            switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.EndOfStream => if (std.mem.findNone(u8, self.line_writer.written(), &std.ascii.whitespace) != null)
                    return error.UnterminatedExpression
                else
                    return null,
                else => |e| return e,
            };

        // discard ';'
        _ = self.reader.discard(.limited(1)) catch |err| switch (err) {
            error.EndOfStream => unreachable,
            else => |e| return e,
        };

        const input = self.line_writer.written();
        var cursor = std.mem.splitAny(u8, input, &std.ascii.whitespace);

        const res = try self.parseExprInternal(&cursor);

        while (cursor.next()) |item| {
            if (item.len != 0) {
                return error.IncompleteExpression;
            }
        }
        return res;
    }

    fn createExpr(self: *Parser, value: Expr) !Expr.Index {
        const res: Expr.Index = @fromBackingInt(@intCast(self.expr_storage.len));
        try self.expr_storage.append(self.gpa, value);
        return res;
    }

    fn parseExprInternal(self: *Parser, cursor: *std.mem.SplitIterator(u8, .any)) !?Expr.Index {
        while (cursor.next()) |item| {
            if (item.len == 0) {
                continue;
            }

            switch (item[0]) {
                '=', '+', '-', '*', '/' => |c| if (item.len == 1) {
                    const lhs = (try self.parseExprInternal(cursor)) orelse
                        return error.IncompleteExpression;
                    const rhs = (try self.parseExprInternal(cursor)) orelse
                        return error.IncompleteExpression;

                    return try self.createExpr(.{
                        .kind = switch (c) {
                            '=' => .assign,
                            '+' => .add,
                            '-' => .sub,
                            '*' => .mul,
                            '/' => .div,
                            else => unreachable,
                        },
                        .data = .{ .binary = .{ .lhs = lhs, .rhs = rhs } },
                    });
                } else {
                    return error.NoWhitespace;
                },
                else => |first_char| if (std.mem.eql(u8, item, "print")) {
                    const operand = (try self.parseExprInternal(cursor)) orelse
                        return error.IncompleteExpression;
                    return try self.createExpr(.{ .kind = .print, .data = .{ .unary = operand } });
                } else if (std.ascii.isDigit(first_char)) {
                    const value = std.fmt.parseUnsigned(u64, item, 10) catch |err| switch (err) {
                        error.Overflow => return error.NumberTooLarge,
                        error.InvalidCharacter => return error.NoWhitespace,
                    };
                    return try self.createExpr(.{ .kind = .number, .data = .{ .number = value } });
                } else if (first_char == '_' or std.ascii.isAlphabetic(first_char)) {
                    const begin: u32 = @intCast(self.name_arena.items.len);
                    try self.name_arena.appendSlice(self.gpa, item);
                    return try self.createExpr(.{
                        .kind = .var_ref,
                        .data = .{ .name = .{ .begin = begin, .len = @intCast(item.len) } },
                    });
                } else {
                    return error.InvalidCharacter;
                },
            }
        }

        return null;
    }
};

pub const Executor = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    expressions: std.MultiArrayList(Expr).Slice,
    variables: std.HashMapUnmanaged(Expr.Name, u64, Context, std.hash_map.default_max_load_percentage),
    map_ctx: Context,

    const Context = struct {
        name_arena: []const u8,

        fn extractName(self: Context, begin: u32, len: u32) []const u8 {
            return self.name_arena[begin..][0..len];
        }

        pub fn hash(self: Context, name: Expr.Name) u64 {
            const str = self.extractName(name.begin, name.len);
            return std.hash.Wyhash.hash(0, str);
        }
        pub fn eql(self: Context, a: Expr.Name, b: Expr.Name) bool {
            const str_a = self.extractName(a.begin, a.len);
            const str_b = self.extractName(b.begin, b.len);
            return std.mem.eql(u8, str_a, str_b);
        }
    };

    pub fn init(
        gpa: std.mem.Allocator,
        program: Program,
        writer: *std.Io.Writer,
    ) Executor {
        return .{
            .gpa = gpa,
            .writer = writer,
            .expressions = program.expression_storage,
            .variables = .empty,
            .map_ctx = .{ .name_arena = program.names },
        };
    }

    pub fn deinit(self: *Executor) void {
        defer self.* = undefined;
        self.variables.deinit(self.gpa);
    }

    pub fn executeExpr(self: *Executor, expr_index: Expr.Index) !u64 {
        const expr = self.expressions.get(expr_index.toU32());
        switch (expr.kind) {
            .assign => {
                const data = expr.data.binary;
                const lhs = self.expressions.get(data.lhs.toU32());

                switch (lhs.kind) {
                    .var_ref => {
                        const value = try self.executeExpr(data.rhs);
                        try self.variables.putContext(self.gpa, lhs.data.name, value, self.map_ctx);
                        return value;
                    },
                    else => return error.ExpressionIsNotAssignable,
                }
            },
            .number => return expr.data.number,
            .var_ref => return self.variables.getContext(expr.data.name, self.map_ctx) orelse error.UndefinedVariable,
            .print => {
                const value = try self.executeExpr(expr.data.unary);
                try self.writer.print("{d}\n", .{value});
                return value;
            },
            .add, .sub, .mul, .div => {
                const data = expr.data.binary;
                const lhs = try self.executeExpr(data.lhs);
                const rhs = try self.executeExpr(data.rhs);

                return switch (expr.kind) {
                    .add => @addWithOverflow(lhs, rhs).@"0",
                    .sub => @subWithOverflow(lhs, rhs).@"0",
                    .mul => @mulWithOverflow(lhs, rhs).@"0",
                    .div => if (rhs != 0) lhs / rhs else std.math.maxInt(u64),
                    else => unreachable,
                };
            },
        }
    }
};
