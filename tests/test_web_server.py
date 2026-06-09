from __future__ import annotations

import json
import threading
import urllib.request
from pathlib import Path

from cc_stats.analyzer import SessionStats, TokenUsage
from cc_stats_web.server import (
    _collect_session_files,
    _get_projects,
    _get_stats,
    start_server,
    _stats_to_dict,
)


def _write_jsonl(path: Path, records: list[dict]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")
    return path


def _write_codex_session(codex_home: Path, name: str, cwd: Path) -> Path:
    path = (
        codex_home
        / "sessions"
        / "2026"
        / "06"
        / "09"
        / f"rollout-2026-06-09T00-00-00-{name}.jsonl"
    )
    return _write_jsonl(path, [
        {
            "timestamp": "2026-06-09T00:00:00Z",
            "type": "session_meta",
            "payload": {
                "id": name,
                "cwd": str(cwd),
                "model": "gpt-5.3-codex",
            },
        },
        {
            "timestamp": "2026-06-09T00:00:01Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "hi"},
        },
        {
            "timestamp": "2026-06-09T00:00:02Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "hello"},
        },
        {
            "timestamp": "2026-06-09T00:00:03Z",
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
    ])


def _write_gemini_session(gemini_home: Path, name: str, cwd: Path) -> Path:
    path = gemini_home / "tmp" / "session-a" / "chats" / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({
            "sessionId": name,
            "directories": [str(cwd)],
            "messages": [
                {
                    "type": "user",
                    "timestamp": "2026-06-09T00:00:00Z",
                    "content": "hello",
                }
            ],
        }),
        encoding="utf-8",
    )
    return path


def _write_claude_session(claude_projects: Path, project_name: str, cwd: Path) -> Path:
    path = claude_projects / project_name / "session-a.jsonl"
    return _write_jsonl(path, [
        {
            "type": "user",
            "timestamp": "2026-06-09T00:00:00Z",
            "cwd": str(cwd),
            "sessionId": f"{project_name}-session",
            "message": {"content": "hello"},
        }
    ])


def _set_source_homes(monkeypatch, tmp_path: Path) -> tuple[Path, Path, Path]:
    claude_projects = tmp_path / "synthetic-claude" / "projects"
    codex_home = tmp_path / "synthetic-codex"
    gemini_home = tmp_path / "synthetic-gemini"
    monkeypatch.setenv("CC_STATS_CLAUDE_PROJECTS_DIR", str(claude_projects))
    monkeypatch.setenv("CC_STATS_CODEX_HOME", str(codex_home))
    monkeypatch.setenv("CC_STATS_GEMINI_HOME", str(gemini_home))
    monkeypatch.setenv("HOME", str(tmp_path / "unused-real-home"))
    return claude_projects, codex_home, gemini_home


def test_get_projects_source_codex_includes_codex_project(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    project_dir = tmp_path / "demo"
    _write_codex_session(codex_home, "codex-a", project_dir)

    projects = _get_projects(source="codex")

    assert projects == [{
        "dir_name": str(project_dir),
        "display_name": str(project_dir),
        "session_count": 1,
        "source": "codex",
    }]


def test_health_endpoint_returns_ok() -> None:
    server, port = start_server()
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": 0.1},
        daemon=True,
    )
    thread.start()

    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=2) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    assert payload == {"status": "ok"}


