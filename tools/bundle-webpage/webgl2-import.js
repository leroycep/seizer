function getWebgl2WasmImport(getMemory, getGlContext) {
  let text_decoder = new TextDecoder();

  let gl_shaders = {};
  let gl_shaders_next_id = 4;
  let gl_programs = {};
  let gl_programs_next_id = 4;
  let gl_textures = {};
  let gl_textures_next_id = 4;
  let gl_vertex_arrays = {};
  let gl_vertex_arrays_next_id = 4;
  let gl_buffers = {};
  let gl_buffers_next_id = 4;
  let gl_uniform_locations = {};
  let gl_uniform_locations_next_id = 4;

  return {
    genTextures: function(textures_len, textures_ptr) {
      const textures_out = new Uint32Array(getMemory().buffer, textures_ptr, textures_len);
      for (let i = 0; i < textures_len; i += 1) {
        const texture_id = gl_textures_next_id;
        gl_textures_next_id += 1;

        gl_textures[texture_id] = getGlContext().createTexture();

        textures_out[i] = texture_id;
      }
    },
    deleteTextures: function(textures_len, textures_ptr) {
      const textures = new Uint32Array(getMemory().buffer, textures_ptr, textures_len);
      for (let i = 0; i < textures_len; i += 1) {
        const texture_id = textures[i];
        getGlContext().deleteTexture(gl_textures[texture_id]);
        delete gl_textures[texture_id];
      }
    },

    genBuffers: function(buffers_len, buffers_ptr) {
      const buffers_out = new Uint32Array(getMemory().buffer, buffers_ptr, buffers_len);
      for (let i = 0; i < buffers_len; i += 1) {
        const buffer_id = gl_buffers_next_id;
        gl_buffers_next_id += 1;

        gl_buffers[buffer_id] = getGlContext().createBuffer();

        buffers_out[i] = buffer_id;
      }
    },
    deleteBuffers: function(buffers_len, buffers_ptr) {
      const buffers = new Uint32Array(getMemory().buffer, buffers_ptr, buffers_len);
      for (let i = 0; i < buffers_len; i += 1) {
        const buffer_id = buffers[i];
        getGlContext().deleteBuffer(gl_buffers[buffer_id]);
        delete gl_buffers[buffer_id];
      }
    },

    genVertexArrays: function(vertex_arrays_len, vertex_arrays_ptr) {
      const vertex_arrays_out = new Uint32Array(getMemory().buffer, vertex_arrays_ptr, vertex_arrays_len);
      for (let i = 0; i < vertex_arrays_len; i += 1) {
        const vertex_array_id = gl_vertex_arrays_next_id;
        gl_vertex_arrays_next_id += 1;

        gl_vertex_arrays[vertex_array_id] = getGlContext().createVertexArray();

        vertex_arrays_out[i] = vertex_array_id;
      }
    },
    createProgram: function() {
        const program_id = gl_programs_next_id;
        gl_programs_next_id += 1;
        gl_programs[program_id] = getGlContext().createProgram();
        return program_id;
    },
    createShader: function(shader_type) {
        const shader_id = gl_shaders_next_id;
        gl_shaders_next_id += 1;
        gl_shaders[shader_id] = getGlContext().createShader(shader_type);
        return shader_id;
    },

    // pub extern "webgl" fn texImage2D(target: Enum, level: Int, internalformat: Int, width: Sizei, height: Sizei, border: Int, format: Enum, @"type": Enum, pixels: ?*const anyopaque) void;
    texImage2D: function(target, level, internalformat, width, height, border, format, pixel_type, pixels_ptr) {
      const pixels = new Uint8Array(getMemory().buffer, pixels_ptr, width * height * 4);
      getGlContext().texImage2D(target, level, internalformat, width, height, border, format, pixel_type, pixels);
    },

    // pub extern "webgl" fn bufferData(target: Enum, size: Sizeiptr, data: ?*const anyopaque, usage: Enum) void;
    bufferData: function(target, data_len, data_ptr, usage) {
      const data = new Uint8Array(getMemory().buffer, data_ptr, data_len);
      getGlContext().bufferData(target, data, usage);
    },

    // pub extern "webgl" fn shaderSource(shader: Uint, count: Sizei, string: [*c]const [*c]const Char, length: [*c]const Int) void;
    shaderSource: function(shader_id, count, string_ptrs_ptr, string_lens_ptr) {
      const data_view = new DataView(getMemory().buffer);

      let shader_text = "";
      for (let i = 0; i < count; i += 1) {
        const string_ptr = data_view.getUint32(string_ptrs_ptr + i * 4, true);
        const string_len = data_view.getUint32(string_lens_ptr + i * 4, true);
        const string = text_decoder.decode(new Uint8Array(getMemory().buffer, string_ptr, string_len));
        shader_text = shader_text + string;
      }

      getGlContext().shaderSource(gl_shaders[shader_id], shader_text);
    },

    // pub extern "webgl" fn getShaderiv(shader: Uint, pname: Enum, params: [*c]Int) void;
    getShaderiv: function(shader_id, pname, out_ptr) {
      if (pname === 0x8b84) return 0;
      const ret_value = getGlContext().getShaderParameter(gl_shaders[shader_id], pname);

      const data_view = new DataView(getMemory().buffer);
      data_view.setUint32(out_ptr, ret_value, true);
    },
    // pub extern "webgl" fn getProgramiv(program: Uint, pname: Enum, params: [*c]Int) void;
    getProgramiv: function(program_id, pname, out_ptr) {
      // if (pname === 0x8b84) return 0;
      const ret_value = getGlContext().getProgramParameter(gl_programs[program_id], pname);

      const data_view = new DataView(getMemory().buffer);
      data_view.setUint32(out_ptr, ret_value, true);
    },

    // pub extern "webgl" fn getShaderInfoLog(shader: Uint, bufSize: Sizei, length: [*c]Sizei, infoLog: [*c]Char) void;
    getShaderInfoLog: function(shader_id, buf_size, lens_ptr, info_log_ptr) { throw "getShaderInfoLog unimplemented"; },
    // pub extern "webgl" fn getProgramInfoLog(program: Uint, bufSize: Sizei, length: [*c]Sizei, infoLog: [*c]Char) void;
    getProgramInfoLog: function(program_id, buf_size, len_ptrs, info_log_ptrs) { throw "getProgramInfoLog unimplemented"; },

    // pub extern "webgl2" fn getUniformLocation(program: Uint, name: [*:0]const Char) void;
    getUniformLocation: function(program_id, name_ptr) {
      const data_view = new DataView(getMemory().buffer);
      let name_len = 0;
      for (;; name_len += 1) {
        if (data_view.getUint8(name_ptr + name_len, true) === 0) {
          break;
        }
      }

      const name = text_decoder.decode(new Uint8Array(getMemory().buffer, name_ptr, name_len));

      const uniform_location_id = gl_uniform_locations_next_id;
      gl_uniform_locations_next_id += 1;

      gl_uniform_locations[uniform_location_id] = getGlContext().getUniformLocation(gl_programs[program_id], name);
      return uniform_location_id;
    },

    // pub extern "webgl2" fn uniformMatrix4fv(location: Int, count: Sizei, transpose: Boolean, value: [*c]const Float) void;
    uniformMatrix4fv: function(uniform_location_id, count, transpose, value_ptr) {
      const value = new Float32Array(getMemory().buffer, value_ptr, count * 16)
      // console.log(uniform_location_id, gl_uniform_locations[uniform_location_id]);
      getGlContext().uniformMatrix4fv(gl_uniform_locations[uniform_location_id], transpose, value);
    },

    clearColor: function(red, green, blue, alpha) { getGlContext().clearColor(red, green, blue, alpha); },
    clear: function(mask) { getGlContext().clear(mask); },
    useProgram: function(program_id) { getGlContext().useProgram(gl_programs[program_id]); },
    activeTexture: function(active_texture) { getGlContext().activeTexture(active_texture); },
    bindTexture: function(target, texture_id) { getGlContext().bindTexture(target, gl_textures[texture_id]); },
    bindVertexArray: function(array_id) { getGlContext().bindVertexArray(gl_vertex_arrays[array_id]); },
    texParameteri: function(target, pname, param) { getGlContext().texParameteri(target, pname, param); },
    compileShader: function(shader_id) { return getGlContext().compileShader(gl_shaders[shader_id]); },
    deleteShader: function(shader_id) { return getGlContext().deleteShader(gl_shaders[shader_id]); },
    attachShader: function(program_id, shader_id) { return getGlContext().attachShader(gl_programs[program_id], gl_shaders[shader_id]); },
    linkProgram: function(program_id) { return getGlContext().linkProgram(gl_programs[program_id]); },
    detachShader: function(program_id, shader_id) { return getGlContext().detachShader(gl_programs[program_id], gl_shaders[shader_id]); },
    deleteProgram: function(program_id) { return getGlContext().deleteProgram(gl_programs[program_id]); },
    enableVertexAttribArray: function(index) { return getGlContext().enableVertexAttribArray(index); },
    bindBuffer: function(target, buffer_id) { return getGlContext().bindBuffer(target, gl_buffers[buffer_id]); },
    vertexAttribPointer: function(index, size, type, normalized, stride, pointer) { return getGlContext().vertexAttribPointer(index, size, type, normalized, stride, pointer); },
    drawArrays: function(mode, first, count) { return getGlContext().drawArrays(mode, first, count); },
    enable: function(cap) { return getGlContext().enable(cap); },
    disable: function(cap) { return getGlContext().disable(cap); },
    blendFunc: function(sfactor, dfactor) { return getGlContext().blendFunc(sfactor, dfactor); },
    scissor: function(x, y, width, height) { return getGlContext().scissor(x, y, width, height); },
    uniform1i: function(uniform_location_id, v0) { return getGlContext().uniform1i(gl_uniform_locations[uniform_location_id], v0); },
  };
}
