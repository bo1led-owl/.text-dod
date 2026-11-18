const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("bytecode");
const config = @import("config");

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

    var last_var: u64 = 0;
    var program: Program = program: {
        const stdin = std.Io.File.stdin();
        var input_reader = stdin.reader(io, &in_buffer);
        const decoder: bytecode.Decoder = .{ .reader = &input_reader.interface };
        break :program readProgram(gpa, decoder, &last_var) catch |err| {
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

    if (config.preprocessor) {
        dumpProgram(&stdout_writer.interface, program, last_var) catch |err| {
            const err_msg = switch (err) {
                error.WriteFailed => @errorName(stdout_writer.err.?),
            };
            std.log.err("failed to dump: {s}", .{err_msg});
            return 1;
        };
    } else if (config.count_var_refs) {
        var count: u64 = 0;

        if (!config.use_multiarraylist) {
            for (program.expression_storage) |expr| {
                count += @intFromBool(expr.kind == .var_ref);
            }
        } else {
            const OpcodeRepr = @typeInfo(bytecode.Opcode).@"enum".tag_type;
            const kinds: []const OpcodeRepr = @ptrCast(program.expression_storage.items(.kind));
            const var_ref_repr: OpcodeRepr = @backingInt(bytecode.Opcode.var_ref);

            var i: u32 = 0;

            if (std.simd.suggestVectorLength(OpcodeRepr)) |vector_length| {
                const V = @Vector(vector_length, OpcodeRepr);
                const splat_var_ref: V = @splat(var_ref_repr);

                while (i + vector_length <= kinds.len) : (i += vector_length) {
                    const lane: V = kinds[i..][0..vector_length].*;
                    count += std.simd.countTrues(lane == splat_var_ref);
                }
            }

            while (i < kinds.len) : (i += 1) {
                count += @intFromBool(kinds[i] == var_ref_repr);
            }
        }

        stdout_writer.interface.print("{d} variable references\n", .{count}) catch return 1;
    } else {
        const var_buffer: []u64 = gpa.alloc(u64, last_var + 1) catch {
            std.log.err("failed to allocate variable storage: out of memory", .{});
            return 1;
        };
        defer gpa.free(var_buffer);

        var executor: Executor = .init(program, &stdout_writer.interface, var_buffer);
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

const ExprContainer = if (config.use_multiarraylist) std.MultiArrayList(Expr) else std.ArrayList(Expr);
const ExprSlice = if (config.use_multiarraylist) std.MultiArrayList(Expr).Slice else []Expr;

fn dumpProgram(writer: *std.Io.Writer, program: Program, last_var: u64) !void {
    if (config.use_multiarraylist) {
        var parts = [_][]const u8{
            std.mem.asBytes(&last_var),
            std.mem.asBytes(&program.top_level_expressions.len),
            std.mem.asBytes(&program.expression_storage.len),
            std.mem.sliceAsBytes(program.top_level_expressions),
            std.mem.sliceAsBytes(program.expression_storage.items(.kind)),
            std.mem.sliceAsBytes(program.expression_storage.items(.data)),
        };

        try writer.writeVecAll(&parts);
    } else {
        var parts = [_][]const u8{
            std.mem.asBytes(&last_var),
            std.mem.asBytes(&program.top_level_expressions.len),
            std.mem.asBytes(&program.expression_storage.len),
            std.mem.sliceAsBytes(program.top_level_expressions),
            std.mem.sliceAsBytes(program.expression_storage),
        };

        try writer.writeVecAll(&parts);
    }
}

fn readProgram(gpa: std.mem.Allocator, decoder: bytecode.Decoder, last_var: *u64) !Program {
    if (config.preprocessed) {
        const reader = decoder.reader;

        var top_level_expressions_len: usize = undefined;
        var expression_storage_len: usize = undefined;
        var header = [_][]u8{
            std.mem.asBytes(last_var),
            std.mem.asBytes(&top_level_expressions_len),
            std.mem.asBytes(&expression_storage_len),
        };
        try reader.readVecAll(&header);

        const top_level_expressions = try gpa.alloc(u32, top_level_expressions_len);
        errdefer gpa.free(top_level_expressions);

        var expression_storage = if (config.use_multiarraylist) multi: {
            var list = try ExprContainer.initCapacity(gpa, expression_storage_len);
            list.len = expression_storage_len;
            break :multi list.toOwnedSlice();
        } else try gpa.alloc(Expr, expression_storage_len);
        errdefer if (config.use_multiarraylist) expression_storage.deinit(gpa) else gpa.free(expression_storage);

        if (config.use_multiarraylist and !config.count_var_refs) {
            var parts = [_][]u8{
                std.mem.sliceAsBytes(top_level_expressions),
                std.mem.sliceAsBytes(expression_storage.items(.kind)),
                std.mem.sliceAsBytes(expression_storage.items(.data)),
            };
            try reader.readVecAll(&parts);
        } else if (config.use_multiarraylist and config.count_var_refs) {
            var parts = [_][]u8{
                std.mem.sliceAsBytes(top_level_expressions),
                std.mem.sliceAsBytes(expression_storage.items(.kind)),
            };
            try reader.readVecAll(&parts);
        } else {
            var parts = [_][]u8{
                std.mem.sliceAsBytes(top_level_expressions),
                std.mem.sliceAsBytes(expression_storage),
            };
            try reader.readVecAll(&parts);
        }

        return .{
            .top_level_expressions = @ptrCast(top_level_expressions),
            .expression_storage = expression_storage,
        };
    } else {
        var top_level_expressions: std.ArrayList(Expr.Index) = .empty;
        var expression_storage: ExprContainer = .empty;

        errdefer top_level_expressions.deinit(gpa);
        errdefer expression_storage.deinit(gpa);

        while (true) {
            const expr = readExpr(
                gpa,
                &expression_storage,
                decoder,
                last_var,
            ) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };

            try top_level_expressions.append(gpa, expr);
        }

        return .{
            .top_level_expressions = try top_level_expressions.toOwnedSlice(gpa),
            .expression_storage = if (config.use_multiarraylist)
                expression_storage.toOwnedSlice()
            else
                try expression_storage.toOwnedSlice(gpa),
        };
    }
}

fn readExpr(
    gpa: std.mem.Allocator,
    expression_storage: *ExprContainer,
    decoder: bytecode.Decoder,
    last_var: *u64,
) !Expr.Index {
    const opcode = try decoder.readOpcode();
    const data: Expr.Data = switch (opcode) {
        .number => .{ .number = num: {
            const num64 = try decoder.readNumber();
            break :num if (config.use_u64)
                num64
            else
                [2]u32{ @truncate(num64), @truncate(num64 >> 32) };
        } },
        .var_ref => var_ref: {
            const name = try decoder.readVarName();
            last_var.* = @max(last_var.*, name);
            break :var_ref .{ .var_ref = if (config.use_u64)
                name
            else
                [2]u32{ @truncate(name), @truncate(name >> 32) } };
        },
        .print => .{ .unary = try readExpr(gpa, expression_storage, decoder, last_var) },
        .add, .sub, .mul, .div, .assign => .{ .binary = .{
            .lhs = try readExpr(gpa, expression_storage, decoder, last_var),
            .rhs = try readExpr(gpa, expression_storage, decoder, last_var),
        } },
    };

    const res = if (config.use_multiarraylist) expression_storage.len else expression_storage.items.len;
    try expression_storage.append(gpa, .{ .kind = opcode, .data = data });
    return @fromBackingInt(@intCast(res));
}

const Program = struct {
    top_level_expressions: []const Expr.Index,
    expression_storage: ExprSlice,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        gpa.free(self.top_level_expressions);

        if (config.use_multiarraylist) {
            self.expression_storage.deinit(gpa);
        } else {
            gpa.free(self.expression_storage);
        }
    }
};

const Expr = struct {
    kind: bytecode.Opcode,
    data: Data,

    pub const Data = union(enum) {
        number: if (config.use_u64) u64 else [2]u32,
        var_ref: if (config.use_u64) u64 else [2]u32,
        unary: Expr.Index,
        binary: Binary,
    };

    pub const Index = enum(u32) {
        _,

        pub fn toU32(self: Index) u32 {
            return @backingInt(self);
        }
    };

    pub const Binary = struct { lhs: Expr.Index, rhs: Expr.Index };
};

pub const Executor = struct {
    writer: *std.Io.Writer,
    expressions: ExprSlice,
    variables: []u64,

    pub fn init(
        program: Program,
        writer: *std.Io.Writer,
        var_buffer: []u64,
    ) Executor {
        return .{
            .writer = writer,
            .expressions = program.expression_storage,
            .variables = var_buffer,
        };
    }

    pub fn executeExpr(self: *Executor, expr_index: Expr.Index) !u64 {
        const expr = if (config.use_multiarraylist)
            self.expressions.get(expr_index.toU32())
        else
            self.expressions[expr_index.toU32()];

        switch (expr.kind) {
            .assign => {
                const data = expr.data.binary;
                const lhs = if (config.use_multiarraylist)
                    self.expressions.get(data.lhs.toU32())
                else
                    self.expressions[data.lhs.toU32()];

                switch (lhs.kind) {
                    .var_ref => {
                        const value = try self.executeExpr(data.rhs);
                        const name = if (config.use_u64)
                            lhs.data.var_ref
                        else
                            (@as(u64, @intCast(lhs.data.var_ref[1])) << 32) | lhs.data.var_ref[0];
                        self.variables[name] = value;
                        return value;
                    },
                    else => return error.ExpressionIsNotAssignable,
                }
            },
            .number => return if (config.use_u64)
                expr.data.number
            else
                (@as(u64, @intCast(expr.data.number[1])) << 32) | expr.data.number[0],
            .var_ref => return self.variables[
                if (config.use_u64)
                    expr.data.var_ref
                else
                    (@as(u64, @intCast(expr.data.var_ref[1])) << 32) | expr.data.var_ref[0]
            ],
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