def test_collect_session_files_source_codex_returns_codex_file(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    codex_file = _write_codex_session(codex_home, "codex-a", tmp_path / "demo")

    files = _collect_session_files(source="codex")

    assert files == [codex_file]


def test_get_stats_source_codex_parses_user_message_and_token_usage(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    _write_codex_session(codex_home, "codex-a", tmp_path / "demo")

    stats = _get_stats(source="codex")

    assert stats["session_count"] == 1
    assert stats["user_message_count"] == 1
    assert stats["token_usage"]["input_tokens"] == 60
    assert stats["token_usage"]["cache_read"] == 40
    assert stats["token_usage"]["output_tokens"] == 10
    assert stats["token_usage"]["total"] == 110


def test_source_filter_excludes_other_sources_for_web_helpers(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, gemini_home = _set_source_homes(monkeypatch, tmp_path)
    project_dir = tmp_path / "demo"
    codex_file = _write_codex_session(codex_home, "codex-a", project_dir)
    gemini_file = _write_gemini_session(gemini_home, "gemini-a", project_dir)

    files = _collect_session_files(source="codex")
    projects = _get_projects(source="codex")

    assert files == [codex_file]
    assert gemini_file not in files
    assert {project["source"] for project in projects} == {"codex"}


def test_project_filter_with_source_disambiguates_shared_cwd(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, gemini_home = _set_source_homes(monkeypatch, tmp_path)
    project_dir = tmp_path / "shared"
    codex_file = _write_codex_session(codex_home, "codex-a", project_dir)
    gemini_file = _write_gemini_session(gemini_home, "gemini-a", project_dir)

    files = _collect_session_files(project_dir_name=str(project_dir), source="codex")
    stats = _get_stats(project_dir_name=str(project_dir), source="codex")

    assert files == [codex_file]
    assert gemini_file not in files
    assert stats["session_count"] == 1
    assert stats["user_message_count"] == 1


def test_collect_session_files_filters_claude_by_project_directory_key(
    tmp_path: Path,
    monkeypatch,
) -> None:
    claude_projects, _, _ = _set_source_homes(monkeypatch, tmp_path)
    claude_file = _write_claude_session(
        claude_projects,
        "-tmp-project-a",
        tmp_path / "demo",
    )

    files = _collect_session_files(project_dir_name="-tmp-project-a", source="claude")
    stats = _get_stats(project_dir_name="-tmp-project-a", source="claude")

    assert files == [claude_file]
    assert stats["session_count"] == 1
    assert stats["user_message_count"] == 1


def test_stats_to_dict_includes_cache_grade_and_claude_only_savings():
    stats = SessionStats(session_id="s1", project_path="/tmp/demo")
    stats.token_usage = TokenUsage(
        input_tokens=300_000,
        output_tokens=50_000,
        cache_read_input_tokens=700_000,
        cache_creation_input_tokens=100_000,
    )
    stats.token_by_model = {
        "claude-sonnet-4.5": TokenUsage(
            input_tokens=100_000,
            cache_read_input_tokens=600_000,
        ),
        "gpt-5.4": TokenUsage(
            input_tokens=200_000,
            cache_read_input_tokens=100_000,
        ),
    }

    result = _stats_to_dict(stats)
    cache = result["cache_stats"]

    assert cache["grade"] == "good"
    assert cache["grade_label"] == "Good"
    assert cache["cache_read_tokens"] == 700_000
    assert cache["total_input_tokens"] == 1_000_000
    assert cache["hit_rate"] == 0.7
    assert cache["savings_usd"] == 1.62
    assert cache["by_model"]["claude-sonnet-4.5"] == 0.8571428571428571
    assert cache["by_model"]["gpt-5.4"] == 0.3333333333333333


def test_stats_to_dict_returns_na_when_no_cache_reads():
    stats = SessionStats(session_id="s2", project_path="/tmp/demo")
    stats.token_usage = TokenUsage(input_tokens=120_000, output_tokens=30_000)
    stats.token_by_model = {
        "claude-sonnet-4.5": TokenUsage(input_tokens=120_000, output_tokens=30_000)
    }

    result = _stats_to_dict(stats)
    cache = result["cache_stats"]

    assert cache["grade"] == "na"
    assert cache["grade_label"] == "N/A"
    assert cache["cache_read_tokens"] == 0
    assert cache["total_input_tokens"] == 0
    assert cache["hit_rate"] == 0.0
    assert cache["savings_usd"] == 0.0
    assert cache["by_model"] == {}
