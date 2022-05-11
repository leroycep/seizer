const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

fn sliceContainsPtr(container: []u8, ptr: [*]u8) bool {
    return @ptrToInt(ptr) >= @ptrToInt(container.ptr) and
        @ptrToInt(ptr) < (@ptrToInt(container.ptr) + container.len);
}

fn sliceContainsSlice(container: []u8, slice: []u8) bool {
    return @ptrToInt(slice.ptr) >= @ptrToInt(container.ptr) and
        (@ptrToInt(slice.ptr) + slice.len) <= (@ptrToInt(container.ptr) + container.len);
}

/// A modifed fixed buffer allocator that allows freeing memory as a stack.
pub const StackAllocator = struct {
    end_index: usize,
    buffer: []u8,

    pub fn init(buffer: []u8) StackAllocator {
        return StackAllocator{
            .buffer = buffer,
            .end_index = 0,
        };
    }

    /// *WARNING* using this at the same time as the interface returned by `threadSafeAllocator` is not thread safe
    pub fn allocator(self: *StackAllocator) Allocator {
        return Allocator.init(self, alloc, resize, free);
    }

    pub fn ownsPtr(self: *StackAllocator, ptr: [*]u8) bool {
        return sliceContainsPtr(self.buffer, ptr);
    }

    pub fn ownsSlice(self: *StackAllocator, slice: []u8) bool {
        return sliceContainsSlice(self.buffer, slice);
    }

    /// NOTE: this will not work in all cases, if the last allocation had an adjusted_index
    ///       then we won't be able to determine what the last allocation was.  This is because
    ///       the alignForward operation done in alloc is not reversible.
    pub fn isLastAllocation(self: *StackAllocator, buf: []u8) bool {
        return buf.ptr + buf.len == self.buffer.ptr + self.end_index;
    }

    /// Header placed directly before allocations
    const Header = struct {
        padding: u8,
    };

    fn alloc(self: *StackAllocator, n: usize, ptr_align: u29, len_align: u29, ra: usize) Allocator.Error![]u8 {
        _ = len_align;
        _ = ra;
        if (ptr_align > 128) return error.OutOfMemory;
        const adjust_off = mem.alignPointerOffset(self.buffer.ptr + self.end_index + @sizeOf(Header), ptr_align) orelse
            return error.OutOfMemory;
        const adjusted_index = self.end_index + adjust_off + @sizeOf(Header);
        const new_end_index = adjusted_index + n;
        if (new_end_index > self.buffer.len) {
            return error.OutOfMemory;
        }
        std.log.info("{*}, {}, {}, {}", .{ self.buffer.ptr, self.end_index, adjust_off, @sizeOf(Header) });
        const header_index = adjusted_index - @sizeOf(Header);
        const header = .{ .padding = @truncate(u8, header_index - self.end_index) };
        const header_buf = self.buffer[header_index..adjusted_index];
        @ptrCast(*align(@alignOf(Header)) Header, header_buf).* = header;
        const result = self.buffer[adjusted_index..new_end_index];
        self.end_index = new_end_index;

        return result;
    }

    fn resize(
        self: *StackAllocator,
        buf: []u8,
        buf_align: u29,
        new_size: usize,
        len_align: u29,
        return_address: usize,
    ) ?usize {
        _ = buf_align;
        _ = return_address;
        assert(self.ownsSlice(buf)); // sanity check

        if (!self.isLastAllocation(buf)) {
            if (new_size > buf.len) return null;
            return mem.alignAllocLen(buf.len, new_size, len_align);
        }

        if (new_size <= buf.len) {
            const sub = buf.len - new_size;
            self.end_index -= sub;
            return mem.alignAllocLen(buf.len - sub, new_size, len_align);
        }

        const add = new_size - buf.len;
        if (add + self.end_index > self.buffer.len) return null;

        self.end_index += add;
        return new_size;
    }

    fn free(
        self: *StackAllocator,
        buf: []u8,
        buf_align: u29,
        return_address: usize,
    ) void {
        _ = buf_align;
        _ = return_address;
        assert(self.ownsSlice(buf)); // sanity check

        if (sliceContainsSlice(self.buffer[self.end_index..], buf)) {
            // Allow double frees
            return;
        }

        const start = @ptrToInt(self.buffer.ptr);
        const cur_addr = @ptrToInt(buf.ptr);

        const header = @intToPtr(*align(@alignOf(Header)) Header, cur_addr - @sizeOf(Header)).*;
        const prev_offset = cur_addr - header.padding - start;

        self.end_index = prev_offset;
    }

    pub fn reset(self: *StackAllocator) void {
        self.end_index = 0;
    }
};
