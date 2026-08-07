"""Codex 会话解析与发现测试"""

from __future__ import annotations

import json
from pathlib import Path

import cc_stats.parser as parser
from cc_stats.analyzer import analyze_session


def _write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def test_parse_codex_jsonl_and_analyze_tokens(tmp_path: Path) -> None:
    path = tmp_path / "rollout-2026-04-16T01-00-00-sess-1.jsonl"
    _write_jsonl(path, [
        {
            "timestamp": "2026-04-16T01:00:00Z",
            "type": "session_meta",
            "payload": {"id": "sess-1", "cwd": "/tmp/project-a"},
        },
        {
            "timestamp": "2026-04-16T01:00:01Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "请看一下"},
        },
        {
            "timestamp": "2026-04-16T01:00:02Z",
            "type": "response_item",
            "payload": {
                "type": "function_call",
                "name": "exec_command",
                "arguments": "{\"cmd\":\"echo hi\"}",
                "call_id": "call-1",
            },
        },
        {
            "timestamp": "2026-04-16T01:00:03Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 40,
                        "output_tokens": 10,
                    }
                },
            },
        },
        {
            "timestamp": "2026-04-16T01:00:04Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "done"},
        },
    ])

    session = parser.parse_codex_jsonl(path)
    assert session.source == "codex"
    assert session.session_id == "sess-1"
    assert session.project_path == "/tmp/project-a"

    stats = analyze_session(session)
    assert stats.user_message_count == 1
    assert stats.tool_call_total == 1
    assert stats.tool_call_counts.get("Bash") == 1
    assert stats.token_usage.input_tokens == 60
    assert stats.token_usage.cache_read_input_tokens == 40
    assert stats.token_usage.output_tokens == 10
    assert stats.token_usage.total == 110


def test_parse_codex_thread_settings_applied_models_token_usage(tmp_path: Path) -> None:
    path = tmp_path / "rollout-2026-07-23T01-00-00-thread-settings.jsonl"
    _write_jsonl(path, [
        {
            "timestamp": "2026-07-23T01:00:00Z",
            "type": "session_meta",
            "payload": {"id": "sess-thread-settings", "cwd": "/tmp/project-a"},
        },
        {
            "timestamp": "2026-07-23T01:00:01Z",
            "type": "event_msg",
            "payload": {
                "type": "thread_settings_applied",
                "thread_settings": {
                    "collaboration_mode": {"settings": {"model": "gpt-5.6-sol"}},
                },
            },
        },
        {
            "timestamp": "2026-07-23T01:00:02Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "working"},
        },
        {
            "timestamp": "2026-07-23T01:00:03Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": 120,
                        "cached_input_tokens": 20,
                        "output_tokens": 30,
                    }
                },
            },
        },
    ])

    stats = analyze_session(parser.parse_codex_jsonl(path))

    assert set(stats.token_by_model) == {"gpt-5.6-sol"}
    assert stats.token_by_model["gpt-5.6-sol"].total == 150


def test_parse_codex_backfills_leading_usage_when_session_has_one_model(tmp_path: Path) -> None:
    path = tmp_path / "rollout-2026-07-23T01-00-00-leading-usage.jsonl"
    _write_jsonl(path, [
        {
            "timestamp": "2026-07-23T01:00:00Z",
            "type": "session_meta",
            "payload": {"id": "sess-leading", "cwd": "/tmp/project-a"},
        },
        {
            "timestamp": "2026-07-23T01:00:01Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "historical reply"},
        },
        {
            "timestamp": "2026-07-23T01:00:02Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": 50,
                        "cached_input_tokens": 10,
                        "output_tokens": 5,
                    }
                },
            },
        },
        {
            "timestamp": "2026-07-23T01:00:03Z",
            "type": "event_msg",
            "payload": {
                "type": "thread_settings_applied",
                "thread_settings": {"model": "gpt-5.6-sol"},
            },
        },
        {
            "timestamp": "2026-07-23T01:00:04Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "current reply"},
        },
        {
            "timestamp": "2026-07-23T01:00:05Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": 80,
                        "cached_input_tokens": 20,
                        "output_tokens": 7,
                    }
                },
            },
        },
    ])

    stats = analyze_session(parser.parse_codex_jsonl(path))

    assert set(stats.token_by_model) == {"gpt-5.6-sol"}
    assert stats.token_by_model["gpt-5.6-sol"].total == 142


