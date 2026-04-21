from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Mapping


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class EventType(str, Enum):
    TASK_STARTED = "task_started"
    TASK_PROGRESS = "task_progress"
    APPROVAL_REQUIRED = "approval_required"
    APPROVAL_RESOLVED = "approval_resolved"
    TASK_COMPLETED = "task_completed"
    TASK_FAILED = "task_failed"
    TASK_CANCELED = "task_canceled"


class TaskStatus(str, Enum):
    IDLE = "IDLE"
    RUNNING = "RUNNING"
    WAITING_APPROVAL = "WAITING_APPROVAL"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    CANCELED = "CANCELED"


class RiskLevel(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


@dataclass(frozen=True)
class Usage:
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any] | None) -> "Usage":
        if not data:
            return cls()
        return cls(
            input_tokens=max(0, int(data.get("input_tokens", 0) or 0)),
            output_tokens=max(0, int(data.get("output_tokens", 0) or 0)),
            cost_usd=max(0.0, float(data.get("cost_usd", 0.0) or 0.0)),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cost_usd": self.cost_usd,
        }


@dataclass(frozen=True)
class Event:
    version: int
    event_id: str
    type: EventType
    task_id: str
    session_id: str
    timestamp: datetime
    source: str = "bridge"
    payload: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "Event":
        event_type = EventType(str(data.get("type", "")))
        ts = data.get("timestamp")
        if isinstance(ts, datetime):
            timestamp = ts
        elif isinstance(ts, str):
            normalized = ts.replace("Z", "+00:00")
            timestamp = datetime.fromisoformat(normalized)
        else:
            timestamp = utc_now()
        if timestamp.tzinfo is None:
            timestamp = timestamp.replace(tzinfo=timezone.utc)
        return cls(
            version=int(data.get("version", 1)),
            event_id=str(data["event_id"]),
            type=event_type,
            task_id=str(data["task_id"]),
            session_id=str(data.get("session_id", "")),
            timestamp=timestamp.astimezone(timezone.utc),
            source=str(data.get("source", "bridge")),
            payload=dict(data.get("payload", {}) or {}),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "event_id": self.event_id,
            "type": self.type.value,
            "task_id": self.task_id,
            "session_id": self.session_id,
            "timestamp": self.timestamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "source": self.source,
            "payload": self.payload,
        }


@dataclass
class TaskSnapshot:
    task_id: str
    session_id: str
    title: str
    repo: str = ""
    model: str = ""
    status: TaskStatus = TaskStatus.RUNNING
    phase: str = ""
    summary: str = ""
    duration_sec: int = 0
    usage: Usage = field(default_factory=Usage)
    started_at: datetime = field(default_factory=utc_now)
    updated_at: datetime = field(default_factory=utc_now)
    error_message: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "session_id": self.session_id,
            "title": self.title,
            "repo": self.repo,
            "model": self.model,
            "status": self.status.value,
            "phase": self.phase,
            "summary": self.summary,
            "duration_sec": self.duration_sec,
            "usage": self.usage.to_dict(),
            "started_at": self.started_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "updated_at": self.updated_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "error_message": self.error_message,
        }


@dataclass
class ApprovalItem:
    approval_id: str
    task_id: str
    tool: str
    action: str
    risk: RiskLevel
    reason: str = ""
    expires_at: datetime = field(default_factory=utc_now)
    resolved: bool = False
    approved: bool | None = None
    resolved_at: datetime | None = None

    def to_dict(self) -> dict[str, Any]:
        out = {
            "approval_id": self.approval_id,
            "task_id": self.task_id,
            "tool": self.tool,
            "action": self.action,
            "risk": self.risk.value,
            "reason": self.reason,
            "expires_at": self.expires_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "resolved": self.resolved,
            "approved": self.approved,
        }
        if self.resolved_at is not None:
            out["resolved_at"] = self.resolved_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        return out
