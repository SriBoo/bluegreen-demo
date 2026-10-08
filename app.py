import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Set by deploy.ps1 for local Blue-Green containers. On Catalyst AppSail
# APP_COLOR is unset, so the response stays "Hello Ai <version>".
VERSION = os.environ.get("APP_VERSION", "v1")
COLOR = os.environ.get("APP_COLOR", "")


class H(BaseHTTPRequestHandler):

    def _send(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("X-App-Version", VERSION)
        if COLOR:
            self.send_header("X-App-Color", COLOR)
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):

        if self.path == "/health":
            self._send(200, "ok\n")
            return

        if self.path == "/":
            suffix = f" ({COLOR})" if COLOR else ""
            self._send(200, f"Hello Ai {VERSION}{suffix}\n now we are using zoho catalyst pipeline")
            return

        self._send(404, "Not Found\n")


# Exit cleanly on "docker stop" (python as PID 1 ignores SIGTERM otherwise).
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

port = int(
    os.environ.get(
        "X_ZOHO_CATALYST_LISTEN_PORT",
        9000
    )
)

ThreadingHTTPServer(
    ("0.0.0.0", port),
    H
).serve_forever()
