"""Regression tests for the standalone Orex update server.

Run with:
    python -m unittest discover -s tool -p "test_*.py"
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import update_server


class LatestPayloadTest(unittest.TestCase):
    def test_keeps_plus_literal_in_release_and_artifact_urls(self) -> None:
        version = "0.4.3"
        build = 6
        release_name = f"{version}+{build}"

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            release_directory = root / "debug" / release_name
            release_directory.mkdir(parents=True)
            for filename in (
                f"Orex-Setup-{release_name}.exe",
                f"app-arm64-v8a-{release_name}.apk",
                f"app-armeabi-v7a-{release_name}.apk",
            ):
                (release_directory / filename).write_bytes(b"artifact")
            (release_directory / "notes.md").write_text("Release notes", encoding="utf-8")

            with patch.object(update_server, "ROOT", root):
                payload = update_server.latest_payload("debug")

        self.assertIsNotNone(payload)
        assert payload is not None
        self.assertNotIn("%2B", str(payload))
        self.assertEqual(
            payload["notes_url"],
            "/updates/debug/0.4.3+6/notes.md",
        )
        self.assertEqual(
            payload["artifacts"],
            {
                "windows-x64": {
                    "url": "/updates/debug/0.4.3+6/Orex-Setup-0.4.3+6.exe",
                    "size_bytes": 8,
                },
                "android-arm64-v8a": {
                    "url": "/updates/debug/0.4.3+6/app-arm64-v8a-0.4.3+6.apk",
                    "size_bytes": 8,
                },
                "android-armeabi-v7a": {
                    "url": "/updates/debug/0.4.3+6/app-armeabi-v7a-0.4.3+6.apk",
                    "size_bytes": 8,
                },
            },
        )
