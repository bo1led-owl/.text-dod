const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
var in_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

const use_arena_for_expressions = true;
const use_arena_for_names = true;

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
    var name_arena: std.heap.ArenaAllocator = .init(gpa);
    defer expr_arena.deinit();
    defer name_arena.deinit();

    var program: Program = program: {
        const stdin = std.Io.File.stdin();
        var input_reader = stdin.reader(io, &in_buffer);
        var decoder: format.Decoder = .{ .reader = &input_reader.interface };
        break :program readProgram(
            gpa,
            if (use_arena_for_expressions) expr_arena.allocator() else gpa,
            if (use_arena_for_names) name_arena.allocator() else gpa,
            &decoder,
        ) catch |err| {
            std.log.err("failed to read program: {s}", .{@errorName(switch (err) {
                error.ReadFailed => input_reader.err.?,
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

fn readProgram(
    gpa: std.mem.Allocator,
    expr_allocator: std.mem.Allocator,
    name_allocator: std.mem.Allocator,
    decoder: *format.Decoder,
) error{ OutOfMemory, InvalidEnumTag, ReadFailed }!Program {
    var top_level_expressions: std.ArrayList(*Expr) = .empty;
    errdefer top_level_expressions.deinit(gpa);

    while (true) {
        const expr = readExpr(expr_allocator, name_allocator, decoder) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        try top_level_expressions.append(gpa, expr);
    }

    return .{
        .top_level_expressions = try top_level_expressions.toOwnedSlice(gpa),
    };
}

fn readExpr(
    expr_allocator: std.mem.Allocator,
    name_allocator: std.mem.Allocator,
    decoder: *format.Decoder,
) !*Expr {
    const opcode = try decoder.readOpcode();

    const res = try expr_allocator.create(Expr);
    res.* = switch (opcode) {
        .number => .{ .number = try decoder.readNumber() },
        .var_ref => var_ref: {
            const len = try decoder.readVarNameLen();
            const buf = try name_allocator.alloc(u8, len);
            try decoder.readVarName(buf);
            break :var_ref .{ .var_ref = buf };
        },
        .print => .{ .print = try readExpr(expr_allocator, name_allocator, decoder) },
        .add => .{ .add = .{
            .lhs = try readExpr(expr_allocator, name_allocator, decoder),
            .rhs = try readExpr(expr_allocator, name_allocator, decoder),
        } },
        .sub => .{ .sub = .{
            .lhs = try readExpr(expr_allocator, name_allocator, decoder),
            .rhs = try readExpr(expr_allocator, name_allocator, decoder),
        } },
        .mul => .{ .mul = .{
            .lhs = try readExpr(expr_allocator, name_allocator, decoder),
            .rhs = try readExpr(expr_allocator, name_allocator, decoder),
        } },
        .div => .{ .div = .{
            .lhs = try readExpr(expr_allocator, name_allocator, decoder),
            .rhs = try readExpr(expr_allocator, name_allocator, decoder),
        } },
        .assign => .{ .assign = .{
            .lhs = try readExpr(expr_allocator, name_allocator, decoder),
            .rhs = try readExpr(expr_allocator, name_allocator, decoder),
        } },
    };

    return res;
}

const Program = struct {
    top_level_expressions: []const *Expr,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        if (!use_arena_for_expressions and !use_arena_for_names) {
            for (self.top_level_expressions) |e| {
                e.deinit(gpa);
            }
        }

        gpa.free(self.top_level_expressions);
    }
};

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
        if (!use_arena_for_expressions) {
            defer gpa.destroy(self);
        }

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
