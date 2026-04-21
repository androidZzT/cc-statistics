from __future__ import annotations

from datetime import datetime, timedelta, timezone

from cc_stats.bridge.models import Event, EventType, TaskStatus
from cc_stats.bridge.state_store import BridgeStateStore

_BASE_TS = datetime.now(timezone.utc).replace(microsecond=0)


def _ts(second: int) -> datetime:
    return _BASE_TS + timedelta(seconds=second)


def _event(event_id: str, event_type: EventType, payload: dict) -> Event:
    return Event(
        version=1,
        event_id=event_id,
        type=event_type,
        task_id="task_1",
        session_id="session_1",
        timestamp=_ts(int(event_id.split("_")[-1])),
        payload=payload,
    )


def test_task_lifecycle_completed() -> None:
    store = BridgeStateStore()

    store.apply_event(
        _event(
            "evt_01",
            EventType.TASK_STARTED,
            {"title": "Run tests", "repo": "/tmp/repo", "model": "claude-sonnet-4-6"},
        )
    )
    store.apply_event(
        _event(
            "evt_02",
            EventType.TASK_PROGRESS,
            {
                "phase": "tool_running",
                "summary": "Running pytest -q",
                "duration_sec": 15,
                "usage": {"input_tokens": 100, "output_tokens": 50, "cost_usd": 0.01},
            },
        )
    )
    store.apply_event(
        _event(
            "evt_03",
            EventType.TASK_COMPLETED,
            {
                "duration_sec": 32,
                "result_summary": "All tests passed",
                "usage": {"input_tokens": 240, "output_tokens": 120, "cost_usd": 0.02},
            },
        )
    )

    task = store.list_tasks(limit=1)[0]
    assert task.status == TaskStatus.COMPLETED
    assert task.duration_sec == 32
    assert task.summary == "All tests passed"
    assert task.usage.input_tokens == 240
    assert store.current_task() is None


def test_approval_approve_flow_returns_to_running() -> None:
    store = BridgeStateStore()
    store.apply_event(_event("evt_01", EventType.TASK_STARTED, {"title": "Publish release"}))
    store.apply_event(
        _event(
            "evt_02",
            EventType.APPROVAL_REQUIRED,
            {
                "approval_id": "apr_1",
                "tool": "Bash",
                "action": "git push origin main",
                "risk": "high",
                "expires_in_sec": 120,
            },
        )
    )
    task = store.current_task()
    assert task is not None
    assert task.status == TaskStatus.WAITING_APPROVAL
    assert len(store.pending_approvals()) == 1

    store.apply_event(
        _event(
            "evt_03",
            EventType.APPROVAL_RESOLVED,
            {"approval_id": "apr_1", "approved": True},
        )
    )
    task = store.current_task()
    assert task is not None
    assert task.status == TaskStatus.RUNNING
    assert len(store.pending_approvals()) == 0


def test_approval_reject_flow_marks_failed() -> None:
    store = BridgeStateStore()
    store.apply_event(_event("evt_01", EventType.TASK_STARTED, {"title": "Dangerous step"}))
    store.apply_event(
        _event(
            "evt_02",
            EventType.APPROVAL_REQUIRED,
            {
                "approval_id": "apr_2",
                "tool": "Bash",
                "action": "rm -rf /",
                "risk": "high",
            },
        )
    )
    store.apply_event(
        _event(
            "evt_03",
            EventType.APPROVAL_RESOLVED,
            {"approval_id": "apr_2", "approved": False},
        )
    )

    task = store.current_task()
    assert task is not None
    assert task.status == TaskStatus.FAILED
    assert task.error_message == "Approval rejected by user."


def test_events_since_event_id() -> None:
    store = BridgeStateStore()
    for idx in range(1, 5):
        store.apply_event(_event(f"evt_{idx:02d}", EventType.TASK_PROGRESS, {"duration_sec": idx}))

    tail = list(store.events_since("evt_02"))
    assert [event.event_id for event in tail] == ["evt_03", "evt_04"]


def test_resolve_approval_with_event_appends_timeline_event() -> None:
    store = BridgeStateStore()
    store.apply_event(_event("evt_01", EventType.TASK_STARTED, {"title": "Publish release"}))
    store.apply_event(
        _event(
            "evt_02",
            EventType.APPROVAL_REQUIRED,
            {
                "approval_id": "apr_42",
                "tool": "Bash",
                "action": "git push origin main",
                "risk": "high",
                "expires_in_sec": 120,
            },
        )
    )

    evt = store.resolve_approval_with_event("apr_42", approved=True, resolver="ios_device")
    assert evt is not None
    assert evt.type == EventType.APPROVAL_RESOLVED
    assert evt.payload["approval_id"] == "apr_42"
    assert evt.payload["approved"] is True
    assert evt.payload["resolved_by"] == "ios_device"
