const Pipeline = @This();

pointer: ?*anyopaque,
interface: *const Interface,

pub const CreateOptions = struct {
    vertex_shader: ShaderStageInfo,
    fragment_shader: ShaderStageInfo,
    attachment_info: AttachmentInfo,

    pub const ShaderStageInfo = struct {};
    pub const AttachmentInfo = struct {};
};

pub const Interface = struct {
    destroy: *const fn (Pipeline) void,
};

const std = @import("std");
