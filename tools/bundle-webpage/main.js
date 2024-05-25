function initialize() {
  let gl_context = null;
  let wasm_instance = null;

  let get_memory_fn = () => {
    return wasm_instance.exports.memory;
  };

  let get_wasm_instance_fn = () => {
    return wasm_instance;
  };

  let get_gl_context_fn = () => { return gl_context; };
  let set_gl_context_fn = (ctx) => { gl_context = ctx; };

  const importObject = {
    "wasi_snapshot_preview1": getWasiSnapshotPreview1WasmImport(get_memory_fn),
    "seizer": getSeizerWasmImport(get_memory_fn, set_gl_context_fn, get_wasm_instance_fn),
    "webgl2": getWebgl2WasmImport(get_memory_fn, get_gl_context_fn),
  };

  const z85_encoded_wasm_element = document.getElementById("z85-encoded-wasm");
  const wasm_json = JSON.parse(z85_encoded_wasm_element.text);

  const decoded_length = parseInt(z85_encoded_wasm_element.attributes["decoded-length"].value) ;
  const wasm_binary = new Uint8Array(decoded_length);

  z85_decode(wasm_json.data, wasm_binary);

  function animationFrameCallback(timestamp) {
    if (wasm_instance) {
      wasm_instance.exports._render();
    }
    window.requestAnimationFrame(animationFrameCallback);
  }

  WebAssembly.instantiate(wasm_binary, importObject).then(
    (results) => {
      wasm_instance = results.instance;
      wasm_instance.exports._initialize();
      window.requestAnimationFrame(animationFrameCallback);
    }
  );
}

initialize();
