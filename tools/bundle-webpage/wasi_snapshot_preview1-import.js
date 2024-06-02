function getWasiSnapshotPreview1WasmImport(getMemory) {
  const ERR = {
    SUCCESS: 0,
    BADF: 8,
    INVAL: 28,
    IO: 29,
  };

  let text_decoder = new TextDecoder();
  let stderr_buffer = "";

  return {
    "proc_exit": function (exit_code) {
      throw ("Main function exited with code " + exit_code);
    },
    "fd_write": function (fd, iovs_ptr, iovs_len, nwritten_ptr) {
      const data_view = new DataView(getMemory().buffer);
      var bytes_written = 0;
      if (fd == 2) {
        for (let i = 0; i < iovs_len; i += 1) {
          const iov_ptr = data_view.getUint32(iovs_ptr + i * 8, true);
          const iov_len = data_view.getUint32(iovs_ptr + i * 8 + 4, true);
          if (iov_ptr + iov_len > getMemory().buffer.byteLength) {
            return ERR.IO;
          }
          const iov = new Uint8Array(getMemory().buffer, iov_ptr, iov_len);
          bytes_written += iov_len;
          stderr_buffer = stderr_buffer + text_decoder.decode(iov);
        }
        console.log(stderr_buffer);
        stderr_buffer = "";
        data_view.setUint32(nwritten_ptr, bytes_written, true);
        return 0;
      }
      return ERR.SUCCESS;
    },
    "fd_read": function (fd, arg1, arg2, arg3) {
      console.log("fd_read(" + fd + ", " + arg1 + ", " + arg2 + ", " + arg3 + ")");
      return -1;
    },
    "fd_close": function (fd) {
      console.log("fd_close(" + fd + ")");
      return -1;
    },
    "path_open": function (arg0, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8) {
      console.log("path_open(" + arg0 + ", " + arg1 + ", " + arg2 + ", " + arg3 + ", " + arg4 + ", " + arg5 + ", " + arg6 + ", " + arg7 + ", " + arg8 + ")");
      return -1;
    },
    "fd_seek": function (fd) {
      throw "unimplemented";
    },
    "fd_filestat_get": function (fd) {
      throw "unimplemented";
    },
    clock_time_get: function(id, precision, timeOut) {
      const view = new DataView(getMemory().buffer);
      if (id === 0) {
        const now = new Date().getTime();

        view.setUint32(timeOut, (now * 1000000.0) % 0x100000000, true);
        view.setUint32(timeOut + 4, (now * 1000000.0) / 0x100000000, true);

        return ERR.SUCCESS;
      } else if (id === 1) {
        const now = window.performance.now();

        view.setUint32(timeOut, (now * 1000.0) % 0x100000000, true);
        view.setUint32(timeOut + 4, (now * 1000.0) / 0x100000000, true);

        return ERR.SUCCESS;
      } else {
        return ERR.INVAL;
      }
    },
  };
}
