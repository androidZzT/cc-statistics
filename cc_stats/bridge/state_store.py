from __future__ import annotations

from collections import deque
from datetime import datetime, timedelta, timezone
from threading import RLock
from typing import Iterable
from uuid import uuid4

from .models import ApprovalItem, Event, EventType, RiskLevel, TaskSnapshot, TaskStatus, Usage, utc_now


class BridgeStateStore:
    """In-memory state for task timeline and approval queue."""

    def __init__(self, max_events: int = 5000) -> None:
        self._lock = RLock()
        self._events: deque[Event] = deque(maxlen=max_events)
        self._tasks: dict[str, TaskSnapshot] = {}
        self._task_order: deque[str] = deque()
        self._approvals: dict[str, ApprovalItem] = {}
        self._current_task_id: str | None = None

    def apply_event(self, event: Event) -> None:
        with self._lock:
            self._events.append(event)
            handler = {
                EventType.TASK_STARTED: self._on_task_started,
                EventType.TASK_PROGRESS: self._on_task_progress,
                EventType.APPROVAL_REQUIRED: self._on_approval_required,
                EventType.APPROVAL_RESOLVED: self._on_approval_resolved,
                EventType.TASK_COMPLETED: self._on_task_completed,
                EventType.TASK_FAILED: self._on_task_failed,
                EventType.TASK_CANCELED: self._on_task_canceled,
            }.get(event.type)
            if handler:
                handler(event)

    def current_task(self) -> TaskSnapshot | None:
        with self._lock:
            if not self._current_task_id:
                return None
            return self._tasks.get(self._current_task_id)

    def list_tasks(self, limit: int = 20) -> list[TaskSnapshot]:
        with self._lock:
            ids = list(self._task_order)[-max(1, limit) :]
            ids.reverse()
            return [self._tasks[task_id] for task_id in ids if task_id in self._tasks]

    def pending_approvals(self) -> list[ApprovalItem]:
        with self._lock:
            self._expire_stale_approvals_locked()
            return [item for item in self._approvals.values() if not item.resolved]

    def get_approval(self, approval_id: str) -> ApprovalItem | None:
        with self._lock:
            self._expire_stale_approvals_locked()
            return self._approvals.get(approval_id)

    def resolve_approval(self, approval_id: str, approved: bool, resolved_at: datetime | None = None) -> bool:
        with self._lock:
            self._expire_stale_approvals_locked()
            now = (resolved_at or utc_now()).astimezone(timezone.utc)
            accepted, _ = self._resolve_approval_locked(approval_id, approved, now)
            return accepted

    def resolve_approval_with_event(
        self,
        approval_id: str,
        approved: bool,
        *,
        source: str = "api",
        resolver: str = "ios_device",
        resolved_at: datetime | None = None,
    ) -> Event | None:
        with self._lock:
            self._expire_stale_approvals_locked()
            now = (resolved_at or utc_now()).astimezone(timezone.utc)
            accepted, item = self._resolve_approval_locked(approval_id, approved, now)
            if not accepted or item is None:
                return None
            task = self._tasks.get(item.task_id)
            event = Event(
                version=1,
                event_id=f"evt_{uuid4().hex}",
                type=EventType.APPROVAL_RESOLVED,
                task_id=item.task_id,
                session_id=task.session_id if task else "",
                timestamp=now,
                source=source,
                payload={
                    "approval_id": approval_id,
                    "approved": approved,
                    "resolved_by": resolver,
                    "resolved_at": now.isoformat().replace("+00:00", "Z"),
                },
            )
            self._events.append(event)
            return event

    def events_since(self, event_id: str | None = None) -> Iterable[Event]:
        with self._lock:
            if not event_id:
                return list(self._events)
            events = list(self._events)
            for idx, event in enumerate(events):
                if event.event_id == event_id:
                    return events[idx + 1 :]
            return events

    def _expire_stale_approvals_locked(self) -> None:
        now = utc_now().astimezone(timezone.utc)
        for item in self._approvals.values():
            if item.resolved:
                continue
            if now <= item.expires_at:
                continue
            item.resolved = True
            item.approved = False
            item.resolved_at = now
            task = self._tasks.get(item.task_id)
            if task and task.status == TaskStatus.WAITING_APPROVAL:
                task.status = TaskStatus.FAILED
                task.phase = "failed"
                task.error_message = "Approval timeout."
                task.summary = task.error_message
                task.updated_at = now

    def _resolve_approval_locked(
        self,
        approval_id: str,
        approved: bool,
        now: datetime,
    ) -> tuple[bool, ApprovalItem | None]:
        item = self._approvals.get(approval_id)
        if item is None or item.resolved:
            return False, item
        if now > item.expires_at:
            item.resolved = True
            item.approved = False
            item.resolved_at = now
            return False, item
        item.resolved = True
        item.approved = approved
        item.resolved_at = now
        task = self._tasks.get(item.task_id)
        if task:
            task.updated_at = now
            task.status = TaskStatus.RUNNING if approved else TaskStatus.FAILED
            if approved:
                task.error_message = ""
            else:
                task.error_message = "Approval rejected by user."
                task.summary = task.error_message
        return True, item

    def _get_or_create_task(self, event: Event) -> TaskSnapshot:
        task = self._tasks.get(event.task_id)
        if task is not None:
            return task
        task = TaskSnapshot(
            task_id=event.task_id,
            session_id=event.session_id,
            title=str(event.payload.get("title", "Untitled task")),
            repo=str(event.payload.get("repo", "")),
            model=str(event.payload.get("model", "")),
            status=TaskStatus.RUNNING,
            started_at=event.timestamp,
            updated_at=event.timestamp,
        )
        self._tasks[event.task_id] = task
        self._task_order.append(event.task_id)
        return task

    def _on_task_started(self, event: Event) -> None:
        task = self._get_or_create_task(event)
        task.title = str(event.payload.get("title", task.title))
        task.repo = str(event.payload.get("repo", task.repo))
        task.model = str(event.payload.get("model", task.model))
        task.status = TaskStatus.RUNNING
        task.phase = ""
        task.summary = ""
        task.updated_at = event.timestamp
        self._current_task_id = event.task_id

    def _on_task_progress(self, event: Event) -> None:
        task = self._get_or_create_task(event)
        task.phase = str(event.payload.get("phase", task.phase))
        task.summary = str(event.payload.get("summary", task.summary))
        task.duration_sec = max(0, int(event.payload.get("duration_sec", task.duration_sec) or 0))
        task.usage = Usage.from_mapping(event.payload.get("usage"))
        task.updated_at = event.timestamp

    def _on_approval_required(self, event: Event) -> None:
        task = self._get_or_create_task(event)
        task.status = TaskStatus.WAITING_APPROVAL
        task.phase = "waiting_user"
        task.summary = str(event.payload.get("action", task.summary))
        task.updated_at = event.timestamp

        raw_risk = str(event.payload.get("risk", RiskLevel.MEDIUM.value))
        try:
            risk = RiskLevel(raw_risk)
        except ValueError:
            risk = RiskLevel.MEDIUM
        expires_in_sec = max(1, int(event.payload.get("expires_in_sec", 120) or 120))
        approval_id = str(event.payload.get("approval_id", ""))
        if not approval_id:
            return
        self._approvals[approval_id] = ApprovalItem(
            approval_id=approval_id,
            task_id=event.task_id,
            tool=str(event.payload.get("tool", "")),
            action=str(event.payload.get("action", "")),
            risk=risk,
            reason=str(event.payload.get("reason", "")),
            expires_at=event.timestamp + timedelta(seconds=expires_in_sec),
        )

    def _on_approval_resolved(self, event: Event) -> None:
        approval_id = str(event.payload.get("approval_id", ""))
        approved = bool(event.payload.get("approved", False))
        self._resolve_approval_locked(approval_id, approved, event.timestamp)

    def _on_task_completed(self, event: Event) -> None:
        task = self._get_or_create_task(event)
        task.status = TaskStatus.COMPLETED
        task.phase = "completed"
        task.duration_sec = max(0, int(event.payload.get("duration_sec", task.duration_sec) or 0))
        task.summary = str(event.payload.get("result_summary", task.summary))
        task.usage = Usage.from_mapping(event.payload.get("usage"))
        task.updated_at = event.timestamp
        if self._current_task_id == event.task_id:
            self._current_task_id = None

    def _on_task_failed(self, event: Event) -> None:
        task = self._get_or_create_task(event)
        task.status = TaskStatus.FAILED
        task.phase = "failed"
        task.duration_sec = max(0, int(event.payload.get("duration_sec", task.duration_sec) or 0))
        task.error_message = str(event.payload.get("error_message", task.error_message))
        task.summary = task.error_message or task.summary
        task.updated_at = event.timestamp
        if self._current_task_id == event.task_id:
            self._current_task_id = None

    def _on_task_canceled(self, event: Event) -> None:
        task = self._get_or_create_task(event)
        task.status = TaskStatus.CANCELED
        task.phase = "canceled"
        task.updated_at = event.timestamp
        if self._current_task_id == event.task_id:
            self._current_task_id = None
