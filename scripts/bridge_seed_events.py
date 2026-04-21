#!/usr/bin/env python3
"""Seed demo events into cc-stats-bridge for iOS Dynamic Island testing."""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from datetime import datetime, timezone
from uuid import uuid4


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _post(base_url: str, payload: dict) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/events",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=3) as resp:
        if resp.status // 100 != 2:
            raise RuntimeError(f"unexpected status: {resp.status}")


def _emit(base_url: str, event_type: str, task_id: str, session_id: str, payload: dict) -> None:
    event = {
        "version": 1,
        "event_id": f"evt_{uuid4().hex}",
        "type": event_type,
        "task_id": task_id,
        "session_id": session_id,
        "timestamp": _now_iso(),
        "source": "seed",
        "payload": payload,
    }
    _post(base_url, event)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Seed demo task events into bridge")
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--task-id", default=f"task_{uuid4().hex[:8]}")
    parser.add_argument("--session-id", default=f"session_{uuid4().hex[:8]}")
    parser.add_argument("--title", default="Fix failing CI")
    parser.add_argument("--repo", default="/Users/dev/repo")
    args = parser.parse_args(argv)

    try:
        _emit(
            args.base_url,
            "task_started",
            args.task_id,
            args.session_id,
            {
                "title": args.title,
                "repo": args.repo,
                "model": "claude-sonnet-4-6",
                "permission_mode": "default",
            },
        )
        time.sleep(0.4)
        _emit(
            args.base_url,
            "task_progress",
            args.task_id,
            args.session_id,
            {
                "phase": "tool_running",
                "summary": "Running pytest -q",
                "duration_sec": 9,
                "usage": {"input_tokens": 420, "output_tokens": 130, "cost_usd": 0.0123},
                "last_tool": {"name": "Bash", "command_preview": "pytest -q", "status": "running"},
            },
        )
        time.sleep(0.4)
        _emit(
            args.base_url,
            "approval_required",
            args.task_id,
            args.session_id,
            {
                "approval_id": "apr_seed",
                "tool": "Bash",
                "action": "git push origin main",
                "risk": "high",
                "reason": "Write to remote",
                "expires_in_sec": 120,
            },
        )
    except Exception as exc:
        print(f"seed failed: {exc}", file=sys.stderr)
        return 1

    print(f"seeded task={args.task_id} session={args.session_id} approval_id=apr_seed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
