const std = @import("std");

pub const Opcode = enum(u8) {
    number,
    var_ref,
    print,
    add,
    sub,
    mul,
    div,
    assign,
};

pub const Writer = struct {
    writer: *std.Io.Writer,

    pub fn writeOpcode(self: *Writer, opcode: Opcode) std.Io.Writer.Error!void {
        const value = @backingInt(opcode);
        try self.writer.writeInt(@TypeOf(value), value, .native);
    }

    pub fn writeNumber(self: *Writer, num: u64) std.Io.Writer.Error!void {
        try self.writer.writeInt(u64, num, .native);
    }

    pub fn writeVarName(self: *Writer, name: []const u8) std.Io.Writer.Error!void {
        try self.writer.writeInt(usize, name.len, .native);
        try self.writer.writeSliceEndian(u8, name, .native);
    }
};

pub const Reader = struct {
    reader: *std.Io.Reader,

    pub fn readOpcode(self: *Reader) !Opcode {
        return try self.reader.takeEnum(Opcode, .native);
    }

    pub fn readNumber(self: *Reader) std.Io.Reader.Error!u64 {
        return self.reader.takeInt(u64, .native);
    }

    pub fn readVarNameLen(self: *Reader) std.Io.Reader.Error!usize {
        return self.reader.takeInt(usize, .native);
    }

    pub fn readVarName(self: *Reader, buffer: []u8) std.Io.Reader.Error!void {
        try self.reader.readSliceEndian(u8, buffer, .native);
    }
};
