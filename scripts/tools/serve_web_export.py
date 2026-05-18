"""
Godot Web Export HTTP Server
Serves Godot web exports with required CORS/COOP/COEP headers.
Usage: python serve_web_export.py [port] [directory]
"""
import sys
import os
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "..", "exports", "web")
COPY_CHUNK_SIZE = 64 * 1024


class GodotWebHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    @staticmethod
    def _is_client_disconnect_error(exc):
        return isinstance(exc, (BrokenPipeError, ConnectionAbortedError, ConnectionResetError))

    @staticmethod
    def _is_ignorable_transfer_error(exc):
        return isinstance(exc, MemoryError) or GodotWebHandler._is_client_disconnect_error(exc)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        try:
            super().end_headers()
        except OSError as exc:
            if self._is_client_disconnect_error(exc):
                self.close_connection = True
                return
            raise

    def do_GET(self):
        try:
            super().do_GET()
        except (OSError, MemoryError) as exc:
            if self._is_ignorable_transfer_error(exc):
                self.close_connection = True
                return
            raise

    def do_HEAD(self):
        try:
            super().do_HEAD()
        except (OSError, MemoryError) as exc:
            if self._is_ignorable_transfer_error(exc):
                self.close_connection = True
                return
            raise

    def copyfile(self, source, outputfile):
        try:
            while True:
                chunk = source.read(COPY_CHUNK_SIZE)
                if not chunk:
                    break
                outputfile.write(chunk)
        except (OSError, MemoryError) as exc:
            if self._is_ignorable_transfer_error(exc):
                self.close_connection = True
                return
            raise

    def guess_type(self, path):
        if path.endswith(".wasm"):
            return "application/wasm"
        if path.endswith(".pck"):
            return "application/octet-stream"
        if path.endswith(".js"):
            return "application/javascript"
        return super().guess_type(path)


if __name__ == "__main__":
    os.makedirs(DIRECTORY, exist_ok=True)
    print(f"Serving Godot web export from: {os.path.abspath(DIRECTORY)}")
    print(f"Open http://localhost:{PORT} in your browser")
    ThreadingHTTPServer(("", PORT), GodotWebHandler).serve_forever()
