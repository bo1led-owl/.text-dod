const std = @import("std");
const builtin = @import("builtin");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
var in_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

const use_arena_for_expressions = false;
const use_arena_for_names = false;

const use_safe_allocator = builtin.mode == .debug or builtin.mode == .safe;
var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});

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

    var expr_arena: std.heap.ArenaAllocator = .init(gpa);
    defer expr_arena.deinit();

    var name_arena: std.heap.ArenaAllocator = .init(gpa);
    defer name_arena.deinit();

    var program: Program = parse: {
        const input_file = std.Io.Dir.cwd().openFile(io, "input", .{ .allow_directory = false }) catch |err| {
            std.log.err("failed to open input file: {s}", .{@errorName(err)});
            return 1;
        };
        defer input_file.close(io);

        var input_reader = input_file.readerStreaming(io, &in_buffer);

        var parser: Parser = .init(
            gpa,
            if (use_arena_for_expressions) expr_arena.allocator() else gpa,
            if (use_arena_for_names) name_arena.allocator() else gpa,
            &input_reader.interface,
        );
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

    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writerStreaming(io, &out_buffer);
    defer stdout_writer.flush() catch {};

    var executor: Executor = .init(gpa, &stdout_writer.interface);
    defer executor.deinit();

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

    return 0;
}

const Expr = union(enum) {
    number: u64,
    var_ref: []const u8,

    print: *Expr,

    add: Binary,
    sub: Binary,
    mul: Binary,
    div: Binary,
    assign: Binary,

    pub const Binary = struct { lhs: *Expr, rhs: *Expr };

    pub fn deinit(self: *Expr, gpa: std.mem.Allocator) void {
        defer self.* = undefined;
        defer gpa.destroy(self);

        switch (self.*) {
            .print => |op| op.deinit(gpa),
            .add, .sub, .mul, .div, .assign => |bin| {
                bin.lhs.deinit(gpa);
                bin.rhs.deinit(gpa);
            },
            .var_ref => |s| if (!use_arena_for_names) gpa.free(s),
            .number => {},
        }
    }
};

const Program = struct {
    top_level_expressions: []const *Expr,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        if (!use_arena_for_expressions) {
            for (self.top_level_expressions) |e| {
                e.deinit(gpa);
            }
        }

        gpa.free(self.top_level_expressions);
    }
};

const Parser = struct {
    gpa: std.mem.Allocator,
    expr_allocator: std.mem.Allocator,
    name_allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    line_writer: std.Io.Writer.Allocating,

    const Error = error{
        NoWhitespace,
        NumberTooLarge,
        InvalidCharacter,
        IncompleteExpression,
        UnterminatedExpression,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        expr_allocator: std.mem.Allocator,
        name_allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) Parser {
        return .{
            .gpa = gpa,
            .expr_allocator = expr_allocator,
            .name_allocator = name_allocator,
            .reader = reader,
            .line_writer = .init(gpa),
        };
    }

    pub fn deinit(self: *Parser) void {
        defer self.* = undefined;
        self.line_writer.deinit();
    }

    pub fn run(self: *Parser) (error{ OutOfMemory, ReadFailed } || Error)!Program {
        var res: std.ArrayList(*Expr) = .empty;

        while (try self.parseExpr()) |expr| {
            try res.append(self.gpa, expr);
        }

        return .{ .top_level_expressions = try res.toOwnedSlice(self.gpa) };
    }

    fn parseExpr(self: *Parser) (error{ OutOfMemory, ReadFailed } || Error)!?*Expr {
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
        errdefer if (res) |e| e.deinit(self.gpa);

        while (cursor.next()) |item| {
            if (item.len != 0) {
                return error.IncompleteExpression;
            }
        }
        return res;
    }

    fn createExpr(self: *Parser, value: Expr) !*Expr {
        const res = try self.expr_allocator.create(Expr);
        res.* = value;
        return res;
    }

    fn parseExprInternal(self: *Parser, cursor: *std.mem.SplitIterator(u8, .any)) !?*Expr {
        while (cursor.next()) |item| {
            if (item.len == 0) {
                continue;
            }

            switch (item[0]) {
                '=', '+', '-', '*', '/' => |c| if (item.len == 1) {
                    const data: Expr.Binary = .{
                        .lhs = (try self.parseExprInternal(cursor)) orelse return error.IncompleteExpression,
                        .rhs = (try self.parseExprInternal(cursor)) orelse return error.IncompleteExpression,
                    };

                    return self.createExpr(switch (c) {
                        '=' => .{ .assign = data },
                        '+' => .{ .add = data },
                        '-' => .{ .sub = data },
                        '*' => .{ .mul = data },
                        '/' => .{ .div = data },
                        else => unreachable,
                    });
                } else {
                    return error.NoWhitespace;
                },
                else => |first_char| if (std.mem.eql(u8, item, "print")) {
                    const operand = (try self.parseExprInternal(cursor)) orelse return error.IncompleteExpression;
                    return self.createExpr(.{ .print = operand });
                } else if (std.ascii.isDigit(first_char)) {
                    const value = std.fmt.parseUnsigned(u64, item, 10) catch |err| switch (err) {
                        error.Overflow => return error.NumberTooLarge,
                        error.InvalidCharacter => return error.NoWhitespace,
                    };

                    return self.createExpr(.{ .number = value });
                } else if (first_char == '_' or std.ascii.isAlphabetic(first_char)) {
                    const cloned_name = try self.name_allocator.alloc(u8, item.len);
                    @memcpy(cloned_name, item);
                    return self.createExpr(.{ .var_ref = cloned_name });
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
    variables: std.StringHashMapUnmanaged(u64),

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) Executor {
        return .{
            .gpa = gpa,
            .writer = writer,
            .variables = .empty,
        };
    }

    pub fn deinit(self: *Executor) void {
        defer self.* = undefined;
        self.variables.deinit(self.gpa);
    }

    pub fn executeExpr(self: *Executor, expr: *const Expr) !u64 {
        switch (expr.*) {
            .assign => |data| {
                switch (data.lhs.*) {
                    .var_ref => |name| {
                        const value = try self.executeExpr(data.rhs);
                        try self.variables.put(self.gpa, name, value);
                        return value;
                    },
                    else => return error.ExpressionIsNotAssignable,
                }
            },
            .number => |value| return value,
            .var_ref => |name| return self.variables.get(name) orelse error.UndefinedVariable,
            .print => |operand| {
                const value = try self.executeExpr(operand);
                try self.writer.print("{d}\n", .{value});
                return value;
            },
            .add, .sub, .mul, .div => |data| {
                const lhs = try self.executeExpr(data.lhs);
                const rhs = try self.executeExpr(data.rhs);

                return switch (expr.*) {
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
