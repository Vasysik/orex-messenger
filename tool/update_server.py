#!/usr/bin/env python3
"""Tiny read-only Orex update feed and artifact server.

The release operator only creates versioned directories under stable/debug and
uploads the known installer filenames. latest.json is generated on every request.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(os.environ.get("OREX_UPDATES_ROOT", "/srv/updates")).resolve()
HOST = os.environ.get("OREX_UPDATES_HOST", "0.0.0.0")
PORT = int(os.environ.get("OREX_UPDATES_PORT", "8080"))
CHANNELS = frozenset({"stable", "debug"})
RELEASE_RE = re.compile(r"^(?P<version>\d+\.\d+\.\d+)\+(?P<build>[1-9]\d*)$")
MAX_NOTES_BYTES = 256 * 1024


@dataclass(frozen=True)
class Release:
    channel: str
    directory: Path
    version: str
    build: int

    @property
    def folder_name(self) -> str:
        return f"{self.version}+{self.build}"

    def known_artifacts(self) -> dict[str, Path]:
        version = self.folder_name
        candidates = {
            "windows-x64": self.directory / f"Orex-Setup-{version}.exe",
            "android-arm64-v8a": self.directory
            / f"app-arm64-v8a-{version}.apk",
            "android-armeabi-v7a": self.directory
            / f"app-armeabi-v7a-{version}.apk",
        }
        return {key: path for key, path in candidates.items() if path.is_file()}

    def notes_path(self) -> Path | None:
        path = self.directory / "notes.md"
        if not path.is_file() or path.stat().st_size > MAX_NOTES_BYTES:
            return None
        return path


def _channel_root(channel: str) -> Path:
    if channel not in CHANNELS:
        raise ValueError("unknown update channel")
    return ROOT / channel


def discover_latest(channel: str) -> Release | None:
    root = _channel_root(channel)
    if not root.is_dir():
        return None
    releases: list[Release] = []
    for directory in root.iterdir():
        if not directory.is_dir() or directory.is_symlink():
            continue
        match = RELEASE_RE.fullmatch(directory.name)
        if match is None:
            continue
        release = Release(
            channel=channel,
            directory=directory,
            version=match.group("version"),
            build=int(match.group("build")),
        )
        if len(release.known_artifacts()) == 3:
            releases.append(release)
    if not releases:
        return None
    return max(
        releases,
        key=lambda item: (
            item.build,
            tuple(int(part) for part in item.version.split(".")),
        ),
    )


def latest_payload(channel: str) -> dict[str, object] | None:
    release = discover_latest(channel)
    if release is None:
        return None
    # A plus is part of the public `<version>+<build>` release identifier.
    # Keep it literal so the generated URLs match the update feed contract
    # consumed by the client (rather than emitting `%2B`).
    prefix = f"/updates/{quote(channel)}/{quote(release.folder_name, safe='+')}"
    artifacts: dict[str, dict[str, object]] = {}
    for key, path in release.known_artifacts().items():
        artifacts[key] = {
            "url": f"{prefix}/{quote(path.name, safe='+')}",
            "size_bytes": path.stat().st_size,
        }
    payload: dict[str, object] = {
        "version": release.version,
        "build": release.build,
        "artifacts": artifacts,
    }
    notes = release.notes_path()
    if notes is not None:
        payload["notes_url"] = f"{prefix}/notes.md"
    return payload


def resolve_public_file(channel: str, release_name: str, filename: str) -> Path | None:
    if channel not in CHANNELS or RELEASE_RE.fullmatch(release_name) is None:
        return None
    if filename in {"", ".", ".."} or Path(filename).name != filename:
        return None
    release_dir = (_channel_root(channel) / release_name).resolve()
    try:
        release_dir.relative_to(ROOT)
    except ValueError:
        return None
    if not release_dir.is_dir() or release_dir.is_symlink():
        return None
    match = RELEASE_RE.fullmatch(release_name)
    assert match is not None
    version = release_name
    allowed = {
        f"Orex-Setup-{version}.exe",
        f"app-arm64-v8a-{version}.apk",
        f"app-armeabi-v7a-{version}.apk",
        "notes.md",
    }
    if filename not in allowed:
        return None
    path = (release_dir / filename).resolve()
    try:
        path.relative_to(release_dir)
    except ValueError:
        return None
    if not path.is_file() or path.is_symlink():
        return None
    if filename == "notes.md" and path.stat().st_size > MAX_NOTES_BYTES:
        return None
    return path


class OrexUpdateHandler(BaseHTTPRequestHandler):
    server_version = "OrexUpdateFeed/1.0"

    def do_HEAD(self) -> None:  # noqa: N802
        self._handle(send_body=False)

    def do_GET(self) -> None:  # noqa: N802
        self._handle(send_body=True)

    def _handle(self, *, send_body: bool) -> None:
        parts = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
        if len(parts) == 3 and parts[0] == "updates" and parts[2] == "latest.json":
            self._serve_latest(parts[1], send_body=send_body)
            return
        if len(parts) == 4 and parts[0] == "updates":
            self._serve_file(parts[1], parts[2], parts[3], send_body=send_body)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def _serve_latest(self, channel: str, *, send_body: bool) -> None:
        try:
            payload = latest_payload(channel)
        except ValueError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        if payload is None:
            self.send_error(HTTPStatus.NOT_FOUND, "No release in this channel")
            return
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        )
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def _serve_file(
        self,
        channel: str,
        release_name: str,
        filename: str,
        *,
        send_body: bool,
    ) -> None:
        path = resolve_public_file(channel, release_name, filename)
        if path is None:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        size = path.stat().st_size
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        if path.name == "notes.md":
            content_type = "text/markdown; charset=utf-8"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        self.send_header("X-Content-Type-Options", "nosniff")
        if path.name != "notes.md":
            self.send_header(
                "Content-Disposition",
                f"attachment; filename*=UTF-8''{quote(path.name)}",
            )
        self.end_headers()
        if not send_body:
            return
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                self.wfile.write(chunk)

    def log_message(self, format: str, *args: object) -> None:
        print(f"[orex-updates] {self.address_string()} {format % args}", flush=True)


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), OrexUpdateHandler)
    print(f"Orex update server: http://{HOST}:{PORT}/updates/<channel>/latest.json")
    print(f"Release root: {ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
