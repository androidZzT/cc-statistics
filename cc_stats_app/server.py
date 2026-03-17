"""轻量 HTTP 服务器：提供 Web 静态文件 + JSON API"""

from __future__ import annotations

import json
import os
import socket
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

from .api import Api

_api = Api()
_web_dir = os.path.join(os.path.dirname(__file__), "web")


class ApiHandler(SimpleHTTPRequestHandler):
    """处理 API 请求和静态文件"""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=_web_dir, **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/api/projects":
            self._json_response(_api.get_projects())
        elif path == "/api/stats":
            project = params.get("project", [None])[0]
            days = params.get("days", [None])[0]
            last_n = params.get("last_n", [None])[0]
            result = _api.get_stats(
                project_dir_name=project if project else None,
                last_n=int(last_n) if last_n else None,
                since_days=int(days) if days and days != "0" else None,
            )
            self._json_response(result)
        elif path == "/api/daily_stats":
            project = params.get("project", [None])[0]
            days = params.get("days", ["30"])[0]
            result = _api.get_daily_stats(
                project_dir_name=project if project else None,
                days=int(days),
            )
            self._json_response(result)
        else:
            super().do_GET()

    def _json_response(self, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # 静默日志
        pass


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_server() -> tuple[HTTPServer, int]:
    """启动服务器，返回 (server, port)"""
    port = find_free_port()
    server = HTTPServer(("127.0.0.1", port), ApiHandler)
    return server, port
