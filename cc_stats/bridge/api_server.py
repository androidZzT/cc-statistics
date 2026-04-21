from __future__ import annotations

import json
import re
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socket import timeout as SocketTimeout
from typing import Any
from urllib.parse import parse_qs, urlparse

from .state_store import BridgeStateStore

_APPROVAL_RESOLVE_RE = re.compile(r"^/v1/approvals/([^/]+):resolve$")
_APPROVAL_ITEM_RE = re.compile(r"^/v1/approvals/([^/:]+)$")


class BridgeHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], store: BridgeStateStore) -> None:
        super().__init__(server_address, BridgeHTTPRequestHandler)
        self.store = store


class BridgeHTTPRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/v1/health":
            self._write_json({"ok": True}, HTTPStatus.OK)
            return

        if path == "/v1/tasks/current":
            task = self.server.store.current_task()  # type: ignore[attr-defined]
            self._write_json(task.to_dict() if task else {}, HTTPStatus.OK)
            return

        if path == "/v1/tasks":
            params = parse_qs(parsed.query)
            limit = _safe_int(params.get("limit", ["20"])[0], default=20, minimum=1, maximum=200)
            tasks = [task.to_dict() for task in self.server.store.list_tasks(limit=limit)]  # type: ignore[attr-defined]
            self._write_json({"tasks": tasks}, HTTPStatus.OK)
            return

        if path == "/v1/approvals":
            items = [item.to_dict() for item in self.server.store.pending_approvals()]  # type: ignore[attr-defined]
            self._write_json({"items": items}, HTTPStatus.OK)
            return

        approval_match = _APPROVAL_ITEM_RE.match(path)
        if approval_match:
            approval_id = approval_match.group(1)
            item = self.server.store.get_approval(approval_id)  # type: ignore[attr-defined]
            if item is None:
                self._write_json({"error": "not_found"}, HTTPStatus.NOT_FOUND)
                return
            self._write_json(item.to_dict(), HTTPStatus.OK)
            return

        if path == "/v1/events/stream":
            self._handle_sse_stream()
            return

        self._write_json({"error": "not_found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/v1/events":
            self._handle_ingest_event()
            return
        matched = _APPROVAL_RESOLVE_RE.match(parsed.path)
        if not matched:
            self._write_json({"error": "not_found"}, HTTPStatus.NOT_FOUND)
            return
        approval_id = matched.group(1)

        body = self._read_json_body()
        if body is None:
            self._write_json({"error": "invalid_json"}, HTTPStatus.UNPROCESSABLE_ENTITY)
            return

        approved = body.get("approved")
        if not isinstance(approved, bool):
            self._write_json({"error": "approved_must_be_boolean"}, HTTPStatus.UNPROCESSABLE_ENTITY)
            return

        resolver = body.get("resolver")
        resolver_name = resolver if isinstance(resolver, str) and resolver.strip() else "ios_device"
        resolved_at = _parse_timestamp(body.get("timestamp"))
        event = self.server.store.resolve_approval_with_event(  # type: ignore[attr-defined]
            approval_id,
            approved,
            source="api",
            resolver=resolver_name,
            resolved_at=resolved_at,
        )
        if event is None:
            self._write_json(
                {"accepted": False, "approval_id": approval_id, "approved": approved},
                HTTPStatus.CONFLICT,
            )
            return

        self._write_json(
            {
                "accepted": True,
                "approval_id": approval_id,
                "approved": approved,
                "event_id": event.event_id,
                "effective_at": event.timestamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            },
            HTTPStatus.OK,
        )

    def _handle_ingest_event(self) -> None:
        body = self._read_json_body()
        if body is None:
            self._write_json({"error": "invalid_json"}, HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        required = ("event_id", "type", "task_id")
        if not all(body.get(key) for key in required):
            self._write_json({"error": "missing_required_fields"}, HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        try:
            from .models import Event

            event = Event.from_mapping(body)
        except (KeyError, ValueError):
            self._write_json({"error": "invalid_event"}, HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.server.store.apply_event(event)  # type: ignore[attr-defined]
        self._write_json({"accepted": True, "event_id": event.event_id}, HTTPStatus.OK)

    def _handle_sse_stream(self) -> None:
        store: BridgeStateStore = self.server.store  # type: ignore[attr-defined]
        last_id = self.headers.get("Last-Event-ID")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        self.connection.settimeout(2.0)
        sent_ids: set[str] = set()
        if last_id:
            sent_ids.add(last_id)

        try:
            while True:
                # keepalive ping
                self.wfile.write(b": ping\n\n")
                self.wfile.flush()

                for event in store.events_since(last_id):
                    if event.event_id in sent_ids:
                        continue
                    payload = json.dumps(event.to_dict(), ensure_ascii=False, separators=(",", ":"))
                    self.wfile.write(f"id: {event.event_id}\n".encode("utf-8"))
                    self.wfile.write(f"event: {event.type.value}\n".encode("utf-8"))
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    last_id = event.event_id
                    sent_ids.add(event.event_id)
                    if len(sent_ids) > 2000:
                        sent_ids.clear()
                        if last_id:
                            sent_ids.add(last_id)
                time.sleep(1.0)
        except (BrokenPipeError, ConnectionResetError, SocketTimeout):
            return

    def _read_json_body(self) -> dict[str, Any] | None:
        raw_len = self.headers.get("Content-Length")
        if not raw_len:
            return {}
        try:
            length = int(raw_len)
        except (TypeError, ValueError):
            return None
        if length < 0 or length > 2 * 1024 * 1024:
            return None
        body = self.rfile.read(length)
        try:
            parsed = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        if not isinstance(parsed, dict):
            return None
        return parsed

    def _write_json(self, data: dict[str, Any], status: HTTPStatus) -> None:
        payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: Any) -> None:
        # Keep daemon stdout clean for users; logs can be added later.
        return


def _safe_int(raw: str, *, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, value))


def _parse_timestamp(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)
