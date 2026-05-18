import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "tools" / "serve_web_export.py"
spec = importlib.util.spec_from_file_location("serve_web_export", MODULE_PATH)
serve_web_export = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(serve_web_export)


class HandlerDisconnectTests(unittest.TestCase):
    def test_end_headers_disables_cache(self):
        handler = object.__new__(serve_web_export.GodotWebHandler)
        handler.close_connection = False
        recorded = []
        handler.send_header = lambda key, value: recorded.append((key, value))
        original = serve_web_export.SimpleHTTPRequestHandler.end_headers
        serve_web_export.SimpleHTTPRequestHandler.end_headers = lambda self: None
        try:
            handler.end_headers()
        finally:
            serve_web_export.SimpleHTTPRequestHandler.end_headers = original

        self.assertIn(("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0"), recorded)
        self.assertIn(("Pragma", "no-cache"), recorded)
        self.assertIn(("Expires", "0"), recorded)

    def test_end_headers_swallows_client_disconnect(self):
        handler = object.__new__(serve_web_export.GodotWebHandler)
        handler.close_connection = False
        handler.send_header = lambda *args, **kwargs: None
        original = serve_web_export.SimpleHTTPRequestHandler.end_headers
        serve_web_export.SimpleHTTPRequestHandler.end_headers = lambda self: (_ for _ in ()).throw(ConnectionAbortedError(10053, "aborted"))
        try:
            handler.end_headers()
        finally:
            serve_web_export.SimpleHTTPRequestHandler.end_headers = original

        self.assertTrue(handler.close_connection)

    def test_do_get_swallows_client_disconnect(self):
        handler = object.__new__(serve_web_export.GodotWebHandler)
        handler.close_connection = False
        original = serve_web_export.SimpleHTTPRequestHandler.do_GET
        serve_web_export.SimpleHTTPRequestHandler.do_GET = lambda self: (_ for _ in ()).throw(ConnectionAbortedError(10053, "aborted"))
        try:
            handler.do_GET()
        finally:
            serve_web_export.SimpleHTTPRequestHandler.do_GET = original

        self.assertTrue(handler.close_connection)

    def test_do_get_swallows_memory_error(self):
        handler = object.__new__(serve_web_export.GodotWebHandler)
        handler.close_connection = False
        original = serve_web_export.SimpleHTTPRequestHandler.do_GET
        serve_web_export.SimpleHTTPRequestHandler.do_GET = lambda self: (_ for _ in ()).throw(MemoryError())
        try:
            handler.do_GET()
        finally:
            serve_web_export.SimpleHTTPRequestHandler.do_GET = original

        self.assertTrue(handler.close_connection)


if __name__ == "__main__":
    unittest.main()
