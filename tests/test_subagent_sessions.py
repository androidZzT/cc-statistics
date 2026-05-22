from __future__ import annotations

import json
from pathlib import Path

from cc_stats.analyzer import analyze_session
from cc_stats.parser import find_sessions, parse_jsonl


def _assistant_line(
    *,
    timestamp: str,
    message_id: str,
    cwd: str,
    input_tokens: int,
    output_tokens: int,
) -> str:
    return json.dumps({
        "type": "assistant",
        "timestamp": timestamp,
        "cwd": cwd,
        "sessionId": "session-1",
        "message": {
            "id": message_id,
            "model": "gpt-5.5",
            "content": [{"type": "text", "text": "ok"}],
            "usage": {
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
            },
        },
    })


def test_parent_session_merges_subagent_messages(tmp_path: Path) -> None:
    project = tmp_path / ".claude" / "projects" / "-tmp-project"
    parent = project / "parent-session.jsonl"
    subagent = project / "parent-session" / "subagents" / "agent-a.jsonl"
    subagent.parent.mkdir(parents=True)
    parent.write_text(
        _assistant_line(
            timestamp="2026-05-22T01:00:00Z",
            message_id="msg-parent",
            cwd="/tmp/project",
            input_tokens=100,
            output_tokens=10,
        )
        + "\n",
        encoding="utf-8",
    )
    subagent.write_text(
        _assistant_line(
            timestamp="2026-05-22T01:01:00Z",
            message_id="msg-subagent",
            cwd="/tmp/project/.claude/worktrees/agent-a",
            input_tokens=200,
            output_tokens=20,
        )
        + "\n",
        encoding="utf-8",
    )

    session = parse_jsonl(parent)
    stats = analyze_session(session)

    assert stats.token_usage.input_tokens == 300
    assert stats.token_usage.output_tokens == 30
    assert stats.token_by_model["gpt-5.5"].total == 330


def test_find_sessions_returns_parent_not_merged_subagent(
    tmp_path: Path,
    monkeypatch,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    project = tmp_path / ".claude" / "projects" / "-tmp-project"
    parent = project / "parent-session.jsonl"
    subagent = project / "parent-session" / "subagents" / "agent-a.jsonl"
    subagent.parent.mkdir(parents=True)
    parent.write_text(
        _assistant_line(
            timestamp="2026-05-22T01:00:00Z",
            message_id="msg-parent",
            cwd="/tmp/project",
            input_tokens=100,
            output_tokens=10,
        )
        + "\n",
        encoding="utf-8",
    )
    subagent.write_text(
        _assistant_line(
            timestamp="2026-05-22T01:01:00Z",
            message_id="msg-subagent",
            cwd="/tmp/project/.claude/worktrees/agent-a",
            input_tokens=200,
            output_tokens=20,
        )
        + "\n",
        encoding="utf-8",
    )

    assert find_sessions() == [parent]


def test_find_sessions_includes_orphan_subagent(
    tmp_path: Path,
    monkeypatch,
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    project = tmp_path / ".claude" / "projects" / "-tmp-project"
    subagent = project / "orphan-session" / "subagents" / "agent-a.jsonl"
    subagent.parent.mkdir(parents=True)
    subagent.write_text(
        _assistant_line(
            timestamp="2026-05-22T01:01:00Z",
            message_id="msg-subagent",
            cwd="/tmp/project/.claude/worktrees/agent-a",
            input_tokens=200,
            output_tokens=20,
        )
        + "\n",
        encoding="utf-8",
    )

    assert find_sessions() == [subagent]
