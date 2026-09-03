#!/usr/bin/env python3
"""Minimal Supervisor API used by the container SIGKILL integration test."""

from __future__ import annotations

import json
import os
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


STATE_DIR = Path(os.environ["STATE_DIR"])
ADDON_WATCHDOG = os.environ.get("ADDON_WATCHDOG", "true") == "true"
LOCK = threading.Lock()


def state_path(name: str) -> Path:
    return STATE_DIR / name


def read_state(name: str, default: str) -> str:
    path = state_path(name)
    return path.read_text(encoding="utf-8").strip() if path.exists() else default


def write_state(name: str, value: str) -> None:
    state_path(name).write_text(f"{value}\n", encoding="utf-8")


def record_action(action: str) -> None:
    with LOCK, state_path("actions.log").open("a", encoding="utf-8") as actions:
        actions.write(f"{action}\n")


class SupervisorHandler(BaseHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        _ = (_format, _args)
        return

    def send_api_response(
        self, data: object, status: HTTPStatus = HTTPStatus.OK
    ) -> None:
        body = json.dumps({"result": "ok", "data": data}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path

        if path == "/ready":
            self.send_api_response({"ready": True})
        elif path == "/addons/self/options/config":
            options = json.loads(
                state_path("options.json").read_text(encoding="utf-8")
            )
            self.send_api_response(options)
        elif path == "/addons/self/info":
            self.send_api_response(
                {"state": "started", "watchdog": ADDON_WATCHDOG}
            )
        elif path == "/addons":
            self.send_api_response({"addons": []})
        elif path == "/core/info":
            self.send_api_response(
                {
                    "state": read_state("core-state", "running"),
                    "watchdog": read_state("core-watchdog", "true") == "true",
                }
            )
        elif path in {"/core/api", "/core/api/"}:
            status = (
                HTTPStatus.OK
                if read_state("core-state", "running") == "running"
                else HTTPStatus.SERVICE_UNAVAILABLE
            )
            self.send_api_response({}, status)
        else:
            self.send_api_response({}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        content_length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(content_length).decode() if content_length else ""

        if path == "/core/stop":
            write_state("core-state", "stopped")
            record_action("POST /core/stop")
        elif path == "/core/start":
            write_state("core-state", "running")
            record_action("POST /core/start")
        elif path == "/core/options":
            options = json.loads(payload or "{}")
            if "watchdog" in options:
                value = "true" if options["watchdog"] else "false"
                write_state("core-watchdog", value)
                record_action(f'POST /core/options {{"watchdog":{value}}}')
        else:
            self.send_api_response({}, HTTPStatus.NOT_FOUND)
            return

        self.send_api_response({})


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    write_state("core-state", read_state("core-state", "running"))
    write_state("core-watchdog", read_state("core-watchdog", "true"))
    state_path("actions.log").touch()
    ThreadingHTTPServer(("0.0.0.0", 80), SupervisorHandler).serve_forever()


if __name__ == "__main__":
    main()