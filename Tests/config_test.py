#!/usr/bin/env python3
"""Offline configuration validation; no personal config is loaded."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_config", ROOT / "scripts/prepare_config.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ID = "00000000-0000-4000-8000-000000000001"


class ConfigurationTests(unittest.TestCase):
    def parse(self, url):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"conversationURL": url}))
            return module.parse_configuration(path)

    def test_supported_routes(self):
        for prefix in ["/c/", "/g/example-project/c/"]:
            identity, url, path = self.parse("https://chatgpt.com" + prefix + ID + "/")
            self.assertEqual(identity, ID)
            self.assertTrue(url.endswith(ID))
            self.assertTrue(path.endswith(ID))

    def test_unsafe_or_wrong_urls(self):
        for url in ["http://chatgpt.com/c/" + ID, "https://chatgpt.com.evil.invalid/c/" + ID,
                    "https://user@chatgpt.com/c/" + ID, "https://chatgpt.com:8443/c/" + ID,
                    "https://chatgpt.com/c/other?target=" + ID,
                    "https://chatgpt.com/c/" + ID + "#fragment", "https://chatgpt.com/c/not-a-uuid"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.parse(url)

    def test_generation_matches_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            module.generate(ROOT / "config/Engine.example.json", output, ROOT / "Sources/SafariDOMBridge.js")
            self.assertIn(ID, (output / "EngineConfiguration.swift").read_text())
            bridge = (output / "SafariDOMBridge.js").read_text()
            self.assertIn(ID, bridge)
            self.assertNotIn("__TRANSLATEGPT_CONVERSATION_ID__", bridge)


if __name__ == "__main__":
    unittest.main()
