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

    var program: Program = program: {
        const stdin = std.Io.File.stdin();
        var input_reader = stdin.reader(io, &in_buffer);
        var decoder: format.Reader = .{ .reader = &input_reader.interface };
        break :program readProgram(gpa, &decoder) catch |err| {
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

    return 0;
}

fn readProgram(gpa: std.mem.Allocator, decoder: *format.Reader) error{ OutOfMemory, InvalidEnumTag, ReadFailed }!Program {
    var names: std.ArrayList(u8) = .empty;
    var top_level_expressions: std.ArrayList(Expr.Index) = .empty;
    var expression_storage: std.MultiArrayList(Expr) = .empty;

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
        .expression_storage = expression_storage.toOwnedSlice(),
    };
}

fn readExpr(
    gpa: std.mem.Allocator,
    names: *std.ArrayList(u8),
    expression_storage: *std.MultiArrayList(Expr),
    decoder: *format.Reader,
) !Expr.Index {
    const opcode = try decoder.readOpcode();
    const data: Expr.Data = switch (opcode) {
        .number => .{ .number = try decoder.readNumber() },
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

    const res = expression_storage.len;
    try expression_storage.append(gpa, .{ .kind = opcode, .data = data });
    return @fromBackingInt(@intCast(res));
}

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

const Expr = struct {
    kind: format.Opcode,
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
        number: u64,
        name: Name,
        unary: Expr.Index,
        binary: Binary,
    };
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
