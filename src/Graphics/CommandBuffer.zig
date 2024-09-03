const CommandBuffer = @This();

pointer: ?*anyopaque,
interface: *const Interface,

pub fn bindPipeline(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline) void {
    return command_buffer.interface.bindPipeline(command_buffer, pipeline);
}

pub fn drawPrimitives(command_buffer: CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    return command_buffer.interface.drawPrimitives(command_buffer, vertex_count, instance_count, first_vertex, first_instance);
}

pub fn uploadToBuffer(command_buffer: CommandBuffer, buffer: *Graphics.Buffer, data: []const u8) void {
    return command_buffer.interface.uploadToBuffer(command_buffer, buffer, data);
}

pub fn bindVertexBuffer(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline, vertex_buffer: *Graphics.Buffer) void {
    return command_buffer.interface.bindVertexBuffer(command_buffer, pipeline, vertex_buffer);
}

// TODO: Swap out name for location
// TODO: replace with uniform buffer that just uploads bytes
pub fn uploadUniformMatrix4F32(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline, name: [:0]const u8, matrix: [4][4]f32) void {
    return command_buffer.interface.uploadUniformMatrix4F32(command_buffer, pipeline, name, matrix);
}

// TODO: Swap out name for location
// TODO: replace with uniform buffer that just uploads bytes
pub fn uploadUniformTexture(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline, name: [:0]const u8, texture: ?*Graphics.Texture) void {
    return command_buffer.interface.uploadUniformTexture(command_buffer, pipeline, name, texture);
}

pub const EndError = error{};
pub fn end(command_buffer: CommandBuffer) EndError!Graphics.RenderBuffer {
    return command_buffer.interface.end(command_buffer);
}

pub const Interface = struct {
    bindPipeline: *const fn (CommandBuffer, *Graphics.Pipeline) void,
    drawPrimitives: *const fn (CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void,
    uploadToBuffer: *const fn (CommandBuffer, buffer: *Graphics.Buffer, data: []const u8) void,
    bindVertexBuffer: *const fn (CommandBuffer, pipeline: *Graphics.Pipeline, buffer: *Graphics.Buffer) void,
    uploadUniformMatrix4F32: *const fn (CommandBuffer, pipeline: *Graphics.Pipeline, name: [:0]const u8, matrix: [4][4]f32) void,
    uploadUniformTexture: *const fn (CommandBuffer, *Graphics.Pipeline, name: [:0]const u8, texture: ?*Graphics.Texture) void,
    end: *const fn (CommandBuffer) EndError!Graphics.RenderBuffer,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        bindPipeline: *const fn (*T, *Graphics.Pipeline) void,
        drawPrimitives: *const fn (*T, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void,
        uploadToBuffer: *const fn (*T, buffer: *Graphics.Buffer, data: []const u8) void,
        bindVertexBuffer: *const fn (*T, pipeline: *Graphics.Pipeline, buffer: *Graphics.Buffer) void,
        uploadUniformMatrix4F32: *const fn (*T, pipeline: *Graphics.Pipeline, name: [:0]const u8, matrix: [4][4]f32) void,
        uploadUniformTexture: *const fn (*T, *Graphics.Pipeline, name: [:0]const u8, texture: ?*Graphics.Texture) void,
        end: *const fn (*T) EndError!Graphics.RenderBuffer,
    }) Interface {
        const type_erased_fns = struct {
            fn bindPipeline(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline) void {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.bindPipeline(t, pipeline);
            }
            fn drawPrimitives(command_buffer: CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.drawPrimitives(t, vertex_count, instance_count, first_vertex, first_instance);
            }
            fn uploadToBuffer(command_buffer: CommandBuffer, buffer: *Graphics.Buffer, data: []const u8) void {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.uploadToBuffer(t, buffer, data);
            }
            fn bindVertexBuffer(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline, vertex_buffer: *Graphics.Buffer) void {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.bindVertexBuffer(t, pipeline, vertex_buffer);
            }
            fn uploadUniformMatrix4F32(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline, name: [:0]const u8, matrix: [4][4]f32) void {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.uploadUniformMatrix4F32(t, pipeline, name, matrix);
            }
            fn uploadUniformTexture(command_buffer: CommandBuffer, pipeline: *Graphics.Pipeline, name: [:0]const u8, texture: ?*Graphics.Texture) void {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.uploadUniformTexture(t, pipeline, name, texture);
            }
            fn end(command_buffer: CommandBuffer) EndError!Graphics.RenderBuffer {
                const t: *T = @ptrCast(@alignCast(command_buffer.pointer));
                return typed_fns.end(t);
            }
        };
        return Interface{
            .bindPipeline = type_erased_fns.bindPipeline,
            .drawPrimitives = type_erased_fns.drawPrimitives,
            .uploadToBuffer = type_erased_fns.uploadToBuffer,
            .bindVertexBuffer = type_erased_fns.bindVertexBuffer,
            .uploadUniformMatrix4F32 = type_erased_fns.uploadUniformMatrix4F32,
            .uploadUniformTexture = type_erased_fns.uploadUniformTexture,
            .end = type_erased_fns.end,
        };
    }
};

const Graphics = @import("../Graphics.zig");
