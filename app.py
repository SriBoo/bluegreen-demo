# import os
# from http.server import BaseHTTPRequestHandler, HTTPServer

# class H(BaseHTTPRequestHandler):
#     def do_GET(self):
#         self.send_response(200)
#         self.end_headers()
#         self.wfile.write(b"Hello Sri v1\n")

# port = int(os.environ.get("X_ZOHO_CATALYST_LISTEN_PORT", 9000))
# HTTPServer(("0.0.0.0", port), H).serve_forever()

import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if self.path == "/":
            version = os.environ.get("APP_VERSION", "v1")

            self.send_response(200)
            self.end_headers()
            self.wfile.write(
                f"Hello Ai {version}\n sample test is happening here.encode()
            )
            return

        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"Not Found\n")


port = int(
    os.environ.get(
        "X_ZOHO_CATALYST_LISTEN_PORT",
        9000
    )
)

HTTPServer(
    ("0.0.0.0", port),
    H
).serve_forever()