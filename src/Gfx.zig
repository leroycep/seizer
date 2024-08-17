ptr: ?*anyopaque,
interface: *const Interface,

pub const Interface = struct {
    begin: *const fn (?*anyopaque, BeginOptions) void,
    clear: *const fn (?*anyopaque, ClearOptions) void,
    end: *const fn (?*anyopaque, EndOptions) void,
};

pub const BeginOptions = struct {
    window_size: [2]f32,
    framebuffer_size: [2]f32,
    invert_y: bool = false,
};

pub const ClearOptions = struct {
    color: ?[4]f32,
};

pub const EndOptions = struct {};

pub fn begin(this: @This(), options: BeginOptions) void {
    this.interface.begin(this.ptr, options);
}

pub fn clear(this: @This(), options: ClearOptions) void {
    this.interface.clear(this.ptr, options);
}

pub fn end(this: @This(), options: EndOptions) void {
    this.interface.end(this.ptr, options);
}
