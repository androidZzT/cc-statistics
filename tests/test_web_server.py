from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cc_stats.analyzer import SessionStats, TokenUsage
from cc_stats_web import server as web_server
from cc_stats_web.server import (
    _collect_session_files,
    _daily_date_keys,
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


def _write_codex_session_at(
    codex_home: Path,
    name: str,
    cwd: Path,
    timestamp: datetime,
) -> Path:
    path = (
        codex_home
        / "sessions"
        / timestamp.strftime("%Y")
        / timestamp.strftime("%m")
        / timestamp.strftime("%d")
        / f"rollout-{timestamp.strftime('%Y-%m-%dT%H-%M-%S')}-{name}.jsonl"
    )
    ts = timestamp.isoformat().replace("+00:00", "Z")
    return _write_jsonl(path, [
        {
            "timestamp": ts,
            "type": "session_meta",
            "payload": {
                "id": name,
                "cwd": str(cwd),
                "model": "gpt-5.3-codex",
            },
        },
        {
            "timestamp": ts,
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "hi"},
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


def _write_gemini_jsonl_session(gemini_home: Path, name: str, cwd: Path) -> Path:
    project_dir = gemini_home / "tmp" / "demo-project"
    (project_dir / "chats").mkdir(parents=True, exist_ok=True)
    (project_dir / ".project_root").write_text(str(cwd), encoding="utf-8")
    path = project_dir / "chats" / f"session-2026-06-09T17-21-{name}.jsonl"
    return _write_jsonl(path, [
        {
            "sessionId": name,
            "projectHash": "project-hash",
            "startTime": "2026-06-09T17:21:00Z",
            "lastUpdated": "2026-06-09T17:22:00Z",
            "kind": "main",
        },
        {
            "id": "user-1",
            "timestamp": "2026-06-09T17:21:01Z",
            "type": "user",
            "content": [{"text": "hello from gemini"}],
        },
        {
            "id": "gemini-1",
            "timestamp": "2026-06-09T17:21:02Z",
            "type": "gemini",
            "content": "done",
            "model": "gemini-2.5-pro",
            "tokens": {"input": 100, "output": 20, "cached": 30},
            "toolCalls": [
                {
                    "id": "tool-1",
                    "name": "read_file",
                    "args": {"path": "README.md"},
                    "timestamp": "2026-06-09T17:21:02Z",
                }
            ],
        },
    ])


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
    cursor_db = tmp_path / "synthetic-cursor" / "state.vscdb"
    monkeypatch.setenv("CC_STATS_CLAUDE_PROJECTS_DIR", str(claude_projects))
    monkeypatch.setenv("CC_STATS_CODEX_HOME", str(codex_home))
    monkeypatch.setenv("CC_STATS_GEMINI_HOME", str(gemini_home))
    monkeypatch.setenv("CC_STATS_CURSOR_STATE_DB", str(cursor_db))
    monkeypatch.setenv("HOME", str(tmp_path / "unused-real-home"))
    return claude_projects, codex_home, gemini_home


def _write_cursor_state_db(cursor_db: Path, project_dir: Path, composer_id: str = "cursor-a") -> Path:
    cursor_db.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(cursor_db)
    try:
        con.execute("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB)")
        con.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
        composer = {
            "composerId": composer_id,
            "createdAt": 1780963200000,
            "lastUpdatedAt": 1780963202000,
            "modelConfig": {"modelName": "claude-4.5-sonnet-thinking"},
            "totalLinesAdded": 3,
            "totalLinesRemoved": 1,
            "fullConversationHeadersOnly": [
                {"bubbleId": "user-1", "type": 1},
                {"bubbleId": "assistant-1", "type": 2},
            ],
        }
        user_bubble = {
            "bubbleId": "user-1",
            "type": 1,
            "createdAt": "2026-06-09T00:00:00Z",
            "text": "build this in Cursor",
            "workspaceUris": [project_dir.as_uri()],
            "workspaceProjectDir": str(project_dir),
        }
        assistant_bubble = {
            "bubbleId": "assistant-1",
            "type": 2,
            "createdAt": "2026-06-09T00:00:02Z",
            "text": "done",
            "modelInfo": {"modelName": "claude-4.5-sonnet-thinking"},
            "tokenCount": {"inputTokens": 10, "outputTokens": 5},
            "workspaceUris": [project_dir.as_uri()],
            "workspaceProjectDir": str(project_dir),
        }
        rows = [
            (f"composerData:{composer_id}", composer),
            (f"bubbleId:{composer_id}:user-1", user_bubble),
            (f"bubbleId:{composer_id}:assistant-1", assistant_bubble),
        ]
        con.executemany(
            "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)",
            [(key, json.dumps(value).encode("utf-8")) for key, value in rows],
        )
        con.commit()
    finally:
        con.close()
    return cursor_db


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
    server, port = start_server(warm_cache=False)
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


def test_health_endpoint_responds_while_stats_request_is_busy(monkeypatch) -> None:
    def slow_stats(*args, **kwargs):
        time.sleep(0.4)
        return {"ok": True}

    monkeypatch.setattr("cc_stats_web.server._get_stats", slow_stats)
    server, port = start_server(warm_cache=False)
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": 0.1},
        daemon=True,
    )
    thread.start()
    stats_thread = threading.Thread(
        target=lambda: urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/stats", timeout=2
        ).read(),
        daemon=True,
    )

    try:
        stats_thread.start()
        time.sleep(0.05)
        start = time.monotonic()
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        elapsed = time.monotonic() - start
    finally:
        stats_thread.join(timeout=2)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    assert payload == {"status": "ok"}
    assert elapsed < 0.3


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


def test_get_stats_source_gemini_parses_windows_jsonl_sessions(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, _, gemini_home = _set_source_homes(monkeypatch, tmp_path)
    _write_gemini_jsonl_session(gemini_home, "gemini-jsonl", tmp_path / "demo")

    stats = _get_stats(source="gemini")

    assert stats["session_count"] == 1
    assert stats["user_message_count"] == 1
    assert stats["tool_calls"] == [{"name": "Read", "count": 1}]
    assert stats["token_usage"]["input_tokens"] == 100
    assert stats["token_usage"]["cache_read"] == 30
    assert stats["token_usage"]["output_tokens"] == 20
    assert stats["token_usage"]["total"] == 150


def test_get_stats_source_cursor_parses_state_db(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _set_source_homes(monkeypatch, tmp_path)
    cursor_db = tmp_path / "synthetic-cursor" / "state.vscdb"
    _write_cursor_state_db(cursor_db, tmp_path / "demo")

    stats = _get_stats(source="cursor")

    assert stats["session_count"] == 1
    assert stats["user_message_count"] == 1
    assert stats["token_usage"]["input_tokens"] == 10
    assert stats["token_usage"]["output_tokens"] == 5
    assert stats["token_usage"]["total"] == 15
    assert stats["total_added"] == 3
    assert stats["total_removed"] == 1


def test_get_dashboard_payload_analyzes_sessions_once_for_summary_daily_and_skills(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    _write_codex_session(codex_home, "codex-a", tmp_path / "demo")
    analyzed: list[str] = []

    def fake_analyze_session(session, *, include_git=True):
        analyzed.append(session.session_id)
        stats = SessionStats(session_id=session.session_id, project_path=session.project_path)
        stats.user_message_count = 1
        return stats

    monkeypatch.setattr(web_server, "analyze_session", fake_analyze_session)

    payload = web_server._get_dashboard_payload(source="codex", daily_days=30)

    assert analyzed == ["codex-a"]
    assert payload["stats"]["session_count"] == 1
    assert isinstance(payload["daily_stats"], list)
    assert payload["skills"] == []


def test_get_dashboard_payload_reuses_analyzed_sessions_between_range_tabs(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    _write_codex_session(codex_home, "codex-a", tmp_path / "demo")
    analyzed: list[str] = []

    def fake_analyze_session(session, *, include_git=True):
        analyzed.append(session.session_id)
        stats = SessionStats(session_id=session.session_id, project_path=session.project_path)
        stats.user_message_count = 1
        return stats

    monkeypatch.setattr(web_server, "analyze_session", fake_analyze_session)

    today = web_server._get_dashboard_payload(source="codex", since_days=1, daily_days=1)
    week = web_server._get_dashboard_payload(source="codex", since_days=7, daily_days=7)

    assert analyzed == ["codex-a"]
    assert today["stats"]["session_count"] == 1
    assert week["stats"]["session_count"] == 1


def test_get_dashboard_payload_keeps_short_lived_cache_when_file_mtime_moves(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    session_file = _write_codex_session(codex_home, "codex-a", tmp_path / "demo")
    analyzed: list[str] = []

    def fake_analyze_session(session, *, include_git=True):
        analyzed.append(session.session_id)
        return SessionStats(session_id=session.session_id, project_path=session.project_path)

    monkeypatch.setattr(web_server, "analyze_session", fake_analyze_session)

    web_server._get_dashboard_payload(source="codex", since_days=1, daily_days=1)
    now = time.time() + 10
    os.utime(session_file, (now, now))
    web_server._get_dashboard_payload(source="codex", since_days=7, daily_days=7)

    assert analyzed == ["codex-a"]


def test_get_dashboard_payload_singleflights_concurrent_cache_fill(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    _write_codex_session(codex_home, "codex-a", tmp_path / "demo")
    started = threading.Event()
    analyzed: list[str] = []

    def fake_analyze_session(session, *, include_git=True):
        analyzed.append(session.session_id)
        started.set()
        time.sleep(0.05)
        return SessionStats(session_id=session.session_id, project_path=session.project_path)

    monkeypatch.setattr(web_server, "analyze_session", fake_analyze_session)

    results: list[dict] = []
    first = threading.Thread(
        target=lambda: results.append(web_server._get_dashboard_payload(source="codex")),
    )
    first.start()
    assert started.wait(timeout=2)
    second = threading.Thread(
        target=lambda: results.append(web_server._get_dashboard_payload(source="codex")),
    )
    second.start()
    first.join(timeout=5)
    second.join(timeout=5)

    assert len(results) == 2
    assert analyzed == ["codex-a"]


def test_get_stats_prefilters_old_mtime_before_parsing(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    now = datetime.now(timezone.utc)
    old_ts = now - timedelta(days=7)
    recent_ts = now - timedelta(hours=1)
    old_file = _write_codex_session_at(codex_home, "old", tmp_path / "old", old_ts)
    recent_file = _write_codex_session_at(
        codex_home,
        "recent",
        tmp_path / "recent",
        recent_ts,
    )
    old_epoch = old_ts.timestamp()
    recent_epoch = recent_ts.timestamp()

    os.utime(old_file, (old_epoch, old_epoch))
    os.utime(recent_file, (recent_epoch, recent_epoch))

    parsed: list[Path] = []
    original_parse = web_server._parse_session_file

    def tracking_parse(path: Path):
        parsed.append(path)
        return original_parse(path)

    monkeypatch.setattr(web_server, "_parse_session_file", tracking_parse)

    stats = web_server._get_stats(source="codex", since_days=1)

    assert stats["session_count"] == 1
    assert recent_file in parsed
    assert old_file not in parsed


def test_get_stats_disables_git_collection_for_web_requests(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    _write_codex_session(codex_home, "codex-a", tmp_path / "demo")
    include_git_values: list[bool] = []

    def fake_analyze_session(session, *, include_git=True):
        include_git_values.append(include_git)
        return SessionStats(session_id=session.session_id, project_path=session.project_path)

    monkeypatch.setattr(web_server, "analyze_session", fake_analyze_session)

    stats = web_server._get_stats(source="codex")

    assert stats["session_count"] == 1
    assert include_git_values == [False]


def test_daily_date_keys_for_today_cover_rolling_window_across_midnight() -> None:
    since_dt = datetime(2026, 6, 9, 15, 30, tzinfo=timezone.utc)
    now_dt = datetime(2026, 6, 9, 17, 0, tzinfo=timezone.utc)

    assert _daily_date_keys(since_dt, days=1, now=now_dt) == [
        "2026-06-09",
        "2026-06-10",
    ]


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


def test_stats_to_dict_includes_cache_grade_and_model_savings():
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
    assert cache["savings_usd"] == 1.845
    assert cache["by_model"]["claude-sonnet-4.5"] == 0.8571428571428571
    assert cache["by_model"]["gpt-5.4"] == 0.3333333333333333


def test_stats_to_dict_marks_skipped_git_scan():
    stats = SessionStats(session_id="s3", project_path="/tmp/demo")

    result = _stats_to_dict(stats, git_scan_skipped=True)

    assert result["git_scan_skipped"] is True


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


def test_stats_to_dict_omits_zero_token_model_rows():
    stats = SessionStats(session_id="s4", project_path="/tmp/demo")
    stats.token_usage = TokenUsage(input_tokens=100, output_tokens=20)
    stats.token_by_model = {
        "gpt-5.5": TokenUsage(input_tokens=100, output_tokens=20),
        "cursor-model-without-token-count": TokenUsage(),
    }

    result = _stats_to_dict(stats)

    assert [row["model"] for row in result["token_by_model"]] == ["gpt-5.5"]


def test_dashboard_html_prefetches_period_payloads():
    html = (Path(web_server._web_dir) / "index.html").read_text(encoding="utf-8")

    assert "dashboardCache" in html
    assert "prefetchPeriodPayloads" in html
    assert "renderDashboardPayload" in html


def test_warm_dashboard_cache_primes_projects_and_analyzed_stats(monkeypatch):
    calls: list[str] = []

    monkeypatch.setattr(web_server, "_get_projects", lambda source=None: calls.append("projects"))
    monkeypatch.setattr(
        web_server,
        "_get_cached_analyzed_stats",
        lambda project_dir_name=None, source=None: calls.append("stats"),
    )

    web_server._warm_dashboard_cache()

    assert calls == ["stats", "projects"]
