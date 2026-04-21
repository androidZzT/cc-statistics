from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping
from uuid import uuid4

from .models import Event, EventType
from .state_store import BridgeStateStore


@dataclass
class StreamCollectorConfig:
    task_id: str
    session_id: str
    title: str
    repo: str = field(default_factory=lambda: str(Path.cwd()))


class ClaudeStreamJsonCollector:
    """Consume Claude Code stream-json lines and project them into bridge events."""

    def __init__(self, store: BridgeStateStore, config: StreamCollectorConfig) -> None:
        self._store = store
        self._cfg = config
        self._started = False
        self._ended = False
        self._model = ""

    def feed_line(self, line: str) -> list[Event]:
        raw = line.strip()
        if not raw:
            return []
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            return []
        if not isinstance(payload, dict):
            return []
        return self.feed_object(payload)

    def feed_object(self, payload: Mapping[str, Any]) -> list[Event]:
        emitted: list[Event] = []
        now = _extract_timestamp(payload) or datetime.now(timezone.utc)
        model = _extract_model(payload)
        if model:
            self._model = model

        if not self._started and _looks_like_start(payload):
            emitted.append(
                self._emit(
                    EventType.TASK_STARTED,
                    now,
                    {
                        "title": self._cfg.title,
                        "repo": self._cfg.repo,
                        "model": self._model,
                        "permission_mode": _extract_permission_mode(payload),
                    },
                )
            )
            self._started = True

        approval = _extract_approval(payload)
        if approval and not self._ended:
            if not self._started:
                emitted.append(
                    self._emit(
                        EventType.TASK_STARTED,
                        now,
                        {
                            "title": self._cfg.title,
                            "repo": self._cfg.repo,
                            "model": self._model,
                            "permission_mode": _extract_permission_mode(payload),
                        },
                    )
                )
                self._started = True
            emitted.append(self._emit(EventType.APPROVAL_REQUIRED, now, approval))

        if _looks_like_error(payload) and not self._ended:
            if not self._started:
                emitted.append(
                    self._emit(
                        EventType.TASK_STARTED,
                        now,
                        {"title": self._cfg.title, "repo": self._cfg.repo, "model": self._model},
                    )
                )
                self._started = True
            emitted.append(
                self._emit(
                    EventType.TASK_FAILED,
                    now,
                    {
                        "duration_sec": _extract_duration(payload),
                        "error_code": _extract_error_code(payload),
                        "error_message": _extract_error_message(payload),
                    },
                )
            )
            self._ended = True

        if _looks_like_progress(payload) and not self._ended and not approval:
            if not self._started:
                emitted.append(
                    self._emit(
                        EventType.TASK_STARTED,
                        now,
                        {"title": self._cfg.title, "repo": self._cfg.repo, "model": self._model},
                    )
                )
                self._started = True
            emitted.append(
                self._emit(
                    EventType.TASK_PROGRESS,
                    now,
                    {
                        "phase": _extract_phase(payload),
                        "summary": _extract_summary(payload),
                        "duration_sec": _extract_duration(payload),
                        "usage": _extract_usage(payload),
                        "last_tool": _extract_last_tool(payload),
                    },
                )
            )

        if _looks_like_complete(payload) and not self._ended:
            if not self._started:
                emitted.append(
                    self._emit(
                        EventType.TASK_STARTED,
                        now,
                        {"title": self._cfg.title, "repo": self._cfg.repo, "model": self._model},
                    )
                )
                self._started = True
            emitted.append(
                self._emit(
                    EventType.TASK_COMPLETED,
                    now,
                    {
                        "duration_sec": _extract_duration(payload),
                        "usage": _extract_usage(payload),
                        "result_summary": _extract_summary(payload),
                    },
                )
            )
            self._ended = True

        for event in emitted:
            self._store.apply_event(event)
        return emitted

    def _emit(self, event_type: EventType, ts: datetime, payload: dict[str, Any]) -> Event:
        event = Event(
            version=1,
            event_id=f"evt_{uuid4().hex}",
            type=event_type,
            task_id=self._cfg.task_id,
            session_id=self._cfg.session_id,
            timestamp=ts.astimezone(timezone.utc),
            payload=payload,
        )
        return event


def _extract_timestamp(payload: Mapping[str, Any]) -> datetime | None:
    for key in ("timestamp", "ts", "time"):
        value = payload.get(key)
        if isinstance(value, str):
            try:
                dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                continue
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
    return None


