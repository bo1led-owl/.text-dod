const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
var in_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

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

    const input_file_name, const output_file_name = args: {
        var arg_iter = init.args.iterate();
        _ = arg_iter.next(); // skip program name

        const err_msg = "not enough arguments: expected INPUT_FILE, OUTPUT_FILE";
        const input = arg_iter.next() orelse {
            std.log.err(err_msg, .{});
            return 2;
        };
        const output = arg_iter.next() orelse {
            std.log.err(err_msg, .{});
            return 2;
        };

        break :args .{ input, output };
    };

    var expr_arena: std.heap.ArenaAllocator = .init(gpa);
    defer expr_arena.deinit();

    var name_arena: std.heap.ArenaAllocator = .init(gpa);
    defer name_arena.deinit();

    var program: Program = parse(
        io,
        gpa,
        expr_arena.allocator(),
        name_arena.allocator(),
        input_file_name,
    ) catch |err| {
        std.log.err("faile to parse: {s}", .{@errorName(err)});
        return 1;
    };
    defer program.deinit(gpa);

    const output_file = std.Io.Dir.cwd().createFile(io, output_file_name, .{}) catch |err| {
        std.log.err("failed to open output file: {s}", .{@errorName(err)});
        return 1;
    };
    defer output_file.close(io);

    var output_file_writer = output_file.writer(io, &out_buffer);
    var formatter: format.Writer = .{ .writer = &output_file_writer.interface };

    for (program.top_level_expressions) |expr| {
        formatExpr(&formatter, expr) catch {
            std.log.err("failed to format an expression: {s}", .{@errorName(output_file_writer.err.?)});
            return 1;
        };
    }

    output_file_writer.flush() catch |err| {
        std.log.err("failed to flush output: {s}", .{@errorName(err)});
        return 1;
    };

    return 0;
}

fn parse(
    io: std.Io,
    gpa: std.mem.Allocator,
    expr_allocator: std.mem.Allocator,
    name_allocator: std.mem.Allocator,
    filename: []const u8,
) !Program {
    const input_file = try std.Io.Dir.cwd().openFile(io, filename, .{ .allow_directory = false });
    defer input_file.close(io);

    var input_reader = input_file.readerStreaming(io, &in_buffer);

    var parser: Parser = .init(
        gpa,
        expr_allocator,
        name_allocator,
        &input_reader.interface,
    );
    defer parser.deinit();

    return parser.run() catch |err| switch (err) {
        error.ReadFailed => input_reader.err.?,
        else => err,
    };
}

fn formatExpr(formatter: *format.Writer, expr: *const Expr) !void {
    try formatter.writeOpcode(expr.*);

    switch (expr.*) {
        .number => |n| try formatter.writeNumber(n),
        .var_ref => |s| try formatter.writeVarName(s),
        .print => |e| try formatExpr(formatter, e),
        .add, .sub, .mul, .div, .assign => |bin| {
            try formatExpr(formatter, bin.lhs);
            try formatExpr(formatter, bin.rhs);
        },
    }
}

const Expr = union(format.Opcode) {
    number: u64,
    var_ref: []const u8,

    print: *Expr,

    add: Binary,
    sub: Binary,
    mul: Binary,
    div: Binary,
    assign: Binary,

    pub const Binary = struct { lhs: *Expr, rhs: *Expr };
};

const Program = struct {
    top_level_expressions: []const *Expr,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
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
