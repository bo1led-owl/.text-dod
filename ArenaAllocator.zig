const ArenaAllocator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

state: State,
child_allocator: Allocator,

pub const State = struct {
    buffer_list: std.SinglyLinkedList,
    end: usize,
};

pub const BufNode = struct {
    node: std.SinglyLinkedList.Node = .{},
    data: usize,

    pub const alignment = Alignment.of(BufNode);
};

pub fn init(child_allocator: Allocator) ArenaAllocator {
    return .{
        .state = .{ .buffer_list = .{}, .end = 0 },
        .child_allocator = child_allocator,
    };
}

pub fn deinit(self: *ArenaAllocator) void {
    var it = self.state.buffer_list.first;
    while (it) |node| {
        const next = node.next;
        const buf_node: *BufNode = @fieldParentPtr("node", node);
        const alloc_buf =
            @as([*]u8, @ptrCast(buf_node))[0..buf_node.data];
        self.child_allocator.rawFree(alloc_buf, BufNode.alignment, @returnAddress());
        it = next;
    }
    self.state = .{ .buffer_list = .{}, .end = 0 };
}

pub fn allocator(self: *ArenaAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn createNode(
    self: *ArenaAllocator,
    prev_len: usize,
    minimum_size: usize,
) ?*BufNode {
    const actual_min_size = minimum_size + (@sizeOf(BufNode) + 16);

    const big_enough_len = prev_len + actual_min_size;
    const len = big_enough_len + big_enough_len / 2;

    const ptr = self.child_allocator.rawAlloc(
        len,
        BufNode.alignment,
        @returnAddress(),
    ) orelse return null;

    const buf_node: *BufNode = @ptrCast(@alignCast(ptr));
    buf_node.* = .{ .data = len };

    self.state.buffer_list.prepend(&buf_node.node);
    self.state.end = 0;
    return buf_node;
}

fn alloc(
    ctx: *anyopaque,
    n: usize,
    alignment: Alignment,
    ra: usize,
) ?[*]u8 {
    _ = ra;
    const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    const ptr_align = alignment.toByteUnits();

    var cur_node: *BufNode = if (self.state.buffer_list.first) |first|
        @fieldParentPtr("node", first)
    else
        (self.createNode(0, n + ptr_align) orelse return null);

    while (true) {
        const cur_alloc_buf =
            @as([*]u8, @ptrCast(cur_node))[0..cur_node.data];
        const cur_buf = cur_alloc_buf[@sizeOf(BufNode)..];

        const addr = @intFromPtr(cur_buf.ptr) + self.state.end;
        const adjusted_addr = std.mem.alignForward(usize, addr, ptr_align);
        const adjusted_index =
            self.state.end + (adjusted_addr - addr);
        const new_end = adjusted_index + n;

        if (new_end <= cur_buf.len) {
            const result = cur_buf[adjusted_index..new_end];
            self.state.end = new_end;
            return result.ptr;
        }

        const bigger_buf_size = @sizeOf(BufNode) + new_end;
        if (self.child_allocator.rawResize(
            cur_alloc_buf,
            BufNode.alignment,
            bigger_buf_size,
            @returnAddress(),
        )) {
            cur_node.data = bigger_buf_size;
        } else {
            cur_node = self.createNode(
                cur_buf.len,
                n + ptr_align,
            ) orelse return null;
        }
    }
}

fn resize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = alignment;
    _ = ret_addr;
    const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));

    const cur_node = self.state.buffer_list.first orelse return false;
    const cur_buf_node: *BufNode = @fieldParentPtr("node", cur_node);
    const cur_buf =
        @as([*]u8, @ptrCast(cur_buf_node))[@sizeOf(BufNode)..cur_buf_node.data];

    if (@intFromPtr(cur_buf.ptr) + self.state.end !=
        @intFromPtr(buf.ptr) + buf.len)
    {
        return new_len <= buf.len;
    }

    if (buf.len >= new_len) {
        self.state.end -= buf.len - new_len;
        return true;
    } else if (cur_buf.len - self.state.end >= new_len - buf.len) {
        self.state.end += new_len - buf.len;
        return true;
    } else {
        return false;
    }
}

fn remap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr))
        memory.ptr
    else
        null;
}

fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    ret_addr: usize,
) void {
    _ = alignment;
    _ = ret_addr;
    const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));

    const cur_node = self.state.buffer_list.first orelse return;
    const cur_buf_node: *BufNode = @fieldParentPtr("node", cur_node);
    const cur_buf =
        @as([*]u8, @ptrCast(cur_buf_node))[@sizeOf(BufNode)..cur_buf_node.data];

    if (@intFromPtr(cur_buf.ptr) + self.state.end ==
        @intFromPtr(buf.ptr) + buf.len)
    {
        self.state.end -= buf.len;
    }
}
