"""Unified session source registry for Claude, Codex, and Gemini."""

from __future__ import annotations

import os
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from cc_stats.parser import (
    Session,
    find_cursor_sessions,
    find_codex_sessions,
    find_codex_sessions_by_keyword,
    find_gemini_sessions,
    find_gemini_sessions_by_keyword,
    find_sessions,
    find_sessions_by_keyword,
    parse_cursor_sessions,
    parse_session_file,
)


class SourceKind(str, Enum):
    ALL = "all"
    CLAUDE = "claude"
    CODEX = "codex"
    GEMINI = "gemini"
    CURSOR = "cursor"


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


def cursor_state_db() -> Path:
    raw = os.environ.get("CC_STATS_CURSOR_STATE_DB", "").strip()
    if raw:
        return Path(raw).expanduser()
    user_dir = _env_path("CC_STATS_CURSOR_USER_DIR", _default_cursor_user_dir())
    return user_dir / "globalStorage" / "state.vscdb"


def _default_cursor_user_dir() -> Path:
    appdata = os.environ.get("APPDATA", "").strip()
    if appdata:
        return Path(appdata) / "Cursor" / "User"
    if os.name == "nt":
        return Path.home() / "AppData" / "Roaming" / "Cursor" / "User"
    if sys_platform := os.environ.get("XDG_CONFIG_HOME", "").strip():
        return Path(sys_platform) / "Cursor" / "User"
    return Path.home() / ".config" / "Cursor" / "User"


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
        return (SourceKind.CLAUDE, SourceKind.CODEX, SourceKind.GEMINI, SourceKind.CURSOR)
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
        elif kind == SourceKind.CURSOR:
            cursor_files = find_cursor_sessions(cursor_state_db_path=cursor_state_db())
            if project_dir is None:
                files.extend(cursor_files)
            else:
                files.extend(_filter_sessions_by_project(cursor_files, project_dir))
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
        elif kind == SourceKind.CURSOR:
            files.extend(_find_cursor_sessions_by_keyword(keyword))
    return list(dict.fromkeys(files))


def list_projects(source: SourceKind | str | None = None) -> list[SourceProject]:
    groups: dict[tuple[SourceKind, str], _ProjectGroup] = {}
    for path in collect_session_files(source=source):
        try:
            sessions = parse_sessions(path)
        except (OSError, ValueError):
            continue
        for session in sessions:
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


def parse_sessions(path: Path) -> list[Session]:
    if path.name == "state.vscdb":
        return parse_cursor_sessions(path)
    return [parse_session_file(path)]


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
            sessions = parse_sessions(path)
        except (OSError, ValueError):
            continue
        if any(
            session.project_path
            and _normalized_path(Path(session.project_path)) == target
            for session in sessions
        ):
            results.append(path)
    return results


def _find_cursor_sessions_by_keyword(keyword: str) -> list[Path]:
    keyword_lower = keyword.lower()
    db_files = find_cursor_sessions(cursor_state_db_path=cursor_state_db())
    if not db_files:
        return []
    for db_file in db_files:
        try:
            sessions = parse_cursor_sessions(db_file)
        except (OSError, ValueError):
            continue
        for session in sessions:
            if keyword_lower in session.project_path.lower():
                return [db_file]
            if any(keyword_lower in str(message.content).lower() for message in session.messages):
                return [db_file]
    return []


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
