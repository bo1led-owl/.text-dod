const std = @import("std");

pub const Opcode = enum(u3) {
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

    pub fn writeOpcode(self: Encoder, opcode: Opcode) std.Io.Writer.Error!void {
        comptime std.debug.assert(@typeInfo(@typeInfo(Opcode).@"enum".tag_type).int.bits <= @typeInfo(u8).int.bits);
        const value = @backingInt(opcode);
        try self.writer.writeInt(u8, value, .native);
    }

    pub fn writeNumber(self: Encoder, num: u64) std.Io.Writer.Error!void {
        try self.writer.writeInt(u64, num, .native);
    }

    pub fn writeVarName(self: Encoder, name: u64) std.Io.Writer.Error!void {
        try self.writer.writeInt(u64, name, .native);
    }
};

pub const Decoder = struct {
    reader: *std.Io.Reader,

    pub fn readOpcode(self: Decoder) !Opcode {
        comptime std.debug.assert(@typeInfo(@typeInfo(Opcode).@"enum".tag_type).int.bits <= @typeInfo(u8).int.bits);
        const read = try self.reader.takeInt(u8, .native);
        return std.enums.fromInt(Opcode, read) orelse error.InvalidEnumTag;
    }

    pub fn readNumber(self: Decoder) std.Io.Reader.Error!u64 {
        return self.reader.takeInt(u64, .native);
    }

    pub fn readVarName(self: Decoder) std.Io.Reader.Error!u64 {
        return try self.reader.takeInt(u64, .native);
    }
};