def test_parse_codex_keeps_leading_usage_unknown_when_multiple_models_seen(tmp_path: Path) -> None:
    path = tmp_path / "rollout-2026-07-23T01-00-00-multi-model.jsonl"
    _write_jsonl(path, [
        {
            "timestamp": "2026-07-23T01:00:00Z",
            "type": "session_meta",
            "payload": {"id": "sess-multi-model", "cwd": "/tmp/project-a"},
        },
        {
            "timestamp": "2026-07-23T01:00:01Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "historical reply"},
        },
        {
            "timestamp": "2026-07-23T01:00:02Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 20, "output_tokens": 2}},
            },
        },
        {
            "timestamp": "2026-07-23T01:00:03Z",
            "type": "event_msg",
            "payload": {"type": "thread_settings_applied", "thread_settings": {"model": "gpt-5.6-sol"}},
        },
        {
            "timestamp": "2026-07-23T01:00:04Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "first model"},
        },
        {
            "timestamp": "2026-07-23T01:00:05Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 30, "output_tokens": 3}},
            },
        },
        {
            "timestamp": "2026-07-23T01:00:06Z",
            "type": "turn_context",
            "payload": {"model": "gpt-5.5"},
        },
        {
            "timestamp": "2026-07-23T01:00:07Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "second model"},
        },
        {
            "timestamp": "2026-07-23T01:00:08Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 40, "output_tokens": 4}},
            },
        },
    ])

    stats = analyze_session(parser.parse_codex_jsonl(path))

    assert stats.token_by_model["unknown"].total == 22
    assert stats.token_by_model["gpt-5.6-sol"].total == 33
    assert stats.token_by_model["gpt-5.5"].total == 44


def test_parse_session_file_auto_detect_codex(tmp_path: Path) -> None:
    codex_file = tmp_path / "rollout-2026-04-16T00-00-00-test.jsonl"
    _write_jsonl(codex_file, [
        {
            "timestamp": "2026-04-16T01:00:00Z",
            "type": "session_meta",
            "payload": {"id": "auto-1", "cwd": "/tmp/project-a"},
        },
        {
            "timestamp": "2026-04-16T01:00:01Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "hi"},
        },
    ])

    session = parser.parse_session_file(codex_file)
    assert session.source == "codex"
    assert session.session_id == "auto-1"


def test_find_codex_sessions_and_keyword(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setattr(parser.Path, "home", classmethod(lambda cls: tmp_path))

    f1 = (
        tmp_path
        / ".codex"
        / "sessions"
        / "2026"
        / "04"
        / "16"
        / "rollout-2026-04-16T00-00-00-a.jsonl"
    )
    f2 = (
        tmp_path
        / ".codex"
        / "sessions"
        / "2026"
        / "04"
        / "16"
        / "rollout-2026-04-16T00-00-00-b.jsonl"
    )

    _write_jsonl(f1, [
        {
            "timestamp": "2026-04-16T01:00:00Z",
            "type": "session_meta",
            "payload": {"id": "a", "cwd": "/work/project-alpha"},
        },
        {
            "timestamp": "2026-04-16T01:00:01Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "keyword-foo"},
        },
    ])
    _write_jsonl(f2, [
        {
            "timestamp": "2026-04-16T01:00:00Z",
            "type": "session_meta",
            "payload": {"id": "b", "cwd": "/work/project-beta"},
        },
    ])

    all_files = parser.find_codex_sessions()
    assert all_files == [f1, f2]

    filtered = parser.find_codex_sessions(Path("/work/project-alpha"))
    assert filtered == [f1]

    by_project_keyword = parser.find_codex_sessions_by_keyword("project-beta")
    assert by_project_keyword == [f2]

    by_message_keyword = parser.find_codex_sessions_by_keyword("keyword-foo")
    assert by_message_keyword == [f1]
