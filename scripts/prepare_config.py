#!/usr/bin/env python3
"""Validate local configuration and generate build-only Swift/JavaScript resources."""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import urlsplit, urlunsplit
import uuid


def parse_configuration(path):
    config = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict) or set(config) != {"conversationURL"}:
        raise ValueError("Configuration must contain only conversationURL")
    if not isinstance(config["conversationURL"], str):
        raise ValueError("conversationURL must be a string")
    url = urlsplit(config["conversationURL"])
    if (url.scheme != "https" or url.hostname != "chatgpt.com"
            or url.username is not None or url.password is not None
            or url.port not in (None, 443) or url.query or url.fragment):
        raise ValueError("Use an HTTPS chatgpt.com conversation URL without credentials, query or fragment")
    match = re.fullmatch(r"/(?:g/[A-Za-z0-9_-]+/)?c/([A-Fa-f0-9-]{36})/?", url.path)
    if not match:
        raise ValueError("Expected /c/<conversation UUID> or /g/<project>/c/<conversation UUID>")
    conversation_id = str(uuid.UUID(match[1]))
    path = url.path.rstrip("/").rsplit("/", 1)[0] + "/" + conversation_id
    return conversation_id, urlunsplit(("https", "chatgpt.com", path, "", "")), path


def generate(config_path, output, template):
    conversation_id, url, path = parse_configuration(config_path)
    canonical = "https://chatgpt.com/c/" + conversation_id
    permitted = [url] if url == canonical else [url, canonical]
    swift = "// Generated from ignored local configuration. Do not commit.\n"
    swift += "enum EngineConfiguration {\n"
    for name, value in [("conversationID", conversation_id), ("conversationURL", url),
                        ("conversationPath", path), ("permittedURLs", permitted)]:
        swift += "    static let " + name + " = " + json.dumps(value) + "\n"
    swift += "}\n"
    bridge = template.read_text(encoding="utf-8")
    placeholder = "__TRANSLATEGPT_CONVERSATION_ID__"
    if bridge.count(placeholder) != 1:
        raise ValueError("Expected exactly one conversation placeholder in the bridge")
    output.mkdir(parents=True, exist_ok=True)
    (output / "EngineConfiguration.swift").write_text(swift, encoding="utf-8")
    (output / "SafariDOMBridge.js").write_text(bridge.replace(placeholder, conversation_id), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    template = Path(__file__).resolve().parents[1] / "Sources/SafariDOMBridge.js"
    try:
        generate(args.config, args.output, template)
    except (ValueError, OSError) as error:
        # Do not print the configured private URL or the raw JSON parse input.
        raise SystemExit("Configuration could not be prepared. Check Engine.example.json and use a valid conversation URL.") from None


if __name__ == "__main__":
    main()
