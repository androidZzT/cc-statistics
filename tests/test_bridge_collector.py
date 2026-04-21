from __future__ import annotations

from cc_stats.bridge.collector import ClaudeStreamJsonCollector, StreamCollectorConfig
from cc_stats.bridge.models import EventType, TaskStatus
from cc_stats.bridge.state_store import BridgeStateStore


def test_collector_emits_lifecycle_events() -> None:
    store = BridgeStateStore()
    collector = ClaudeStreamJsonCollector(
        store,
        StreamCollectorConfig(task_id="task_1", session_id="session_1", title="Fix bug"),
    )

    emitted = collector.feed_object({"type": "init", "model": "claude-sonnet-4-6"})
    assert [e.type for e in emitted] == [EventType.TASK_STARTED]

    emitted = collector.feed_object(
        {
            "type": "assistant",
            "summary": "Running tests",
            "duration_sec": 12,
            "usage": {"input_tokens": 50, "output_tokens": 20, "cost_usd": 0.01},
        }
    )
    assert [e.type for e in emitted] == [EventType.TASK_PROGRESS]

    emitted = collector.feed_object({"type": "completed", "summary": "Done"})
    assert [e.type for e in emitted] == [EventType.TASK_COMPLETED]

    task = store.list_tasks(limit=1)[0]
    assert task.status == TaskStatus.COMPLETED
    assert task.summary == "Done"


def test_collector_approval_event() -> None:
    store = BridgeStateStore()
    collector = ClaudeStreamJsonCollector(
        store,
        StreamCollectorConfig(task_id="task_2", session_id="session_2", title="Release"),
    )

    emitted = collector.feed_object(
        {
            "event": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "git push origin main"},
            "approval_required": True,
            "approval_id": "apr_123",
            "risk": "high",
        }
    )
    # start + approval_required
    assert [e.type for e in emitted] == [EventType.TASK_STARTED, EventType.APPROVAL_REQUIRED]

    pending = store.pending_approvals()
    assert len(pending) == 1
    assert pending[0].approval_id == "apr_123"
    assert pending[0].action == "git push origin main"
