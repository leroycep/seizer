function getSeizerWasmImport(getMemory, setGlContext, getWasmInstance) {
  const MAP_KEY_STRING_TO_NUMBER = {
      "Escape" : 1,
      "Digit1" : 2,
      "Digit2" : 3,
      "Digit3" : 4,
      "Digit4" : 5,
      "Digit5" : 6,
      "Digit6" : 7,
      "Digit7" : 8,
      "Digit8" : 9,
      "Digit9" : 10,
      "Digit0" : 11,

      "Minus" : 12,
      "Equal" : 13,
      "Backspace" : 14,
      "Tab" : 15,
      "KeyQ" : 16,
      "KeyW" : 17,
      "KeyE" : 18,
      "KeyR" : 19,
      "KeyT" : 20,
      "KeyY" : 21,
      "KeyU" : 22,
      "KeyI" : 23,
      "KeyO" : 24,
      "KeyP" : 25,
      "BracketLeft" : 26,
      "BracketRight" : 27,
      "Enter" : 28,
      "ControlLeft" : 29,
      "KeyA" : 30,
      "KeyS" : 31,
      "KeyD" : 32,
      "KeyF" : 33,
      "KeyG" : 34,
      "KeyH" : 35,
      "KeyJ" : 36,
      "KeyK" : 37,
      "KeyL" : 38,
      "Semicolon" : 39,
      "Quote" : 40,
      "Backquote" : 41,
      "ShiftLeft" : 42,
      "Backslash" : 43,
      "KeyZ" : 44,
      "KeyX" : 45,
      "KeyC" : 46,
      "KeyV" : 47,
      "KeyB" : 48,
      "KeyN" : 49,
      "KeyM" : 50,
      "Comma" : 51,
      "Period" : 52,
      "Slash" : 53,
      "ShiftRight" : 54,
      "NumpadMultiply" : 55,
      "AltLeft" : 56,
      "Space" : 57,
      "CapsLock" : 58,
      "F1" : 59,
      "F2" : 60,
      "F3" : 61,
      "F4" : 62,
      "F5" : 63,
      "F6" : 64,
      "F7" : 65,
      "F8" : 66,
      "F9" : 67,
      "F10" : 68,
      "NumLock" : 69,
      "ScrollLock" : 70,
      "Numpad7" : 71,
      "Numpad8" : 72,
      "Numpad9" : 73,
      "NumpadSubtract" : 74,
      "Numpad4" : 75,
      "Numpad5" : 76,
      "Numpad6" : 77,
      "NumpadAdd" : 78,
      "Numpad1" : 79,
      "Numpad2" : 80,
      "Numpad3" : 81,
      "Numpad0" : 82,
      "NumpadDecimal" : 83,

      "ArrowUp" : 103,
      "ArrowLeft" : 105,
      "ArrowRight" : 106,
      "ArrowDown" : 108,
  };

  const output_element = document.getElementById("output");
  let windows = {};
  let next_window_id = 4;

  return {
    create_surface: function(width, height) {
      window_id = next_window_id;
      next_window_id += 1;      

      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      canvas.tabIndex = 0;

      output_element.append(canvas);

      windows[window_id] = {
        canvas: canvas,
        gl: canvas.getContext("webgl2"),
        should_close: false,
      };

      canvas.addEventListener("keydown", (event) => {
        if (event.defaultPrevented) return;

        const key_code_number = MAP_KEY_STRING_TO_NUMBER[event.code];
        if (key_code_number === undefined) return;

        getWasmInstance().exports._key_event(window_id, key_code_number, true);
      }, true);
      canvas.addEventListener("keyup", (event) => {
        if (event.defaultPrevented) return;

        const key_code_number = MAP_KEY_STRING_TO_NUMBER[event.code];
        if (key_code_number === undefined) return;

        getWasmInstance().exports._key_event(window_id, key_code_number, false);
      }, true);

      return window_id;
    },
    surface_get_size: function(w_id, width_ptr, height_ptr) {
      const w = windows[w_id];

      const data_view = new DataView(getMemory().buffer);
      if (width_ptr) {
        data_view.setUint32(width_ptr, w.canvas.width, true);
      }
      if (height_ptr) {
        data_view.setUint32(height_ptr, w.canvas.height, true);
      }
    },
    surface_make_gl_context_current: function(w_id) {
      setGlContext(windows[w_id].gl);
    },
  }
}
