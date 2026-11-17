const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("bytecode");
const config = @import("config");

var out_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
var in_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const input_file_name = args: {
        var arg_iter = init.args.iterate();
        _ = arg_iter.next(); // skip program name

        const err_msg = "not enough arguments: expected INPUT_FILE";
        const input = arg_iter.next() orelse {
            std.log.err(err_msg, .{});
            return 2;
        };

        break :args input;
    };

    const input_file = std.Io.Dir.cwd().openFile(io, input_file_name, .{ .allow_directory = false }) catch |err| {
        std.log.err("failed to open input file: {s}", .{@errorName(err)});
        return 1;
    };
    defer input_file.close(io);

    var input_reader = input_file.reader(io, &in_buffer);
    const decoder: bytecode.Decoder = .{ .reader = &input_reader.interface };

    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writerStreaming(io, &out_buffer);
    defer stdout_writer.flush() catch {};

    disProgram(decoder, &stdout_writer.interface) catch |err| {
        const err_msg = switch (err) {
            error.WriteFailed => @errorName(stdout_writer.err.?),
            error.ReadFailed => @errorName(input_reader.err.?),
            error.InvalidEnumTag => "invalid opcode",
        };

        std.log.err("failed to disassemble: {s}", .{err_msg});
        return 1;
    };

    return 0;
}

fn disProgram(decoder: bytecode.Decoder, writer: *std.Io.Writer) !void {
    while (true) {
        disExpr(decoder, writer) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try writer.writeByte('\n');
    }
}

fn disExpr(decoder: bytecode.Decoder, writer: *std.Io.Writer) !void {
    const opcode = try decoder.readOpcode();

    switch (opcode) {
        .print => try writer.writeAll("print "),
        .add => try writer.writeAll("+ "),
        .sub => try writer.writeAll("- "),
        .mul => try writer.writeAll("* "),
        .div => try writer.writeAll("/ "),
        .assign => try writer.writeAll("= "),
        else => {},
    }

    switch (opcode) {
        .number => {
            const num = try decoder.readNumber();
            try writer.printInt(num, 10, .lower, .{});
        },
        .var_ref => {
            const len = try decoder.readVarNameLen();
            try decoder.reader.streamExact(writer, len);
        },
        .print => try disExpr(decoder, writer),
        .add, .sub, .mul, .div, .assign => {
            try disExpr(decoder, writer);
            try writer.writeByte(' ');
            try disExpr(decoder, writer);
        },
    }
}
