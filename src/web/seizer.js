// Promises with an id, so that it can be passed to WASM
var idpromise_promises = {};
var idpromise_open_ids = [];

function idpromise_call(func, args) {
    let params = args || [];
    return new Promise((resolve, reject) => {
        let id = Object.keys(idpromise_promises).length;
        if (idpromise_open_ids.length > 0) {
            id = idpromise_open_ids.pop();
        }
        idpromise_promises[id] = { resolve, reject };
        func(id, ...params);
    });
}

function idpromise_reject(id, errno) {
    idpromise_promises[id].reject(errno);
    idpromise_open_ids.push(id);
    delete idpromise_promises[id];
}

function idpromise_resolve(id, data) {
    idpromise_promises[id].resolve(data);
    idpromise_open_ids.push(id);
    delete idpromise_promises[id];
}

// Platform ENV
export default function getPlatformEnv(canvas_element, getInstance) {
    const getMemory = () => getInstance().exports.memory;
    const utf8decoder = new TextDecoder();
    const readCharStr = (ptr, len) =>
        utf8decoder.decode(new Uint8Array(getMemory().buffer, ptr, len));
    const writeCharStr = (ptr, len, lenRetPtr, text) => {
        const encoder = new TextEncoder();
        const message = encoder.encode(text);
        const zigbytes = new Uint8Array(getMemory().buffer, ptr, len);
        let zigidx = 0;
        for (const b of message) {
            if (zigidx >= len - 1) break;
            zigbytes[zigidx] = b;
            zigidx += 1;
        }
        zigbytes[zigidx] = 0;
        if (lenRetPtr !== 0) {
            new Uint32Array(getMemory().buffer, lenRetPtr, 1)[0] = zigidx;
        }
    };

    function getErrorName(errno) {
        const instance = getInstance();
        const ptr = instance.exports.wasm_error_name_ptr(errno);
        const len = instance.exports.wasm_error_name_len(errno);
        return utf8decoder.decode(new Uint8Array(getMemory().buffer, ptr, len));
    }

    const initFinished = (maxDelta, tickDelta) => {
        const instance = getInstance();

        let prevTime = performance.now();
        let tickTime = 0.0;
        let accumulator = 0.0;

        function step(currentTime) {
            let delta = (currentTime - prevTime) / 1000; // Delta in seconds
            if (delta > maxDelta) {
                delta = maxDelta; // Try to avoid spiral of death when lag hits
            }
            prevTime = currentTime;

            accumulator += delta;

            while (accumulator >= tickDelta) {
                instance.exports.update(tickTime, tickDelta);
                accumulator -= tickDelta;
                tickTime += tickDelta;
            }

            // Where the render is between two timesteps.
            // If we are halfway between frames (based on what's in the accumulator)
            // then alpha will be equal to 0.5
            const alpha = accumulator / tickDelta;

            instance.exports.render(alpha);

            if (running) {
                window.requestAnimationFrame(step);
            }
        }
        window.requestAnimationFrame(step);

        const ex = instance.exports;
        const keyMap = {
            Unknown: ex.KEYCODE_UNKNOWN,
            Backspace: ex.KEYCODE_BACKSPACE,
        };
        const codeMap = {
            Unknown: ex.SCANCODE_UNKNOWN,
            KeyW: ex.SCANCODE_W,
            KeyA: ex.SCANCODE_A,
            KeyS: ex.SCANCODE_S,
            KeyD: ex.SCANCODE_D,
            KeyZ: ex.SCANCODE_Z,
            KeyR: ex.SCANCODE_R,
            ArrowLeft: ex.SCANCODE_LEFT,
            ArrowRight: ex.SCANCODE_RIGHT,
            ArrowUp: ex.SCANCODE_UP,
            ArrowDown: ex.SCANCODE_DOWN,
            Escape: ex.SCANCODE_ESCAPE,
            Space: ex.SCANCODE_SPACE,
            Numpad0: ex.SCANCODE_NUMPAD0,
            Numpad1: ex.SCANCODE_NUMPAD1,
            Numpad2: ex.SCANCODE_NUMPAD2,
            Numpad3: ex.SCANCODE_NUMPAD3,
            Numpad4: ex.SCANCODE_NUMPAD4,
            Numpad5: ex.SCANCODE_NUMPAD5,
            Numpad6: ex.SCANCODE_NUMPAD6,
            Numpad7: ex.SCANCODE_NUMPAD7,
            Numpad8: ex.SCANCODE_NUMPAD8,
            Numpad9: ex.SCANCODE_NUMPAD9,
        };
        document.addEventListener("keydown", (ev) => {
            if (document.activeElement != canvas_element) return;

            if (ev.defaultPrevented) {
                return;
            }
            ev.preventDefault();

            let zigKeyConst = keyMap[ev.key];
            if (!zigKeyConst) {
                zigKeyConst = keyMap.Unknown;
            }

            let zigScancodeConst = codeMap[ev.code];
            if (!zigScancodeConst) {
                zigScancodeConst = codeMap.Unknown;
            }

            const zigKey = new Uint16Array(getMemory().buffer, zigKeyConst, 1)[0];
            const zigScancode = new Uint16Array(
                getMemory().buffer,
                zigScancodeConst,
                1
            )[0];
            instance.exports.onKeyDown(zigKey, zigScancode);

            if (!ev.isComposing) {
                switch (ev.key) {
                    case "Unidentified":
                    case "Alt":
                    case "AltGraph":
                    case "CapsLock":
                    case "Control":
                    case "Fn":
                    case "FnLock":
                    case "Hyper":
                    case "Meta":
                    case "NumLock":
                    case "ScrollLock":
                    case "Shift":
                    case "Super":
                    case "Symbol":
                    case "SymbolLock":
                    case "Enter":
                    case "Tab":
                    case "ArrowDown":
                    case "ArrowLeft":
                    case "ArrowRight":
                    case "ArrowUp":
                    case "OS":
                    case "Escape":
                    case "Backspace":
                        // Don't send text input events for special keys
                        return;
                    default:
                        break;
                }
                const zigbytes = new Uint8Array(
                    getMemory().buffer,
                    instance.exports.TEXT_INPUT_BUFFER,
                    32
                );

                const encoder = new TextEncoder();
                const message = encoder.encode(ev.key);

                let zigidx = 0;
                for (const b of message) {
                    if (zigidx >= 32 - 1) break;
                    zigbytes[zigidx] = b;
                    zigidx += 1;
                }
                zigbytes[zigidx] = 0;

                instance.exports.onTextInput(zigidx);
            }
        });

        document.addEventListener("keyup", (ev) => {
            if (ev.defaultPrevented) {
                return;
            }
            const zigConst = codeMap[ev.code];
            if (zigConst !== undefined) {
                const zigCode = new Uint16Array(
                    getMemory().buffer,
                    zigConst,
                    1
                )[0];
                instance.exports.onKeyUp(zigCode);
            }
        });
    };

    const gl = canvas_element.getContext("webgl2", {
        antialias: false,
        preserveDrawingBuffer: true,
    });

    if (!gl) {
        throw new Error("The browser does not support WebGL");
    }

    // Start resources arrays with a null value to ensure the id 0 is never returned
    const glShaders = [null];
    const glPrograms = [null];
    const glBuffers = [null];
    const glVertexArrays = [null];
    const glTextures = [null];
    const glFramebuffers = [null];
    const glUniformLocations = [null];

    // Set up errno constants to be filled in when `seizer_run` is called
    let ERRNO_OUT_OF_MEMORY = undefined;
    let ERRNO_FILE_NOT_FOUND = undefined;
    let ERRNO_UNKNOWN = undefined;

    let seizer_log_string = "";
    let running = true;

    return {
        seizer_run(maxDelta, tickDelta) {
            const instance = getInstance();

            // Load error numbers from WASM
            const dataview = new DataView(instance.exports.memory.buffer);
            ERRNO_OUT_OF_MEMORY = dataview.getUint32(
                instance.exports.ERRNO_OUT_OF_MEMORY,
                true
            );
            ERRNO_FILE_NOT_FOUND = dataview.getUint32(
                instance.exports.ERRNO_FILE_NOT_FOUND,
                true
            );
            ERRNO_UNKNOWN = dataview.getUint32(
                instance.exports.ERRNO_UNKNOWN,
                true
            );

            // TODO: call async init function
            idpromise_call(instance.exports.onInit).then((_data) => {
                initFinished(maxDelta, tickDelta);
            });
        },
        seizer_quit() {
            running = false;
        },
        seizer_log_write: (ptr, len) => {
            seizer_log_string += utf8decoder.decode(
                new Uint8Array(getMemory().buffer, ptr, len)
            );
        },
        seizer_log_flush: () => {
            console.log(seizer_log_string);
            seizer_log_string = "";
        },
        seizer_reject_promise: (id, errno) => {
            idpromise_reject(id, new Error(getErrorName(errno)));
        },
        seizer_resolve_promise: idpromise_resolve,

        seizer_fetch: (ptr, len, cb, ctx, allocator) => {
            const instance = getInstance();

            const filename = utf8decoder.decode(
                new Uint8Array(getMemory().buffer, ptr, len)
            );

            fetch(filename)
                .then((response) => {
                    if (!response.ok) {
                        instance.exports.wasm_fail_fetch(
                            cb,
                            ctx,
                            ERRNO_FILE_NOT_FOUND
                        );
                    }
                    return response.arrayBuffer();
                })
                .then((buffer) => new Uint8Array(buffer))
                .then(
                    (bytes) => {
                        const wasm_bytes_ptr = instance.exports.wasm_allocator_alloc(
                            allocator,
                            bytes.byteLength
                        );
                        if (wasm_bytes_ptr == 0) {
                            instance.exports.wasm_fail_fetch(
                                cb,
                                ctx,
                                ERRNO_OUT_OF_MEMORY
                            );
                        }

                        const wasm_bytes = new Uint8Array(
                            instance.exports.memory.buffer,
                            wasm_bytes_ptr,
                            bytes.byteLength
                        );
                        wasm_bytes.set(bytes);

                        instance.exports.wasm_finalize_fetch(
                            cb,
                            ctx,
                            wasm_bytes_ptr,
                            bytes.byteLength
                        );
                    },
                    (err) =>
                        instance.exports.wasm_fail_fetch(cb, ctx, ERRNO_UNKNOWN)
                );
        },
        seizer_random_bytes(ptr, len) {
            const bytes = new Uint8Array(getMemory().buffer, ptr, len);
            window.crypto.getRandomValues(bytes);
        },

        getScreenW() {
            return gl.drawingBufferWidth;
        },
        getScreenH() {
            return gl.drawingBufferHeight;
        },

        // GL stuff
        activeTexture(target) {
            gl.activeTexture(target);
        },
        attachShader(program, shader) {
            gl.attachShader(glPrograms[program], glShaders[shader]);
        },
        bindBuffer(type, buffer_id) {
            gl.bindBuffer(type, glBuffers[buffer_id]);
        },
        bindVertexArray(vertex_array_id) {
            gl.bindVertexArray(glVertexArrays[vertex_array_id]);
        },
        bindFramebuffer(target, framebuffer) {
            gl.bindFramebuffer(target, glFramebuffers[framebuffer]);
        },
        bindTexture(target, texture_id) {
            gl.bindTexture(target, glTextures[texture_id]);
        },
        blendFunc(x, y) {
            gl.blendFunc(x, y);
        },
        bufferData(type, count, data_ptr, draw_type) {
            const bytes = new Uint8Array(getMemory().buffer, data_ptr, count);
            gl.bufferData(type, bytes, draw_type);
        },
        checkFramebufferStatus(target) {
            return gl.checkFramebufferStatus(target);
        },
        clear(mask) {
            gl.clear(mask);
        },
        clearColor(r, g, b, a) {
            gl.clearColor(r, g, b, a);
        },
        compileShader(shader) {
            gl.compileShader(glShaders[shader]);
        },
        getShaderiv(shader, pname, outptr) {
            new Int32Array(
                getMemory().buffer,
                outptr,
                1
            )[0] = gl.getShaderParameter(glShaders[shader], pname);
        },
        createBuffer() {
            glBuffers.push(gl.createBuffer());
            return glBuffers.length - 1;
        },
        genBuffers(amount, ptr) {
            let out = new Uint32Array(getMemory().buffer, ptr, amount);
            for (let i = 0; i < amount; i += 1) {
                out[i] = glBuffers.length;
                glBuffers.push(gl.createBuffer());
            }
        },
        createFramebuffer() {
            glFramebuffers.push(gl.createFramebuffer());
            return glFramebuffers.length - 1;
        },
        createProgram() {
            glPrograms.push(gl.createProgram());
            return glPrograms.length - 1;
        },
        createShader(shader_type) {
            glShaders.push(gl.createShader(shader_type));
            return glShaders.length - 1;
        },
        genTextures(amount, ptr) {
            let out = new Uint32Array(getMemory().buffer, ptr, amount);
            for (let i = 0; i < amount; i += 1) {
                out[i] = glTextures.length;
                glTextures.push(gl.createTexture());
            }
        },
        deleteBuffers(amount, ids_ptr) {
            let ids = new Uint32Array(getMemory().buffer, ids_ptr, amount);
            for (let i = 0; i < amount; i += 1) {
                const id = ids[i];
                gl.deleteBuffer(glBuffers[id]);
                glBuffers[id] = undefined;
            }
        },
        deleteProgram(id) {
            gl.deleteProgram(glPrograms[id]);
            glPrograms[id] = undefined;
        },
        deleteShader(id) {
            gl.deleteShader(glShaders[id]);
            glShaders[id] = undefined;
        },
        deleteTexture(id) {
            gl.deleteTexture(glTextures[id]);
            glTextures[id] = undefined;
        },
        deleteVertexArrays(amount, ids_ptr) {
            let ids = new Uint32Array(getMemory().buffer, ids_ptr, amount);
            for (let i = 0; i < amount; i += 1) {
                const id = ids[i];
                gl.deleteVertexArray(glVertexArrays[id]);
                glVertexArrays[id] = undefined;
            }
        },
        depthFunc(x) {
            gl.depthFunc(x);
        },
        detachShader(program, shader) {
            gl.detachShader(glPrograms[program], glShaders[shader]);
        },
        disable(cap) {
            gl.disable(cap);
        },
        genVertexArrays(amount, ptr) {
            let out = new Uint32Array(getMemory().buffer, ptr, amount);
            for (let i = 0; i < amount; i += 1) {
                out[i] = glVertexArrays.length;
                glVertexArrays.push(gl.createVertexArray());
            }
        },
        drawArrays(type, offset, count) {
            gl.drawArrays(type, offset, count);
        },
        drawElements(mode, count, type, offset) {
            gl.drawElements(mode, count, type, offset);
        },
        enable(x) {
            gl.enable(x);
        },
        enableVertexAttribArray(x) {
            gl.enableVertexAttribArray(x);
        },
        framebufferTexture2D(target, attachment, textarget, texture, level) {
            gl.framebufferTexture2D(
                target,
                attachment,
                textarget,
                glTextures[texture],
                level
            );
        },
        frontFace(mode) {
            gl.frontFace(mode);
        },
        getAttribLocation_(program_id, name_ptr, name_len) {
            const name = readCharStr(name_ptr, name_len);
            return gl.getAttribLocation(glPrograms[program_id], name);
        },
        getError() {
            return gl.getError();
        },
        getShaderInfoLog(shader, maxLength, length, infoLog) {
            writeCharStr(
                infoLog,
                maxLength,
                length,
                gl.getShaderInfoLog(glShaders[shader])
            );
        },
        getUniformLocation_(program_id, name_ptr, name_len) {
            const name = readCharStr(name_ptr, name_len);
            glUniformLocations.push(
                gl.getUniformLocation(glPrograms[program_id], name)
            );
            return glUniformLocations.length - 1;
        },
        linkProgram(program) {
            gl.linkProgram(glPrograms[program]);
        },
        getProgramiv(program, pname, outptr) {
            new Int32Array(
                getMemory().buffer,
                outptr,
                1
            )[0] = gl.getProgramParameter(glPrograms[program], pname);
        },
        getProgramInfoLog(program, maxLength, length, infoLog) {
            writeCharStr(
                infoLog,
                maxLength,
                length,
                gl.getProgramInfoLog(glPrograms[program])
            );
        },
        pixelStorei(pname, param) {
            gl.pixelStorei(pname, param);
        },
        shaderSource(shader, count, string_ptrs, string_len_array) {
            let string = "";

            let pointers = new Uint32Array(
                getMemory().buffer,
                string_ptrs,
                count
            );
            let lengths = new Uint32Array(
                getMemory().buffer,
                string_len_array,
                count
            );
            for (let i = 0; i < count; i += 1) {
                // TODO: Check if webgl can accept an array of strings
                const string_to_append = readCharStr(pointers[i], lengths[i]);
                string = string + string_to_append;
            }

            gl.shaderSource(glShaders[shader], string);
        },
        texImage2D(
            target,
            level,
            internal_format,
            width,
            height,
            border,
            format,
            type,
            data_ptr
        ) {
            const PIXEL_SIZES = {
                [gl.RGBA]: 4,
            };
            const pixel_size = PIXEL_SIZES[format];

            // Need to find out the pixel size for more formats
            if (!format) throw new Error("Unimplemented pixel format");

            const data =
                data_ptr != 0
                    ? new Uint8Array(
                          getMemory().buffer,
                          data_ptr,
                          width * height * pixel_size
                      )
                    : null;

            gl.texImage2D(
                target,
                level,
                internal_format,
                width,
                height,
                border,
                format,
                type,
                data
            );
        },
        texParameterf(target, pname, param) {
            gl.texParameterf(target, pname, param);
        },
        texParameteri(target, pname, param) {
            gl.texParameteri(target, pname, param);
        },
        uniform1f(location_id, x) {
            gl.uniform1f(glUniformLocations[location_id], x);
        },
        uniform1i(location_id, x) {
            gl.uniform1i(glUniformLocations[location_id], x);
        },
        uniform4f(location_id, x, y, z, w) {
            gl.uniform4f(glUniformLocations[location_id], x, y, z, w);
        },
        uniformMatrix4fv(location_id, data_len, transpose, data_ptr) {
            const floats = new Float32Array(
                getMemory().buffer,
                data_ptr,
                data_len * 16
            );
            gl.uniformMatrix4fv(
                glUniformLocations[location_id],
                transpose,
                floats
            );
        },
        useProgram(program_id) {
            gl.useProgram(glPrograms[program_id]);
        },
        vertexAttribPointer(
            attrib_location,
            size,
            type,
            normalize,
            stride,
            offset
        ) {
            gl.vertexAttribPointer(
                attrib_location,
                size,
                type,
                normalize,
                stride,
                offset
            );
        },
        viewport(x, y, width, height) {
            gl.viewport(x, y, width, height);
        },
        scissor(x, y, width, height) {
            gl.scissor(x, y, width, height);
        },
    };
}
