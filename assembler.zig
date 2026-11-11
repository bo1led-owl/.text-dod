const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
var in_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    var allocator = switch (builtin.optimize) {
        .debug => std.heap.DebugAllocator(.{}){},
        .safe => std.heap.SafeAllocator.init(std.heap.page_allocator, .{}),
        else => struct {
            pub fn allocator(self: @This()) std.mem.Allocator {
                _ = self;
                return std.heap.brk_allocator;
            }
            pub fn deinit(self: @This()) void {
                _ = self;
            }
        }{},
    };

    const gpa = allocator.allocator();
    defer _ = allocator.deinit();

    var io_impl = std.Io.Threaded.init_single_threaded;
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

    const input_file = std.Io.Dir.cwd().openFile(io, input_file_name, .{ .allow_directory = false }) catch |err| {
        std.log.err("failed to open input file: {s}", .{@errorName(err)});
        return 1;
    };
    defer input_file.close(io);

    var input_file_reader = input_file.readerStreaming(io, &in_buffer);

    const output_file = std.Io.Dir.cwd().createFile(io, output_file_name, .{}) catch |err| {
        std.log.err("failed to open output file: {s}", .{@errorName(err)});
        return 1;
    };
    defer output_file.close(io);

    var output_file_writer = output_file.writer(io, &out_buffer);
    var encoder: format.Encoder = .{ .writer = &output_file_writer.interface };

    var preprocessor: Preprocessor = .init(gpa, &input_file_reader.interface, &encoder);
    defer preprocessor.deinit();

    preprocessor.run() catch |err| {
        std.log.err("failed to preprocess: {s}", .{@errorName(switch (err) {
            error.ReadFailed => input_file_reader.err.?,
            error.WriteFailed => output_file_writer.err.?,
            else => err,
        })});
    };

    output_file_writer.flush() catch |err| {
        std.log.err("failed to flush output: {s}", .{@errorName(err)});
        return 1;
    };

    return 0;
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

const Preprocessor = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    encoder: *format.Encoder,
    line_writer: std.Io.Writer.Allocating,

    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, encoder: *format.Encoder) Preprocessor {
        return .{
            .gpa = gpa,
            .reader = reader,
            .encoder = encoder,
            .line_writer = .init(gpa),
        };
    }

    pub fn deinit(self: *Preprocessor) void {
        defer self.* = undefined;
        self.line_writer.deinit();
    }

    pub fn run(self: *Preprocessor) !void {
        var running = true;
        while (running) {
            running = try self.preprocessExpr();
        }
    }

    fn preprocessExpr(self: *Preprocessor) !bool {
        self.line_writer.clearRetainingCapacity();

        _ = self.reader.streamDelimiterEnding(&self.line_writer.writer, '\n') catch |err|
            switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => |e| return e,
            };

        if (self.reader.bufferedLen() > 0 and self.reader.buffered()[0] == '\n') {
            self.reader.toss(1);
        }

        const input = self.line_writer.written();
        var cursor = std.mem.splitAny(u8, input, &std.ascii.whitespace);

        const res = try self.preprocessExprInternal(&cursor);

        while (cursor.next()) |item| {
            if (item.len != 0) {
                return error.IncompleteExpression;
            }
        }
        return res;
    }

    fn preprocessExprInternal(self: *Preprocessor, cursor: *std.mem.SplitIterator(u8, .any)) !bool {
        const item = while (cursor.next()) |item| {
            if (item.len != 0) {
                break item;
            }
        } else {
            return false;
        };

        switch (item[0]) {
            '=', '+', '-', '*', '/' => |c| if (item.len == 1) {
                try self.encoder.writeOpcode(switch (c) {
                    '=' => .assign,
                    '+' => .add,
                    '-' => .sub,
                    '*' => .mul,
                    '/' => .div,
                    else => unreachable,
                });

                if (!try self.preprocessExprInternal(cursor)) {
                    return error.IncompleteExpression;
                }
                if (!try self.preprocessExprInternal(cursor)) {
                    return error.IncompleteExpression;
                }
            } else {
                return error.NoWhitespace;
            },
            else => |first_char| if (std.mem.eql(u8, item, "print")) {
                try self.encoder.writeOpcode(.print);
                if (!try self.preprocessExprInternal(cursor)) {
                    return error.IncompleteExpression;
                }
            } else if (std.ascii.isDigit(first_char)) {
                const value = std.fmt.parseUnsigned(u64, item, 10) catch |err| switch (err) {
                    error.Overflow => return error.NumberTooLarge,
                    error.InvalidCharacter => return error.NoWhitespace,
                };

                try self.encoder.writeOpcode(.number);
                try self.encoder.writeNumber(value);
            } else if (first_char == '_' or std.ascii.isAlphabetic(first_char)) {
                try self.encoder.writeOpcode(.var_ref);
                try self.encoder.writeVarName(item);
            } else {
                return error.InvalidCharacter;
            },
        }

        return true;
    }
};
