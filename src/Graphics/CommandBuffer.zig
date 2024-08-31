const CommandBuffer = @This();

pointer: ?*anyopaque,
interface: *const Interface,

pub const EndError = error{};
pub fn end(command_buffer: CommandBuffer) EndError!Graphics.RenderBuffer {
    return command_buffer.interface.end(command_buffer);
}

pub const Interface = struct {
    end: *const fn (CommandBuffer) EndError!Graphics.RenderBuffer,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        end: *const fn (*T) EndError!Graphics.RenderBuffer,
    }) Interface {
        const type_erased_fns = struct {
            fn end(command_buffer: CommandBuffer) EndError!Graphics.RenderBuffer {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.end(t);
            }
        };
        return Interface{
            .end = type_erased_fns.end,
        };
    }
};

const Graphics = @import("../Graphics.zig");
