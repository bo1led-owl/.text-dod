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

    var program: Program = program: {
        const stdin = std.Io.File.stdin();
        var input_reader = stdin.reader(io, &in_buffer);
        const decoder: bytecode.Decoder = .{ .reader = &input_reader.interface };
        break :program readProgram(gpa, decoder) catch |err| {
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
        var executor: Executor = .init(gpa, program, &stdout_writer.interface);
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

const ExprContainer = if (config.use_multiarraylist) std.MultiArrayList(Expr) else std.ArrayList(Expr);
const ExprSlice = if (config.use_multiarraylist) std.MultiArrayList(Expr).Slice else []Expr;

fn readProgram(gpa: std.mem.Allocator, decoder: bytecode.Decoder) error{ OutOfMemory, InvalidEnumTag, ReadFailed }!Program {
    var names: std.ArrayList(u8) = .empty;
    var top_level_expressions: std.ArrayList(Expr.Index) = .empty;
    var expression_storage: ExprContainer = .empty;

    errdefer names.deinit(gpa);
    errdefer top_level_expressions.deinit(gpa);
    errdefer expression_storage.deinit(gpa);

    while (true) {
        const expr = readExpr(gpa, &names, &expression_storage, decoder) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        try top_level_expressions.append(gpa, expr);
    }

    return .{
        .names = try names.toOwnedSlice(gpa),
        .top_level_expressions = try top_level_expressions.toOwnedSlice(gpa),
        .expression_storage = if (config.use_multiarraylist)
            expression_storage.toOwnedSlice()
        else
            try expression_storage.toOwnedSlice(gpa),
    };
}

fn readExpr(
    gpa: std.mem.Allocator,
    names: *std.ArrayList(u8),
    expression_storage: *ExprContainer,
    decoder: bytecode.Decoder,
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
            const len = try decoder.readVarNameLen();
            const prev_len = names.items.len;
            try names.resize(gpa, prev_len + len);
            const buf = names.items[prev_len..];
            try decoder.readVarName(buf);
            break :var_ref .{ .name = .{ .begin = @intCast(prev_len), .len = @intCast(len) } };
        },
        .print => .{ .unary = try readExpr(gpa, names, expression_storage, decoder) },
        .add, .sub, .mul, .div, .assign => .{ .binary = .{
            .lhs = try readExpr(gpa, names, expression_storage, decoder),
            .rhs = try readExpr(gpa, names, expression_storage, decoder),
        } },
    };

    const res = if (config.use_multiarraylist) expression_storage.len else expression_storage.items.len;
    try expression_storage.append(gpa, .{ .kind = opcode, .data = data });
    return @fromBackingInt(@intCast(res));
}

const Program = struct {
    names: []const u8,
    top_level_expressions: []const Expr.Index,
    expression_storage: ExprSlice,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        gpa.free(self.names);
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

    pub const Index = enum(u32) {
        _,

        pub fn toU32(self: Index) u32 {
            return @backingInt(self);
        }
    };

    pub const Name = struct { begin: u32, len: u32 };
    pub const Binary = struct { lhs: Expr.Index, rhs: Expr.Index };

    pub const Data = union(enum) {
        number: if (config.use_u64) u64 else [2]u32,
        name: Name,
        unary: Expr.Index,
        binary: Binary,
    };
};

pub const Executor = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    expressions: ExprSlice,
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
                        try self.variables.putContext(self.gpa, lhs.data.name, value, self.map_ctx);
                        return value;
                    },
                    else => return error.ExpressionIsNotAssignable,
                }
            },
            .number => return if (config.use_u64)
                expr.data.number
            else
                (@as(u64, @intCast(expr.data.number[1])) << 32) | expr.data.number[0],
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
