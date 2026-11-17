const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("bytecode");
const config = @import("config");

const ArenaAllocator = @import("ArenaAllocator.zig");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
var in_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

pub fn main() u8 {
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

    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var program: Program = program: {
        const stdin = std.Io.File.stdin();
        var input_reader = stdin.reader(io, &in_buffer);
        const decoder: bytecode.Decoder = .{ .reader = &input_reader.interface };
        break :program readProgram(
            gpa,
            if (config.use_arena) arena.allocator() else gpa,
            if (config.use_arena) arena.allocator() else gpa,
            decoder,
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

    if (config.count_var_refs) {
        var count: u32 = 0;
        for (program.top_level_expressions) |expr| {
            count += countVarRefs(expr);
        }
        stdout_writer.interface.print("{d} variable references\n", .{count}) catch return 1;
    } else {
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
    }

    return 0;
}

fn countVarRefs(e: *const Expr) u32 {
    return switch (e.kind) {
        .number => 0,
        .var_ref => 1,
        .print => countVarRefs(e.data.operand),
        .add,
        .sub,
        .mul,
        .div,
        .assign,
        => countVarRefs(e.data.binary.lhs) + countVarRefs(e.data.binary.rhs),
    };
}

fn readProgram(
    gpa: std.mem.Allocator,
    expr_allocator: std.mem.Allocator,
    name_allocator: std.mem.Allocator,
    decoder: bytecode.Decoder,
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
    decoder: bytecode.Decoder,
) !*Expr {
    const opcode = try decoder.readOpcode();

    const res = try expr_allocator.create(Expr);
    res.kind = opcode;
    res.data = switch (opcode) {
        .number => .{ .number = try decoder.readNumber() },
        .var_ref => var_ref: {
            const len = try decoder.readVarNameLen();
            const buf = try name_allocator.alloc(u8, len);
            try decoder.readVarName(buf);
            break :var_ref .{ .var_ref = buf };
        },
        .print => .{ .operand = try readExpr(expr_allocator, name_allocator, decoder) },
        .add, .sub, .mul, .div, .assign => .{ .binary = .{
            .lhs = try readExpr(expr_allocator, name_allocator, decoder),
            .rhs = try readExpr(expr_allocator, name_allocator, decoder),
        } },
    };

    return res;
}

const Program = struct {
    top_level_expressions: []const *Expr,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        if (!config.use_arena) {
            for (self.top_level_expressions) |e| {
                e.deinit(gpa);
            }
        }

        gpa.free(self.top_level_expressions);
    }
};

const Expr = struct {
    kind: bytecode.Opcode,
    data: Data,

    const Data = union {
        number: u64,
        var_ref: []const u8,
        operand: *Expr,
        binary: Binary,
    };

    pub const Binary = struct { lhs: *Expr, rhs: *Expr };

    pub fn deinit(self: *Expr, gpa: std.mem.Allocator) void {
        if (config.use_arena) {
            return;
        }

        defer self.* = undefined;
        defer gpa.destroy(self);

        switch (self.kind) {
            .print => self.data.operand.deinit(gpa),
            .add, .sub, .mul, .div, .assign => {
                self.data.binary.lhs.deinit(gpa);
                self.data.binary.rhs.deinit(gpa);
            },
            .var_ref => gpa.free(self.data.var_ref),
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
        switch (expr.kind) {
            .assign => {
                const data = expr.data.binary;
                switch (data.lhs.kind) {
                    .var_ref => {
                        const value = try self.executeExpr(data.rhs);
                        try self.variables.put(self.gpa, data.lhs.data.var_ref, value);
                        return value;
                    },
                    else => return error.ExpressionIsNotAssignable,
                }
            },
            .number => return expr.data.number,
            .var_ref => return self.variables.get(expr.data.var_ref) orelse error.UndefinedVariable,
            .print => {
                const value = try self.executeExpr(expr.data.operand);
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
