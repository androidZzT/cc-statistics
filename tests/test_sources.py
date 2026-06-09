from __future__ import annotations

import json
from pathlib import Path

from cc_stats.sources import (
    SourceKind,
    collect_session_files,
    collect_session_files_by_keyword,
    list_projects,
)


def _write_jsonl(path: Path, records: list[dict]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")
    return path


def _write_codex_session(codex_home: Path, name: str, cwd: Path, message: str = "hi") -> Path:
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
            "payload": {"id": name, "cwd": str(cwd)},
        },
        {
            "timestamp": "2026-06-09T00:00:01Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": message},
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


def test_collect_session_files_all_includes_codex_synthetic_sessions(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _, codex_home, gemini_home = _set_source_homes(monkeypatch, tmp_path)
    codex_file = _write_codex_session(codex_home, "codex-a", tmp_path / "demo")
    gemini_file = _write_gemini_session(gemini_home, "gemini-a", tmp_path / "gemini-demo")

    files = collect_session_files(source=SourceKind.ALL)

    assert codex_file in files
    assert gemini_file in files


def test_list_projects_source_codex_groups_by_cwd(tmp_path: Path, monkeypatch) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    project_dir = tmp_path / "demo"
    _write_codex_session(codex_home, "codex-a", project_dir)
    _write_codex_session(codex_home, "codex-b", project_dir)

    projects = list_projects(source=SourceKind.CODEX)

    assert len(projects) == 1
    assert projects[0].source == SourceKind.CODEX
    assert projects[0].key == str(project_dir)
    assert projects[0].display_name == str(project_dir)
    assert projects[0].session_count == 2


def test_list_projects_source_claude_preserves_project_directory_key(
    tmp_path: Path,
    monkeypatch,
) -> None:
    claude_projects, _, _ = _set_source_homes(monkeypatch, tmp_path)
    shared_cwd = tmp_path / "shared-project"
    _write_claude_session(claude_projects, "-tmp-project-a", shared_cwd)
    _write_claude_session(claude_projects, "-tmp-project-b", shared_cwd)

    projects = list_projects(source=SourceKind.CLAUDE)

    assert [p.key for p in projects] == ["-tmp-project-a", "-tmp-project-b"]
    assert [p.display_name for p in projects] == [str(shared_cwd), str(shared_cwd)]
    assert [p.session_count for p in projects] == [1, 1]


def test_source_filter_excludes_other_sources(tmp_path: Path, monkeypatch) -> None:
    _, codex_home, gemini_home = _set_source_homes(monkeypatch, tmp_path)
    codex_file = _write_codex_session(codex_home, "codex-a", tmp_path / "demo")
    gemini_file = _write_gemini_session(gemini_home, "gemini-a", tmp_path / "demo")

    files = collect_session_files(source=SourceKind.CODEX)

    assert files == [codex_file]
    assert gemini_file not in files


def test_keyword_search_uses_env_overrides_for_codex(tmp_path: Path, monkeypatch) -> None:
    _, codex_home, gemini_home = _set_source_homes(monkeypatch, tmp_path)
    codex_file = _write_codex_session(
        codex_home,
        "codex-a",
        tmp_path / "demo",
        message="needle from override",
    )
    _write_gemini_session(gemini_home, "gemini-a", tmp_path / "demo")

    files = collect_session_files_by_keyword("needle", source=SourceKind.CODEX)

    assert files == [codex_file]


def test_list_projects_display_shape_for_cli(tmp_path: Path, monkeypatch) -> None:
    _, codex_home, _ = _set_source_homes(monkeypatch, tmp_path)
    _write_codex_session(codex_home, "codex-a", tmp_path / "demo")

    projects = list_projects(source="codex")

    assert [(p.source.value, Path(p.display_name).name, p.session_count) for p in projects] == [
        ("codex", "demo", 1),
    ]


def test_env_overrides_do_not_require_real_home_data(tmp_path: Path, monkeypatch) -> None:
    claude_projects, codex_home, gemini_home = _set_source_homes(monkeypatch, tmp_path)
    assert not claude_projects.exists()
    assert not codex_home.exists()
    assert not gemini_home.exists()

    assert collect_session_files() == []
    assert list_projects() == []
