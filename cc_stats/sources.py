"""Unified session source registry for Claude, Codex, and Gemini."""

from __future__ import annotations

import os
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from cc_stats.parser import (
    Session,
    find_codex_sessions,
    find_codex_sessions_by_keyword,
    find_gemini_sessions,
    find_gemini_sessions_by_keyword,
    find_sessions,
    find_sessions_by_keyword,
    parse_session_file,
)


class SourceKind(str, Enum):
    ALL = "all"
    CLAUDE = "claude"
    CODEX = "codex"
    GEMINI = "gemini"


@dataclass(frozen=True)
class SourceProject:
    source: SourceKind
    key: str
    display_name: str
    session_count: int
    last_modified: float


def claude_projects_dir() -> Path:
    return _env_path("CC_STATS_CLAUDE_PROJECTS_DIR", Path.home() / ".claude" / "projects")


def codex_home() -> Path:
    return _env_path("CC_STATS_CODEX_HOME", Path.home() / ".codex")


def gemini_home() -> Path:
    return _env_path("CC_STATS_GEMINI_HOME", Path.home() / ".gemini")


def _env_path(name: str, default: Path) -> Path:
    raw = os.environ.get(name, "").strip()
    return Path(raw).expanduser() if raw else default


def normalize_source(source: SourceKind | str | None) -> SourceKind:
    if source is None or source == "":
        return SourceKind.ALL
    if isinstance(source, SourceKind):
        return source
    value = str(source).strip().lower()
    if value in {"claude-code", "claude_code"}:
        value = SourceKind.CLAUDE.value
    try:
        return SourceKind(value)
    except ValueError as exc:
        allowed = ", ".join(kind.value for kind in SourceKind)
        raise ValueError(f"Unknown source {source!r}; expected one of: {allowed}") from exc


def active_sources(source: SourceKind | str | None = None) -> tuple[SourceKind, ...]:
    normalized = normalize_source(source)
    if normalized == SourceKind.ALL:
        return (SourceKind.CLAUDE, SourceKind.CODEX, SourceKind.GEMINI)
    return (normalized,)


def collect_session_files(
    source: SourceKind | str | None = None,
    project_dir: Path | None = None,
) -> list[Path]:
    files: list[Path] = []
    for kind in active_sources(source):
        if kind == SourceKind.CLAUDE:
            files.extend(find_sessions(project_dir, projects_dir=claude_projects_dir()))
        elif kind == SourceKind.CODEX:
            files.extend(find_codex_sessions(project_dir, codex_home_dir=codex_home()))
        elif kind == SourceKind.GEMINI:
            if project_dir is None:
                files.extend(find_gemini_sessions(gemini_home_dir=gemini_home()))
            else:
                files.extend(_filter_sessions_by_project(
                    find_gemini_sessions(gemini_home_dir=gemini_home()),
                    project_dir,
                ))
    return list(dict.fromkeys(files))


def collect_session_files_by_keyword(
    keyword: str,
    source: SourceKind | str | None = None,
) -> list[Path]:
    files: list[Path] = []
    for kind in active_sources(source):
        if kind == SourceKind.CLAUDE:
            files.extend(find_sessions_by_keyword(keyword, projects_dir=claude_projects_dir()))
        elif kind == SourceKind.CODEX:
            files.extend(find_codex_sessions_by_keyword(keyword, codex_home_dir=codex_home()))
        elif kind == SourceKind.GEMINI:
            files.extend(find_gemini_sessions_by_keyword(keyword, gemini_home_dir=gemini_home()))
    return list(dict.fromkeys(files))


def list_projects(source: SourceKind | str | None = None) -> list[SourceProject]:
    groups: dict[tuple[SourceKind, str], _ProjectGroup] = {}
    for path in collect_session_files(source=source):
        try:
            session = parse_file(path)
        except (OSError, ValueError):
            continue
        kind = normalize_source(session.source)
        key = _project_key(path, session, kind)
        display_name = session.project_path or key
        last_modified = _mtime(path)
        group_key = (kind, key)
        if group_key not in groups:
            groups[group_key] = _ProjectGroup(
                source=kind,
                key=key,
                display_name=display_name,
                session_count=0,
                last_modified=last_modified,
            )
        group = groups[group_key]
        group.session_count += 1
        group.last_modified = max(group.last_modified, last_modified)
        if session.project_path:
            group.display_name = session.project_path

    return [
        SourceProject(
            source=group.source,
            key=group.key,
            display_name=group.display_name,
            session_count=group.session_count,
            last_modified=group.last_modified,
        )
        for group in sorted(
            groups.values(),
            key=lambda group: (group.source.value, group.display_name.lower(), group.key),
        )
    ]


def parse_file(path: Path) -> Session:
    return parse_session_file(path)


@dataclass
class _ProjectGroup:
    source: SourceKind
    key: str
    display_name: str
    session_count: int
    last_modified: float


def _filter_sessions_by_project(paths: list[Path], project_dir: Path) -> list[Path]:
    target = _normalized_path(project_dir)
    results: list[Path] = []
    for path in paths:
        try:
            session = parse_file(path)
        except (OSError, ValueError):
            continue
        if not session.project_path:
            continue
        if _normalized_path(Path(session.project_path)) == target:
            results.append(path)
    return results


def _project_key(path: Path, session: Session, source: SourceKind) -> str:
    if source == SourceKind.CLAUDE:
        return path.parent.name
    if session.project_path:
        return session.project_path
    return str(path.parent)


def _normalized_path(path: Path) -> str:
    try:
        resolved = str(path.expanduser().resolve())
    except OSError:
        resolved = str(path.expanduser())
    return os.path.normcase(resolved)


def _mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0
