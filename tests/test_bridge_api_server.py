from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone

from cc_stats.bridge.api_server import BridgeHTTPServer
from cc_stats.bridge.models import Event, EventType
from cc_stats.bridge.state_store import BridgeStateStore


def _start_server(store: BridgeStateStore) -> tuple[BridgeHTTPServer, threading.Thread, str]:
    server = BridgeHTTPServer(("127.0.0.1", 0), store)
    host, port = server.server_address
    base_url = f"http://{host}:{port}"
    th = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
    th.start()
    return server, th, base_url


def _stop_server(server: BridgeHTTPServer, th: threading.Thread) -> None:
    server.shutdown()
    server.server_close()
    th.join(timeout=2)


def _get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=2) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _post_json(url: str, payload: dict) -> tuple[int, dict]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def test_health_and_current_task_endpoint() -> None:
    store = BridgeStateStore()
    event = Event(
        version=1,
        event_id="evt_1",
        type=EventType.TASK_STARTED,
        task_id="task_1",
        session_id="session_1",
        timestamp=datetime.now(timezone.utc),
        payload={"title": "Task A", "repo": "/tmp/repo", "model": "claude-sonnet"},
    )
    store.apply_event(event)

    server, th, base_url = _start_server(store)
    try:
        assert _get_json(f"{base_url}/v1/health") == {"ok": True}
        current = _get_json(f"{base_url}/v1/tasks/current")
        assert current["task_id"] == "task_1"
        assert current["status"] == "RUNNING"
    finally:
        _stop_server(server, th)


def test_approval_resolve_endpoint() -> None:
    store = BridgeStateStore()
    store.apply_event(
        Event(
            version=1,
            event_id="evt_1",
            type=EventType.TASK_STARTED,
            task_id="task_1",
            session_id="session_1",
            timestamp=datetime.now(timezone.utc),
            payload={"title": "Task A"},
        )
    )
    store.apply_event(
        Event(
            version=1,
            event_id="evt_2",
            type=EventType.APPROVAL_REQUIRED,
            task_id="task_1",
            session_id="session_1",
            timestamp=datetime.now(timezone.utc),
            payload={
                "approval_id": "apr_1",
                "tool": "Bash",
                "action": "git push origin main",
                "risk": "high",
                "expires_in_sec": 120,
            },
        )
    )

    server, th, base_url = _start_server(store)
    try:
        status, body = _post_json(
            f"{base_url}/v1/approvals/apr_1:resolve",
            {
                "approved": True,
                "timestamp": "2026-04-18T08:00:10Z",
                "nonce": "n1",
                "signature": "s1",
            },
        )
        assert status == 200
        assert body["accepted"] is True
        assert body["event_id"].startswith("evt_")
        assert "effective_at" in body
        tail = list(store.events_since("evt_2"))
        assert len(tail) == 1
        assert tail[0].type == EventType.APPROVAL_RESOLVED
        assert tail[0].payload["approval_id"] == "apr_1"
        assert tail[0].payload["approved"] is True

        status, body = _post_json(
            f"{base_url}/v1/approvals/apr_1:resolve",
            {
                "approved": False,
                "timestamp": "2026-04-18T08:00:11Z",
                "nonce": "n2",
                "signature": "s2",
            },
        )
        assert status == 409
        assert body["accepted"] is False
    finally:
        _stop_server(server, th)


def test_get_approval_item_endpoint() -> None:
    store = BridgeStateStore()
    store.apply_event(
        Event(
            version=1,
            event_id="evt_1",
            type=EventType.TASK_STARTED,
            task_id="task_1",
            session_id="session_1",
            timestamp=datetime.now(timezone.utc),
            payload={"title": "Task A"},
        )
    )
    store.apply_event(
        Event(
            version=1,
            event_id="evt_2",
            type=EventType.APPROVAL_REQUIRED,
            task_id="task_1",
            session_id="session_1",
            timestamp=datetime.now(timezone.utc),
            payload={
                "approval_id": "apr_lookup_1",
                "tool": "Bash",
                "action": "rm -rf /tmp/demo",
                "risk": "high",
                "expires_in_sec": 120,
            },
        )
    )

    server, th, base_url = _start_server(store)
    try:
        item = _get_json(f"{base_url}/v1/approvals/apr_lookup_1")
        assert item["approval_id"] == "apr_lookup_1"
        assert item["resolved"] is False
        status, _ = _post_json(
            f"{base_url}/v1/approvals/apr_lookup_1:resolve",
            {"approved": True},
        )
        assert status == 200
        item = _get_json(f"{base_url}/v1/approvals/apr_lookup_1")
        assert item["resolved"] is True
        assert item["approved"] is True

        status, body = _post_json(f"{base_url}/v1/approvals/missing:resolve", {"approved": True})
        assert status == 409
        assert body["accepted"] is False
    finally:
        _stop_server(server, th)


def test_event_ingest_endpoint() -> None:
    store = BridgeStateStore()
    server, th, base_url = _start_server(store)
    try:
        status, body = _post_json(
            f"{base_url}/v1/events",
            {
                "version": 1,
                "event_id": "evt_100",
                "type": "task_started",
                "task_id": "task_100",
                "session_id": "session_100",
                "timestamp": "2026-04-18T08:00:00Z",
                "payload": {"title": "Ingested task"},
            },
        )
        assert status == 200
        assert body["accepted"] is True

        current = _get_json(f"{base_url}/v1/tasks/current")
        assert current["task_id"] == "task_100"
        assert current["title"] == "Ingested task"
    finally:
        _stop_server(server, th)
