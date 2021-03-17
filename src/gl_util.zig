const std = @import("std");
const gl = @import("./seizer.zig").gl;

/// Custom functions to make loading easier
pub fn shaderSource(shader: gl.GLuint, source: []const u8) void {
    gl.shaderSource(shader, 1, &source.ptr, &@intCast(c_int, source.len));
}

pub fn compileShader(allocator: *std.mem.Allocator, vertex_source: [:0]const u8, fragment_source: [:0]const u8) !gl.GLuint {
    var vertex_shader = try compilerShaderPart(allocator, gl.VERTEX_SHADER, vertex_source);
    defer gl.deleteShader(vertex_shader);

    var fragment_shader = try compilerShaderPart(allocator, gl.FRAGMENT_SHADER, fragment_source);
    defer gl.deleteShader(fragment_shader);

    const program = gl.createProgram();
    if (program == 0)
        return error.OpenGlFailure;
    errdefer gl.deleteProgram(program);

    gl.attachShader(program, vertex_shader);
    defer gl.detachShader(program, vertex_shader);

    gl.attachShader(program, fragment_shader);
    defer gl.detachShader(program, fragment_shader);

    gl.linkProgram(program);

    var link_status: gl.GLint = undefined;
    gl.getProgramiv(program, gl.LINK_STATUS, &link_status);

    if (link_status != gl.TRUE) {
        var info_log_length: gl.GLint = undefined;
        gl.getProgramiv(program, gl.INFO_LOG_LENGTH, &info_log_length);

        const info_log = try allocator.alloc(u8, @intCast(usize, info_log_length));
        defer allocator.free(info_log);

        gl.getProgramInfoLog(program, @intCast(c_int, info_log.len), null, info_log.ptr);

        std.log.info("failed to compile shader:\n{}", .{info_log});

        return error.InvalidShader;
    }

    return program;
}

pub fn compilerShaderPart(allocator: *std.mem.Allocator, shader_type: gl.GLenum, source: [:0]const u8) !gl.GLuint {
    var shader = gl.createShader(shader_type);
    if (shader == 0)
        return error.OpenGlFailure;
    errdefer gl.deleteShader(shader);

    var sources = [_][*c]const u8{source.ptr};
    var lengths = [_]gl.GLint{@intCast(gl.GLint, source.len)};

    gl.shaderSource(shader, 1, &sources, &lengths);

    gl.compileShader(shader);

    var compile_status: gl.GLint = undefined;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &compile_status);

    if (compile_status != gl.TRUE) {
        var info_log_length: gl.GLint = undefined;
        gl.getShaderiv(shader, gl.INFO_LOG_LENGTH, &info_log_length);

        const info_log = try allocator.alloc(u8, @intCast(usize, info_log_length));
        defer allocator.free(info_log);

        gl.getShaderInfoLog(shader, @intCast(c_int, info_log.len), null, info_log.ptr);

        std.log.info("failed to compile shader:\n{}", .{info_log});

        return error.InvalidShader;
    }

    return shader;
}
