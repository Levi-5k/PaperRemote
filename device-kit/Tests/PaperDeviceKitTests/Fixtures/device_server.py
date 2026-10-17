import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


root = Path(sys.argv[1])
descriptor = (root / "protocol/fixtures/device-descriptor-v1-screenless.json").read_bytes()
profile = (root / "protocol/fixtures/remote-profile-v7-screenless.json").read_bytes()
controls = json.loads((root / "protocol/fixtures/device-descriptor-v1-controls.json").read_text())["controls"]
values = json.loads((root / "protocol/fixtures/device-controls-v1-snapshot.json").read_text())["values"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        return self.headers.get("Authorization") == "Bearer fixture-token"

    def controls_reply(self):
        self.reply(200, json.dumps({"values": values}).encode())

    def set_control(self):
        if not self.authorized():
            self.reply(401, b'{"ok":false,"error":"unauthorized"}')
            return
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        control = next((item for item in controls if item["id"] == request.get("id")), None)
        if control is None:
            self.reply(404, b'{"ok":false,"error":"unknown_control"}')
        elif control.get("readOnly"):
            self.reply(400, b'{"ok":false,"error":"read_only"}')
        elif control["kind"] == "action":
            self.reply(200, json.dumps({"ok": True, "values": values}).encode())
        elif control["kind"] == "range" and isinstance(request.get("value"), (int, float)) \
                and control["minimum"] <= request["value"] <= control["maximum"]:
            values[control["id"]] = request["value"]
            self.reply(200, json.dumps({"ok": True, "values": values}).encode())
        elif control["kind"] == "toggle" and isinstance(request.get("value"), bool):
            values[control["id"]] = request["value"]
            self.reply(200, json.dumps({"ok": True, "values": values}).encode())
        else:
            self.reply(400, b'{"ok":false,"error":"invalid_value"}')

    def do_GET(self):
        if self.path == "/device/controls":
            if self.authorized():
                self.controls_reply()
            else:
                self.reply(401, b'{"ok":false,"error":"unauthorized"}')
        elif self.path == "/device":
            self.reply(200, descriptor)
        elif self.path == "/remote" and self.headers.get("Authorization") == "Bearer fixture-token":
            self.reply(200, profile)
        else:
            self.reply(404, b'{"error":"not_found"}')

    def do_POST(self):
        global profile
        if self.path == "/device/controls":
            self.set_control()
            return
        if self.path != "/remote" or self.headers.get("Authorization") != "Bearer fixture-token":
            self.reply(401, b'{"error":"unauthorized"}')
            return
        count = int(self.headers.get("Content-Length", "0"))
        if not 0 < count <= 65536:
            self.reply(413, b'{"error":"too_large"}')
            return
        data = self.rfile.read(count)
        decoded = json.loads(data)
        if decoded.get("version") != 7:
            self.reply(400, b'{"error":"unsupported_profile"}')
            return
        if decoded.get("updatedAtMilliseconds") == 666:
            self.reply(200, b'{"ok":false,"error":"installation_failed"}')
            return
        profile = data
        self.reply(200, b'{"ok":true}')


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
