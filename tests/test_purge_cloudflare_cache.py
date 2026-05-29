import importlib.util
import json
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "tools" / "purge_cloudflare_cache.py"
spec = importlib.util.spec_from_file_location("purge_cloudflare_cache", MODULE_PATH)
purge_cloudflare_cache = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(purge_cloudflare_cache)


class PurgeCloudflareCacheTests(unittest.TestCase):
    def test_build_purge_urls_includes_root_and_export_files(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            export_dir = pathlib.Path(tmp_dir)
            (export_dir / "index.html").write_text("html", encoding="utf-8")
            (export_dir / "index.js").write_text("js", encoding="utf-8")
            (export_dir / "index.pck").write_text("pck", encoding="utf-8")
            (export_dir / "index.wasm").write_text("wasm", encoding="utf-8")
            (export_dir / "index.png.import").write_text("ignored", encoding="utf-8")

            urls = purge_cloudflare_cache.build_purge_urls("https://ptcg4npg.us.cc/", export_dir)

        self.assertEqual(urls[0], "https://ptcg4npg.us.cc/")
        self.assertIn("https://ptcg4npg.us.cc/index.html", urls)
        self.assertIn("https://ptcg4npg.us.cc/index.js", urls)
        self.assertIn("https://ptcg4npg.us.cc/index.pck", urls)
        self.assertIn("https://ptcg4npg.us.cc/index.wasm", urls)
        self.assertNotIn("https://ptcg4npg.us.cc/index.png.import", urls)

    def test_purge_cloudflare_cache_posts_expected_payload(self):
        captured = {}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"success": true, "result": {"id": "job"}}'

        def fake_urlopen(req, timeout=0):
            captured["url"] = req.full_url
            captured["headers"] = dict(req.header_items())
            captured["body"] = req.data.decode("utf-8")
            captured["timeout"] = timeout
            return FakeResponse()

        original = purge_cloudflare_cache.request.urlopen
        purge_cloudflare_cache.request.urlopen = fake_urlopen
        try:
            result = purge_cloudflare_cache.purge_cloudflare_cache(
                zone_id="zone123",
                api_token="token456",
                urls=["https://ptcg4npg.us.cc/", "https://ptcg4npg.us.cc/index.pck"],
            )
        finally:
            purge_cloudflare_cache.request.urlopen = original

        self.assertEqual(captured["url"], "https://api.cloudflare.com/client/v4/zones/zone123/purge_cache")
        self.assertEqual(captured["headers"]["Authorization"], "Bearer token456")
        self.assertEqual(json.loads(captured["body"]), {
            "files": [
                "https://ptcg4npg.us.cc/",
                "https://ptcg4npg.us.cc/index.pck",
            ]
        })
        self.assertEqual(result["result"]["id"], "job")

    def test_purge_cloudflare_cache_requires_urls_without_purge_everything(self):
        with self.assertRaises(ValueError):
            purge_cloudflare_cache.purge_cloudflare_cache(
                zone_id="zone123",
                api_token="token456",
                urls=[],
            )


if __name__ == "__main__":
    unittest.main()