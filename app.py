import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Hello World v1\n")

port = int(os.environ.get("X_ZOHO_CATALYST_LISTEN_PORT", 9000))
HTTPServer(("0.0.0.0", port), H).serve_forever()