def _extract_model(payload: Mapping[str, Any]) -> str:
    for key in ("model", "model_name"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    meta = payload.get("meta")
    if isinstance(meta, Mapping):
        value = meta.get("model")
        if isinstance(value, str):
            return value
    return ""


def _extract_permission_mode(payload: Mapping[str, Any]) -> str:
    mode = payload.get("permission_mode")
    if isinstance(mode, str):
        return mode
    meta = payload.get("meta")
    if isinstance(meta, Mapping):
        mode = meta.get("permission_mode")
        if isinstance(mode, str):
            return mode
    return ""


def _extract_usage(payload: Mapping[str, Any]) -> dict[str, Any]:
    usage = payload.get("usage")
    if isinstance(usage, Mapping):
        return {
            "input_tokens": int(usage.get("input_tokens", 0) or 0),
            "output_tokens": int(usage.get("output_tokens", 0) or 0),
            "cost_usd": float(usage.get("cost_usd", 0.0) or 0.0),
        }
    return {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0}


def _extract_duration(payload: Mapping[str, Any]) -> int:
    for key in ("duration_sec", "duration_seconds", "elapsed_sec", "elapsed_seconds"):
        value = payload.get(key)
        if isinstance(value, (int, float)):
            return max(0, int(value))
    return 0


def _extract_phase(payload: Mapping[str, Any]) -> str:
    phase = payload.get("phase")
    if isinstance(phase, str):
        return phase
    event_type = str(payload.get("type", "")).lower()
    subtype = str(payload.get("subtype", "")).lower()
    text = f"{event_type}:{subtype}"
    if "tool" in text:
        return "tool_running"
    if "thinking" in text:
        return "thinking"
    if "assistant" in text or "message" in text:
        return "responding"
    return "running"


def _extract_summary(payload: Mapping[str, Any]) -> str:
    for key in ("summary", "message", "text", "result"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()[:180]
    content = payload.get("content")
    if isinstance(content, str) and content.strip():
        return content.strip()[:180]
    tool = _extract_last_tool(payload)
    if tool:
        cmd = str(tool.get("command_preview", "")).strip()
        name = str(tool.get("name", "")).strip()
        if cmd:
            return f"{name}: {cmd}"[:180]
        if name:
            return name[:180]
    return "Running task"


def _extract_last_tool(payload: Mapping[str, Any]) -> dict[str, Any]:
    tool = payload.get("tool")
    if isinstance(tool, Mapping):
        return {
            "name": str(tool.get("name", "")),
            "command_preview": str(tool.get("command") or tool.get("input") or ""),
            "status": str(tool.get("status", "running")),
        }
    tool_name = payload.get("tool_name")
    if isinstance(tool_name, str) and tool_name:
        tool_input = payload.get("tool_input")
        command_preview = ""
        if isinstance(tool_input, Mapping):
            command_preview = str(
                tool_input.get("command")
                or tool_input.get("file_path")
                or tool_input.get("description")
                or ""
            )
        return {
            "name": tool_name,
            "command_preview": command_preview,
            "status": "running",
        }
    return {}


def _extract_approval(payload: Mapping[str, Any]) -> dict[str, Any] | None:
    raw_type = str(payload.get("type", "")).lower()
    raw_event = str(payload.get("event", "")).lower()
    if payload.get("approval_required") is not True and "pretooluse" not in raw_event and "approval" not in raw_type:
        return None
    tool_name = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input")
    action = ""
    if isinstance(tool_input, Mapping):
        action = str(
            tool_input.get("command")
            or tool_input.get("file_path")
            or tool_input.get("description")
            or ""
        )
    if not action:
        action = str(payload.get("action") or "")
    approval_id = str(payload.get("approval_id") or payload.get("id") or f"apr_{uuid4().hex}")
    return {
        "approval_id": approval_id,
        "tool": tool_name or str(payload.get("tool") or "Unknown"),
        "action": action or "Action requires approval",
        "risk": str(payload.get("risk") or "medium"),
        "reason": str(payload.get("reason") or ""),
        "expires_in_sec": int(payload.get("expires_in_sec", 120) or 120),
    }


def _looks_like_start(payload: Mapping[str, Any]) -> bool:
    raw_type = str(payload.get("type", "")).lower()
    raw_subtype = str(payload.get("subtype", "")).lower()
    raw_event = str(payload.get("event", "")).lower()
    return any(
        token in {raw_type, raw_subtype, raw_event}
        for token in ("system/init", "init", "start", "started")
    )


def _looks_like_progress(payload: Mapping[str, Any]) -> bool:
    if payload.get("usage") is not None:
        return True
    raw_type = str(payload.get("type", "")).lower()
    raw_event = str(payload.get("event", "")).lower()
    return any(token in raw_type or token in raw_event for token in ("message", "assistant", "tool", "delta"))


def _looks_like_complete(payload: Mapping[str, Any]) -> bool:
    raw_type = str(payload.get("type", "")).lower()
    raw_subtype = str(payload.get("subtype", "")).lower()
    raw_event = str(payload.get("event", "")).lower()
    stop_reason = str(payload.get("stop_reason", "")).lower()
    return any(
        token in {raw_type, raw_subtype, raw_event, stop_reason}
        for token in ("task_completed", "completed", "done", "stop", "end_turn")
    )


def _looks_like_error(payload: Mapping[str, Any]) -> bool:
    if payload.get("error"):
        return True
    raw_type = str(payload.get("type", "")).lower()
    raw_event = str(payload.get("event", "")).lower()
    return "error" in raw_type or "error" in raw_event or "failed" in raw_type


def _extract_error_code(payload: Mapping[str, Any]) -> str:
    err = payload.get("error")
    if isinstance(err, Mapping):
        code = err.get("code")
        if isinstance(code, str):
            return code
    code = payload.get("error_code")
    if isinstance(code, str):
        return code
    return "unknown_error"


def _extract_error_message(payload: Mapping[str, Any]) -> str:
    err = payload.get("error")
    if isinstance(err, Mapping):
        msg = err.get("message")
        if isinstance(msg, str) and msg:
            return msg
    for key in ("error_message", "message", "summary"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return "Task failed"
