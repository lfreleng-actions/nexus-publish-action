#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Minimal mock of a Nexus upload endpoint for action testing.

Accepts ``PUT`` and ``POST`` uploads on any path and appends one line per
request, in arrival order, to the file named by ``MOCK_LOG``::

    PUT /content/repositories/snapshots/org/example/a.jar auth=yes

``auth`` records whether an ``Authorization`` header arrived; the header
value itself is never logged.

``MOCK_RESPONSES`` holds a JSON object mapping a path suffix to a list of
responses served on successive requests for a matching path. The final
entry repeats once the list runs out. An entry is either an HTTP status
code, ``"drop"``, which closes the connection without replying so that
curl reports an empty reply (exit 52), or ``"partial:<code>"``, which
sends that status with a truncated body and closes the connection, so
curl fails after receiving the status (exit 18). Unmatched paths
receive 201.

The server binds an ephemeral port on 127.0.0.1 and writes it to the file
named by ``MOCK_PORT_FILE``; the socket is already listening by then.
"""

import json
import os
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ.get("MOCK_LOG", "/tmp/nexus_publish_requests.log")
PORT_FILE = os.environ.get("MOCK_PORT_FILE", "/tmp/nexus_publish_mock.port")
RESPONSES: dict[str, list[int | str]] = json.loads(
    os.environ.get("MOCK_RESPONSES", "{}")
)

# Requests seen so far per matched suffix, to step through RESPONSES
HITS: defaultdict[str, int] = defaultdict(int)


def _log(line: str) -> None:
    with open(LOG, "a", encoding="utf-8") as handle:
        _ = handle.write(line + "\n")


def _next_response(path: str) -> int | str:
    for suffix, sequence in RESPONSES.items():
        if path.endswith(suffix):
            index = min(HITS[suffix], len(sequence) - 1)
            HITS[suffix] += 1
            return sequence[index]
    return 201


class Handler(BaseHTTPRequestHandler):
    """Record uploads and answer with the scripted response."""

    def _handle_upload(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            _ = self.rfile.read(length)
        auth = "yes" if self.headers.get("Authorization") else "no"
        _log(f"{self.command} {self.path} auth={auth}")

        response = _next_response(self.path)
        if response == "drop":
            self.close_connection = True
            return
        if isinstance(response, str) and response.startswith("partial:"):
            self.send_response(int(response.split(":", 1)[1]))
            self.send_header("Content-Length", "1000")
            self.end_headers()
            _ = self.wfile.write(b"<status>")
            self.close_connection = True
            return
        code = int(response)
        payload = f"<status>{code}</status>".encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        _ = self.wfile.write(payload)

    def do_PUT(self) -> None:
        self._handle_upload()

    def do_POST(self) -> None:
        self._handle_upload()

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    open(LOG, "w", encoding="utf-8").close()
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(PORT_FILE, "w", encoding="utf-8") as handle:
        _ = handle.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
