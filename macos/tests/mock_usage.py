"""Local stand-in for the usage endpoint (127.0.0.1 only). The path picks the reply:
/ok -> full usage JSON, /401, /429 (Retry-After: 90), /html (unexpected body), /redirect (302).
Every request's Authorization and anthropic-beta headers are appended to the file given as argv[2]."""
import http.server
import json
import sys

FULL = {
    "five_hour": {"utilization": 22.5, "resets_at": "2030-11-13T01:59:59.912345+00:00"},
    "seven_day": {"utilization": 61, "resets_at": "2030-11-19T02:59:41.5+00:00"},
    "seven_day_opus": {"utilization": 80, "resets_at": "2030-11-19T02:59:41+00:00"},
    "extra_usage": {"is_enabled": True, "monthly_limit": 5000, "used_credits": 1250, "utilization": 25.0},
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[2], "a") as f:
            f.write(f"{self.path} {self.headers.get('Authorization')} {self.headers.get('anthropic-beta')}\n")
        if self.path == "/ok":
            body, status, extra = json.dumps(FULL).encode(), 200, {}
        elif self.path == "/html":
            body, status, extra = b"<html>maintenance</html>", 200, {}
        elif self.path == "/redirect":
            body, status, extra = b"", 302, {"Location": "http://127.0.0.1:1/elsewhere"}
        elif self.path == "/429":
            body, status, extra = b"{}", 429, {"Retry-After": "90"}
        else:
            body, status, extra = b"{}", int(self.path.strip("/") or 500), {}
        self.send_response(status)
        for k, v in extra.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
