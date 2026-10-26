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

pub const Encoder = struct {
    writer: *std.Io.Writer,

    pub fn writeOpcode(self: *Encoder, opcode: Opcode) std.Io.Writer.Error!void {
        const value = @backingInt(opcode);
        try self.writer.writeInt(@TypeOf(value), value, .native);
    }

    pub fn writeNumber(self: *Encoder, num: u64) std.Io.Writer.Error!void {
        try self.writer.writeInt(u64, num, .native);
    }

    pub fn writeVarName(self: *Encoder, name: []const u8) std.Io.Writer.Error!void {
        try self.writer.writeInt(usize, name.len, .native);
        try self.writer.writeSliceEndian(u8, name, .native);
    }
};

pub const Decoder = struct {
    reader: *std.Io.Reader,

    pub fn readOpcode(self: *Decoder) !Opcode {
        return try self.reader.takeEnum(Opcode, .native);
    }

    pub fn readNumber(self: *Decoder) std.Io.Reader.Error!u64 {
        return self.reader.takeInt(u64, .native);
    }

    pub fn readVarNameLen(self: *Decoder) std.Io.Reader.Error!usize {
        return self.reader.takeInt(usize, .native);
    }

    pub fn readVarName(self: *Decoder, buffer: []u8) std.Io.Reader.Error!void {
        try self.reader.readSliceEndian(u8, buffer, .native);
    }
};
