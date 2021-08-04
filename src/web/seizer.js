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
        const codeMap = load_scancodes(instance);
        const keyEventToKeyScancode = (ev) => {
            let zigKeyConst = keyMap[ev.key];
            if (!zigKeyConst) {
                zigKeyConst = keyMap.Unknown;
            }

            const zigKey = new Uint16Array(
                getMemory().buffer,
                zigKeyConst,
                1
            )[0];
            return [
                zigKey,
                codeMap[ev.code] ? codeMap[ev.code] : codeMap.Unknown,
            ];
        };
        document.addEventListener("keydown", (ev) => {
            if (document.activeElement != canvas_element) return;

            if (ev.defaultPrevented) {
                return;
            }
            ev.preventDefault();

            const [zigKey, zigScancode] = keyEventToKeyScancode(ev);
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
            const [zigKey, zigScancode] = keyEventToKeyScancode(ev);
            instance.exports.onKeyUp(zigKey, zigScancode);
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

        now_f64() {
            return Date.now();
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
        deleteTextures(amount, ids_ptr) {
            let ids = new Uint32Array(getMemory().buffer, ids_ptr, amount);
            for (let i = 0; i < amount; i += 1) {
                const id = ids[i];
                gl.deleteTexture(glTextures[id]);
                glTextures[id] = undefined;
            }
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
                [gl.RGB]: 3,
            };
            const pixel_size = PIXEL_SIZES[format];

            // Need to find out the pixel size for more formats
            if (!pixel_size) throw new Error("Unimplemented pixel format");

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
        generateMipmap(mode) {
            gl.generateMipmap(mode);
        },
    };
}

function load_scancodes(instance) {
    const e = instance.exports;
    const codeMapPtrs = {
        Unknown: e.SCANCODE_UNKNOWN,
        Unidentified: e.SCANCODE_UNKNOWN,
        Escape: e.SCANCODE_ESCAPE,
        Digit0: e.SCANCODE__0,
        Digit1: e.SCANCODE__1,
        Digit2: e.SCANCODE__2,
        Digit3: e.SCANCODE__3,
        Digit4: e.SCANCODE__4,
        Digit5: e.SCANCODE__5,
        Digit6: e.SCANCODE__6,
        Digit7: e.SCANCODE__7,
        Digit8: e.SCANCODE__8,
        Digit9: e.SCANCODE__9,
        Minus: e.SCANCODE_MINUS,
        Equal: e.SCANCODE_EQUALS,
        Backspace: e.SCANCODE_BACKSPACE,
        Tab: e.SCANCODE_TAB,
        KeyQ: e.SCANCODE_Q,
        KeyW: e.SCANCODE_W,
        KeyE: e.SCANCODE_E,
        KeyR: e.SCANCODE_R,
        KeyT: e.SCANCODE_T,
        KeyY: e.SCANCODE_Y,
        KeyU: e.SCANCODE_U,
        KeyI: e.SCANCODE_I,
        KeyO: e.SCANCODE_O,
        KeyP: e.SCANCODE_P,
        BracketLeft: e.SCANCODE_LEFTBRACKET,
        BracketRight: e.SCANCODE_RIGHTBRACKET,
        Enter: e.SCANCODE_RETURN,
        ControlLeft: e.SCANCODE_LCTRL,
        KeyA: e.SCANCODE_A,
        KeyS: e.SCANCODE_S,
        KeyD: e.SCANCODE_D,
        KeyF: e.SCANCODE_F,
        KeyG: e.SCANCODE_G,
        KeyH: e.SCANCODE_H,
        KeyJ: e.SCANCODE_J,
        KeyK: e.SCANCODE_K,
        KeyL: e.SCANCODE_L,
        Semicolon: e.SCANCODE_SEMICOLON,
        Quote: e.SCANCODE_APOSTROPHE,
        Backquote: e.SCANCODE_GRAVE,
        ShiftLeft: e.SCANCODE_LSHIFT,
        Backslash: e.SCANCODE_BACKSLASH,
        KeyZ: e.SCANCODE_Z,
        KeyX: e.SCANCODE_X,
        KeyC: e.SCANCODE_C,
        KeyV: e.SCANCODE_V,
        KeyB: e.SCANCODE_B,
        KeyN: e.SCANCODE_N,
        KeyM: e.SCANCODE_M,
        Comma: e.SCANCODE_COMMA,
        Period: e.SCANCODE_PERIOD,
        Slash: e.SCANCODE_SLASH,
        ShiftRight: e.SCANCODE_RSHIFT,
        NumpadMultiply: e.SCANCODE_KP_MULTIPLY,
        AltLeft: e.SCANCODE_LALT,
        Space: e.SCANCODE_SPACE,
        CapsLock: e.SCANCODE_CAPSLOCK,
        F1: e.SCANCODE_F1,
        F2: e.SCANCODE_F2,
        F3: e.SCANCODE_F3,
        F4: e.SCANCODE_F4,
        F5: e.SCANCODE_F5,
        F6: e.SCANCODE_F6,
        F7: e.SCANCODE_F7,
        F8: e.SCANCODE_F8,
        F9: e.SCANCODE_F9,
        F10: e.SCANCODE_F10,
        Pause: e.SCANCODE_PAUSE,
        ScrollLock: e.SCANCODE_SCROLLLOCK,
        Numpad7: e.SCANCODE_KP_7,
        Numpad8: e.SCANCODE_KP_8,
        Numpad9: e.SCANCODE_KP_9,
        NumpadSubtract: e.SCANCODE_KP_MINUS,
        Numpad4: e.SCANCODE_KP_4,
        Numpad5: e.SCANCODE_KP_5,
        Numpad6: e.SCANCODE_KP_6,
        NumpadAdd: e.SCANCODE_KP_PLUS,
        Numpad1: e.SCANCODE_KP_1,
        Numpad2: e.SCANCODE_KP_2,
        Numpad3: e.SCANCODE_KP_3,
        Numpad0: e.SCANCODE_KP_0,
        NumpadDecimal: e.SCANCODE_KP_PERIOD,

        // Only in Firefox
        PrintScreen: e.SCANCODE_PRINTSCREEN,

        IntlBackslash: e.SCANCODE_NONUSBACKSLASH,
        F11: e.SCANCODE_F11,
        F12: e.SCANCODE_F12,
        NumpadEqual: e.SCANCODE_KP_EQUALS,
        F13: e.SCANCODE_F13,
        F14: e.SCANCODE_F14,
        F15: e.SCANCODE_F15,
        F16: e.SCANCODE_F16,
        F17: e.SCANCODE_F17,
        F18: e.SCANCODE_F18,
        F19: e.SCANCODE_F19,
        F20: e.SCANCODE_F20,
        F21: e.SCANCODE_F21,
        F22: e.SCANCODE_F22,
        F23: e.SCANCODE_F23,
        F24: e.SCANCODE_F24,
        Lang2: e.SCANCODE_LANG2,
        Lang1: e.SCANCODE_LANG1,
        NumpadComma: e.SCANCODE_KP_COMMA,
        MediaTrackPrevious: e.SCANCODE_AUDIOPREV,
        MediaTrackNext: e.SCANCODE_AUDIONEXT,
        NumpadEnter: e.SCANCODE_KP_ENTER,
        ControlRight: e.SCANCODE_RCTRL,
        AudioVolumeMute: e.SCANCODE_AUDIOMUTE,
        MediaPlayPause: e.SCANCODE_AUDIOPLAY,
        MediaStop: e.SCANCODE_AUDIOSTOP,

        VolumeDown: e.SCANCODE_VOLUMEDOWN,
        VolumeUp: e.SCANCODE_VOLUMEUP,
        AudioVolumeDown: e.SCANCODE_VOLUMEDOWN,
        AudioVolumeUp: e.SCANCODE_VOLUMEUP,

        BrowserHome: e.SCANCODE_AC_HOME,
        NumpadDivide: e.SCANCODE_KP_DIVIDE,
        AltRight: e.SCANCODE_RALT,
        NumLock: e.SCANCODE_NUMLOCKCLEAR,
        Home: e.SCANCODE_HOME,
        ArrowUp: e.SCANCODE_UP,
        PageUp: e.SCANCODE_PAGEUP,
        ArrowLeft: e.SCANCODE_LEFT,
        ArrowRight: e.SCANCODE_RIGHT,
        End: e.SCANCODE_END,
        ArrowDown: e.SCANCODE_DOWN,
        PageDown: e.SCANCODE_PAGEDOWN,
        Insert: e.SCANCODE_INSERT,
        Delete: e.SCANCODE_DELETE,
        MetaLeft: e.SCANCODE_APPLICATION,
        MetaRight: e.SCANCODE_APPLICATION,
        OSLeft: e.SCANCODE_APPLICATION,
        OSRight: e.SCANCODE_APPLICATION,
        ContextMenu: e.SCANCODE_MENU,
        Power: e.SCANCODE_POWER,
        BrowserSearch: e.SCANCODE_AC_SEARCH,
        BrowserFavorites: e.SCANCODE_AC_BOOKMARKS,
        BrowserRefresh: e.SCANCODE_AC_REFRESH,
        BrowserStop: e.SCANCODE_AC_STOP,
        BrowserForward: e.SCANCODE_AC_FORWARD,
        BrowserBack: e.SCANCODE_AC_BACK,
        LaunchMediaPlayer: e.SCANCODE_MEDIASELECT,
        MediaSelect: e.SCANCODE_MEDIASELECT,
        LaunchApp1: e.SCANCODE_APP1,
        LaunchMail: e.SCANCODE_MAIL,
        Eject: e.SCANCODE_EJECT,
        LaunchApp2: e.SCANCODE_APP2,

        Cut: e.SCANCODE_CUT,
        Copy: e.SCANCODE_COPY,
        Help: e.SCANCODE_HELP,
        Select: e.SCANCODE_SELECT,
    };

    const codeMap = {};
    for (let key in codeMapPtrs) {
        codeMap[key] = new Uint16Array(e.memory.buffer, codeMapPtrs[key], 1)[0];
    }

    return codeMap;
}
