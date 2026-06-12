"""HTTP server: static files + JSON API"""

from __future__ import annotations

import json
import os
import socket
import threading
import time
from collections import defaultdict
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from cc_stats.cli import _trim_stats_by_date_range
from cc_stats.analyzer import (
    SessionStats,
    TokenUsage,
    analyze_session,
    compute_cache_stats,
    merge_stats,
)
from cc_stats.pricing import match_model_pricing
from cc_stats.sources import collect_session_files, list_projects, parse_file, parse_sessions

_web_dir = os.path.join(os.path.dirname(__file__), "web")


@dataclass(frozen=True)
class _AnalyzedCacheEntry:
    signature: tuple[tuple[str, int | None, int | None], ...]
    stats: list[SessionStats]
    created_at: float


@dataclass(frozen=True)
class _ProjectsCacheEntry:
    signature: tuple[tuple[str, int | None, int | None], ...]
    projects: list[dict]
    created_at: float


@dataclass(frozen=True)
class _DashboardPeriodRange:
    since_dt: datetime | None
    since_date: str | None
    until_date: str | None
    daily_days: int


_CACHE_TTL_SECONDS = 45.0
_ANALYZED_CACHE_LOCK = threading.Lock()
_PROJECTS_CACHE_LOCK = threading.Lock()
_ANALYZED_CACHE: dict[tuple[str, str], _AnalyzedCacheEntry] = {}
_PROJECTS_CACHE: dict[str, _ProjectsCacheEntry] = {}


def _session_files_signature(files: list[Path]) -> tuple[tuple[str, int | None, int | None], ...]:
    signature = []
    for path in files:
        try:
            stat = path.stat()
            signature.append((str(path), stat.st_mtime_ns, stat.st_size))
        except OSError:
            signature.append((str(path), None, None))
    return tuple(signature)


def _cache_source_key(source: str | None) -> str:
    env_parts = [
        os.environ.get("CC_STATS_CLAUDE_PROJECTS_DIR", ""),
        os.environ.get("CC_STATS_CODEX_HOME", ""),
        os.environ.get("CC_STATS_GEMINI_HOME", ""),
        os.environ.get("CC_STATS_CURSOR_STATE_DB", ""),
        os.environ.get("CC_STATS_CURSOR_USER_DIR", ""),
        os.environ.get("HOME", ""),
    ]
    return "\0".join([source or "", *env_parts])


def _cache_project_key(project_dir_name) -> str:
    return str(project_dir_name or "")


def _is_cache_fresh(created_at: float) -> bool:
    return time.monotonic() - created_at <= _CACHE_TTL_SECONDS


def _now_local() -> datetime:
    return datetime.now().astimezone()


def _dashboard_period_range(
    period: str | None,
    now: datetime | None = None,
) -> _DashboardPeriodRange | None:
    if not period:
        return None

    normalized = period.strip().lower()
    local_now = now if now is not None else _now_local()
    if local_now.tzinfo is None:
        local_now = local_now.astimezone()

    if normalized == "all":
        return _DashboardPeriodRange(None, None, None, 30)
    if normalized == "today":
        start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif normalized == "week":
        start = (local_now - timedelta(days=local_now.weekday())).replace(
            hour=0,
            minute=0,
            second=0,
            microsecond=0,
        )
    elif normalized == "month":
        start = local_now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    else:
        raise ValueError(f"Unsupported dashboard period: {period}")

    since_date = start.date().strftime("%Y-%m-%d")
    until_date = local_now.date().strftime("%Y-%m-%d")
    daily_days = max((local_now.date() - start.date()).days + 1, 1)
    return _DashboardPeriodRange(
        start.astimezone(timezone.utc),
        since_date,
        until_date,
        daily_days,
    )


def _date_key_in_range(
    date_key: str,
    since_date: str | None,
    until_date: str | None,
) -> bool:
    if since_date and date_key < since_date:
        return False
    if until_date and date_key > until_date:
        return False
    return True


def _stats_matches_local_date_range(
    stats: SessionStats,
    since_date: str | None,
    until_date: str | None,
) -> bool:
    if not since_date and not until_date:
        return True
    if stats.token_by_date:
        return any(
            usage.total > 0 and _date_key_in_range(date_key, since_date, until_date)
            for date_key, usage in stats.token_by_date.items()
        )
    if stats.start_time:
        return _date_key_in_range(
            stats.start_time.astimezone().strftime("%Y-%m-%d"),
            since_date,
            until_date,
        )
    if stats.end_time:
        return _date_key_in_range(
            stats.end_time.astimezone().strftime("%Y-%m-%d"),
            since_date,
            until_date,
        )
    return False


def _scale_timedelta(value: timedelta, fraction: float) -> timedelta:
    return timedelta(seconds=value.total_seconds() * fraction)


def _scale_stats_durations(stats: SessionStats, fraction: float) -> None:
    fraction = max(0.0, min(fraction, 1.0))
    stats.total_duration = _scale_timedelta(stats.total_duration, fraction)
    stats.ai_duration = _scale_timedelta(stats.ai_duration, fraction)
    stats.user_duration = _scale_timedelta(stats.user_duration, fraction)
    stats.active_duration = _scale_timedelta(stats.active_duration, fraction)


def _stats_for_local_date_range(
    all_stats: list[SessionStats],
    since_date: str | None,
    until_date: str | None,
) -> list[SessionStats]:
    if not since_date and not until_date:
        return all_stats

    filtered = []
    for stats in all_stats:
        if not _stats_matches_local_date_range(stats, since_date, until_date):
            continue
        original_token_total = stats.token_usage.total
        stats_copy = deepcopy(stats)
        _trim_stats_by_date_range(stats_copy, since_date, until_date)
        if original_token_total > 0:
            _scale_stats_durations(
                stats_copy,
                stats_copy.token_usage.total / original_token_total,
            )
        filtered.append(stats_copy)
    return filtered


def _estimate_cost(tu: TokenUsage, model: str = "") -> float:
    p = match_model_pricing(model)
    cost = 0.0
    cost += tu.input_tokens / 1e6 * p["input"]
    cost += tu.output_tokens / 1e6 * p["output"]
    cost += tu.cache_read_input_tokens / 1e6 * p["cache_read"]
    cost += tu.cache_creation_input_tokens / 1e6 * p["cache_create"]
    return cost


def _stats_to_dict(
    stats: SessionStats,
    session_count: int = 1,
    git_scan_skipped: bool = False,
) -> dict:
    def _td_seconds(td):
        return td.total_seconds()

    def _fmt_duration(td):
        total = int(td.total_seconds())
        if total < 0:
            return "0s"
        h, rem = divmod(total, 3600)
        m, s = divmod(rem, 60)
        parts = []
        if h:
            parts.append(f"{h}h")
        if m:
            parts.append(f"{m}m")
        if s or not parts:
            parts.append(f"{s}s")
        return " ".join(parts)

    def _token_dict(tu):
        return {
            "input_tokens": tu.input_tokens,
            "output_tokens": tu.output_tokens,
            "cache_read": tu.cache_read_input_tokens,
            "cache_creation": tu.cache_creation_input_tokens,
            "total": tu.total,
        }

    sorted_tools = sorted(stats.tool_call_counts.items(), key=lambda x: x[1], reverse=True)
    sorted_langs = sorted(stats.lines_by_lang.items(), key=lambda x: x[1]["added"], reverse=True)

    # Cost per model
    total_cost = 0.0
    model_tokens = []
    for model, usage in sorted(stats.token_by_model.items(), key=lambda x: x[1].total, reverse=True):
        if usage.total <= 0:
            continue
        cost = _estimate_cost(usage, model)
        total_cost += cost
        model_tokens.append({
            "model": model,
            **_token_dict(usage),
            "cost": round(cost, 4),
        })

    cache = compute_cache_stats(stats.token_usage, stats.token_by_model)

    return {
        "session_count": session_count,
        "user_message_count": stats.user_message_count,
        "tool_call_total": stats.tool_call_total,
        "tool_calls": [{"name": n, "count": c} for n, c in sorted_tools],
        "total_duration": _td_seconds(stats.total_duration),
        "total_duration_fmt": _fmt_duration(stats.total_duration),
        "ai_duration": _td_seconds(stats.ai_duration),
        "ai_duration_fmt": _fmt_duration(stats.ai_duration),
        "user_duration": _td_seconds(stats.user_duration),
        "user_duration_fmt": _fmt_duration(stats.user_duration),
        "active_duration": _td_seconds(stats.active_duration),
        "active_duration_fmt": _fmt_duration(stats.active_duration),
        "turn_count": stats.turn_count,
        "total_added": stats.total_added,
        "total_removed": stats.total_removed,
        "lines_by_lang": [{"lang": l, **c} for l, c in sorted_langs],
        "git_available": stats.git_available,
        "git_total_added": stats.git_total_added,
        "git_total_removed": stats.git_total_removed,
        "git_commit_count": stats.git_commit_count,
        "git_scan_skipped": git_scan_skipped,
        "token_usage": _token_dict(stats.token_usage),
        "token_by_model": model_tokens,
        "estimated_cost": round(total_cost, 2),
        "cache_stats": {
            "hit_rate": round(cache.hit_rate, 4),
            "grade": cache.grade,
            "grade_label": cache.grade_label,
            "cache_read_tokens": cache.cache_read_tokens,
            "total_input_tokens": cache.total_input_tokens,
            "savings_usd": round(cache.savings_usd, 4),
            "by_model": cache.by_model,
        },
    }


def _get_projects(source: str | None = None):
    cache_key = _cache_source_key(source)
    with _PROJECTS_CACHE_LOCK:
        cached = _PROJECTS_CACHE.get(cache_key)
        if cached and _is_cache_fresh(cached.created_at):
            return cached.projects

        files = collect_session_files(source=source)
        files.sort(key=lambda path: str(path))
        signature = _session_files_signature(files)
        cached = _PROJECTS_CACHE.get(cache_key)
        if cached and cached.signature == signature:
            _PROJECTS_CACHE[cache_key] = _ProjectsCacheEntry(
                signature=cached.signature,
                projects=cached.projects,
                created_at=time.monotonic(),
            )
            return cached.projects

        projects = [
            {
                "dir_name": project.key,
                "display_name": project.display_name,
                "session_count": project.session_count,
                "source": project.source.value,
            }
            for project in list_projects(source=source)
        ]
        projects.sort(key=lambda x: x["session_count"], reverse=True)
        _PROJECTS_CACHE[cache_key] = _ProjectsCacheEntry(
            signature=signature,
            projects=projects,
            created_at=time.monotonic(),
        )
        return projects


def _collect_session_files(project_dir_name=None, source: str | None = None):
    """Collect session files from the shared source registry."""
    files = collect_session_files(source=source)
    if not project_dir_name:
        return files

    filtered = []
    for f in files:
        try:
            sessions = _parse_sessions_from_file(f)
        except Exception:
            continue
        if any(session.project_path == project_dir_name for session in sessions):
            filtered.append(f)
            continue
        if (
            any(session.source == "claude" for session in sessions)
            and f.parent.name == project_dir_name
        ):
            filtered.append(f)
    return filtered


def _parse_session_file(f):
    """Parse a session file through the shared source parser."""
    return parse_file(f)


def _parse_sessions_from_file(f):
    """Parse one source entry into one or more sessions."""
    if getattr(f, "name", "") == "state.vscdb":
        return parse_sessions(f)
    return [_parse_session_file(f)]


def _filter_files_by_mtime(files: list, since_dt: datetime | None):
    if since_dt is None:
        return files

    threshold = since_dt.timestamp()
    filtered = []
    for f in files:
        try:
            if f.stat().st_mtime >= threshold:
                filtered.append(f)
        except OSError:
            filtered.append(f)
    return filtered


def _session_matches_project(session, path, project_dir_name) -> bool:
    if not project_dir_name:
        return True
    if session.project_path == project_dir_name:
        return True
    return session.source == "claude" and path.parent.name == project_dir_name


def _analyze_session_files(
    files: list,
    since_dt: datetime | None = None,
    project_dir_name=None,
) -> list[SessionStats]:
    all_stats = []
    for f in files:
        try:
            sessions = _parse_sessions_from_file(f)
            for session in sessions:
                if not _session_matches_project(session, f, project_dir_name):
                    continue
                stats = analyze_session(session, include_git=False)
                if since_dt and stats.end_time and stats.end_time < since_dt:
                    continue
                all_stats.append(stats)
        except Exception:
            continue
    return all_stats


def _get_cached_analyzed_stats(
    project_dir_name=None,
    source: str | None = None,
) -> list[SessionStats]:
    cache_key = (_cache_source_key(source), _cache_project_key(project_dir_name))
    with _ANALYZED_CACHE_LOCK:
        cached = _ANALYZED_CACHE.get(cache_key)
        if cached and _is_cache_fresh(cached.created_at):
            return cached.stats

        files = _collect_session_files(project_dir_name, source=source)
        if not files:
            return []

        files.sort(key=lambda f: f.stat().st_mtime)
        signature = _session_files_signature(files)
        cached = _ANALYZED_CACHE.get(cache_key)
        if cached and cached.signature == signature:
            _ANALYZED_CACHE[cache_key] = _AnalyzedCacheEntry(
                signature=cached.signature,
                stats=cached.stats,
                created_at=time.monotonic(),
            )
            return cached.stats

        all_stats = _analyze_session_files(files, project_dir_name=project_dir_name)
        _ANALYZED_CACHE[cache_key] = _AnalyzedCacheEntry(
            signature=signature,
            stats=all_stats,
            created_at=time.monotonic(),
        )
        return all_stats


def _merged_stats(all_stats: list[SessionStats]) -> SessionStats | None:
    if not all_stats:
        return None
    return all_stats[0] if len(all_stats) == 1 else merge_stats(all_stats)


def _daily_date_keys(
    since_dt: datetime,
    days: int,
    now: datetime | None = None,
) -> list[str]:
    now_dt = now or datetime.now(tz=timezone.utc)
    if days <= 1:
        start_date = since_dt.astimezone().date()
        end_date = now_dt.astimezone().date()
        if start_date > end_date:
            start_date = end_date
        span = (end_date - start_date).days
        return [
            (start_date + timedelta(days=i)).strftime("%Y-%m-%d")
            for i in range(span + 1)
        ]

    today = now_dt.astimezone().date()
    return [
        (today - timedelta(days=i)).strftime("%Y-%m-%d")
        for i in range(days - 1, -1, -1)
    ]


def _get_stats(project_dir_name=None, since_days=None, source: str | None = None):
    files = _collect_session_files(project_dir_name, source=source)
    if not files:
        return {"error": "No sessions found"}

    since_dt = None
    if since_days:
        since_dt = datetime.now(tz=timezone.utc) - timedelta(days=since_days)

    files = _filter_files_by_mtime(files, since_dt)
    files.sort(key=lambda f: f.stat().st_mtime)

    all_stats = _analyze_session_files(files, since_dt, project_dir_name)

    if not all_stats:
        return {"error": "No valid sessions"}

    result = _merged_stats(all_stats)
    if result is None:
        return {"error": "No valid sessions"}
    return _stats_to_dict(
        result,
        session_count=len(all_stats),
        git_scan_skipped=True,
    )


def _get_daily_stats(project_dir_name=None, days=14, source: str | None = None):
    files = _collect_session_files(project_dir_name, source=source)

    since_dt = datetime.now(tz=timezone.utc) - timedelta(days=days)
    files = _filter_files_by_mtime(files, since_dt)
    daily: dict[str, list] = defaultdict(list)

    for stats in _analyze_session_files(files, since_dt, project_dir_name):
        if not stats.start_time:
            continue
        day_key = stats.start_time.astimezone().strftime("%Y-%m-%d")
        daily[day_key].append(stats)

    result = []
    for day_key in _daily_date_keys(since_dt, days):
        day_stats = daily.get(day_key, [])
        if day_stats:
            merged = merge_stats(day_stats) if len(day_stats) > 1 else day_stats[0]
            cost = sum(_estimate_cost(u, m) for m, u in merged.token_by_model.items())
            result.append({
                "date": day_key,
                "sessions": len(day_stats),
                "messages": merged.user_message_count,
                "tool_calls": merged.tool_call_total,
                "active_minutes": round(merged.active_duration.total_seconds() / 60, 1),
                "lines_added": merged.total_added,
                "lines_removed": merged.total_removed,
                "tokens": merged.token_usage.total,
                "cost": round(cost, 2),
            })
        else:
            result.append({
                "date": day_key, "sessions": 0, "messages": 0, "tool_calls": 0,
                "active_minutes": 0, "lines_added": 0, "lines_removed": 0, "tokens": 0, "cost": 0,
            })
    return result


def _add_token_usage(target: TokenUsage, source: TokenUsage) -> None:
    target.input_tokens += source.input_tokens
    target.output_tokens += source.output_tokens
    target.cache_read_input_tokens += source.cache_read_input_tokens
    target.cache_creation_input_tokens += source.cache_creation_input_tokens


def _daily_token_usage_and_cost(
    stats_list: list[SessionStats],
    day_key: str,
    fallback_stats: SessionStats,
) -> tuple[TokenUsage, float]:
    usage = TokenUsage()
    cost = 0.0
    saw_token_dates = False

    for stats in stats_list:
        day_usage = stats.token_by_date.get(day_key)
        if day_usage is None:
            continue
        saw_token_dates = True
        _add_token_usage(usage, day_usage)

        model_map = stats.token_by_model_by_date.get(day_key)
        if model_map:
            cost += sum(
                _estimate_cost(model_usage, model)
                for model, model_usage in model_map.items()
            )
        elif stats.token_usage.total > 0:
            stats_cost = sum(
                _estimate_cost(model_usage, model)
                for model, model_usage in stats.token_by_model.items()
            )
            cost += stats_cost * day_usage.total / stats.token_usage.total

    if not saw_token_dates:
        usage = fallback_stats.token_usage
        cost = sum(
            _estimate_cost(model_usage, model)
            for model, model_usage in fallback_stats.token_by_model.items()
        )

    return usage, cost


def _daily_active_minutes(
    stats_list: list[SessionStats],
    day_key: str,
    fallback_stats: SessionStats,
) -> float:
    seconds = 0.0
    saw_token_dates = False
    for stats in stats_list:
        day_usage = stats.token_by_date.get(day_key)
        if day_usage is None:
            continue
        saw_token_dates = True
        if stats.token_usage.total > 0:
            seconds += (
                stats.active_duration.total_seconds()
                * day_usage.total
                / stats.token_usage.total
            )

    if not saw_token_dates:
        seconds = fallback_stats.active_duration.total_seconds()

    return round(seconds / 60, 1)


def _daily_stats_from_analyzed(
    all_stats: list[SessionStats],
    since_dt: datetime,
    days: int,
    now: datetime | None = None,
) -> list[dict]:
    date_keys = _daily_date_keys(since_dt, days, now=now)
    date_key_set = set(date_keys)
    daily: dict[str, list] = defaultdict(list)
    for stats in all_stats:
        if stats.token_by_date:
            for day_key, usage in stats.token_by_date.items():
                if usage.total > 0 and day_key in date_key_set:
                    daily[day_key].append(stats)
            continue
        if stats.start_time:
            day_key = stats.start_time.astimezone().strftime("%Y-%m-%d")
            if day_key in date_key_set:
                daily[day_key].append(stats)

    result = []
    for day_key in date_keys:
        day_stats = daily.get(day_key, [])
        if day_stats:
            merged = merge_stats(day_stats) if len(day_stats) > 1 else day_stats[0]
            usage, cost = _daily_token_usage_and_cost(day_stats, day_key, merged)
            active_minutes = _daily_active_minutes(day_stats, day_key, merged)
            result.append({
                "date": day_key,
                "sessions": len(day_stats),
                "messages": merged.user_message_count,
                "tool_calls": merged.tool_call_total,
                "active_minutes": active_minutes,
                "lines_added": merged.total_added,
                "lines_removed": merged.total_removed,
                "tokens": usage.total,
                "cost": round(cost, 2),
            })
        else:
            result.append({
                "date": day_key, "sessions": 0, "messages": 0, "tool_calls": 0,
                "active_minutes": 0, "lines_added": 0, "lines_removed": 0, "tokens": 0, "cost": 0,
            })
    return result


def _get_skill_stats(project_dir_name=None, since_days=None, source: str | None = None):
    """Return skill usage statistics as a list sorted by call_count.

    Skill stats always cover ALL sessions (ignoring since_days) because
    skill usage patterns are more meaningful at the all-time level.
    """
    files = _collect_session_files(project_dir_name, source=source)
    if not files:
        return []

    files.sort(key=lambda f: f.stat().st_mtime)

    all_stats = _analyze_session_files(files, project_dir_name=project_dir_name)

    if not all_stats:
        return []

    result = _merged_stats(all_stats)
    if result is None:
        return []

    skills = []
    for name, su in sorted(
        result.skill_stats.items(), key=lambda x: x[1].call_count, reverse=True
    ):
        resolved = su.success_count + su.error_count
        success_rate = (
            round(su.success_count / resolved * 100) if resolved > 0 else None
        )
        skills.append({
            "name": name,
            "call_count": su.call_count,
            "success_count": su.success_count,
            "error_count": su.error_count,
            "unknown_count": su.unknown_count,
            "success_rate": success_rate,
        })
    return skills


def _skill_stats_from_analyzed(all_stats: list[SessionStats]) -> list[dict]:
    result = _merged_stats(all_stats)
    if result is None:
        return []

    skills = []
    for name, su in sorted(
        result.skill_stats.items(), key=lambda x: x[1].call_count, reverse=True
    ):
        resolved = su.success_count + su.error_count
        success_rate = (
            round(su.success_count / resolved * 100) if resolved > 0 else None
        )
        skills.append({
            "name": name,
            "call_count": su.call_count,
            "success_count": su.success_count,
            "error_count": su.error_count,
            "unknown_count": su.unknown_count,
            "success_rate": success_rate,
        })
    return skills


def _get_dashboard_payload(
    project_dir_name=None,
    since_days=None,
    daily_days=30,
    source: str | None = None,
    period: str | None = None,
):
    all_stats = _get_cached_analyzed_stats(project_dir_name, source=source)
    if not all_stats:
        return {
            "stats": {"error": "No sessions found"},
            "daily_stats": [],
            "skills": [],
        }

    since_dt = None
    period_range = _dashboard_period_range(period)
    if period_range is not None:
        since_dt = period_range.since_dt
        stats_for_range = _stats_for_local_date_range(
            all_stats,
            period_range.since_date,
            period_range.until_date,
        )
        daily_days = period_range.daily_days
        daily_source_stats = stats_for_range
    elif since_days:
        since_dt = datetime.now(tz=timezone.utc) - timedelta(days=since_days)
        stats_for_range = [
            stats for stats in all_stats
            if not since_dt or not stats.end_time or stats.end_time >= since_dt
        ]
        daily_source_stats = all_stats
    else:
        stats_for_range = all_stats
        daily_source_stats = all_stats

    merged = _merged_stats(stats_for_range)
    if merged is None:
        if period_range is not None:
            stats_payload = _stats_to_dict(
                SessionStats(session_id="", project_path=str(project_dir_name or "")),
                session_count=0,
                git_scan_skipped=True,
            )
        else:
            stats_payload = {"error": "No valid sessions"}
    else:
        stats_payload = _stats_to_dict(
            merged,
            session_count=len(stats_for_range),
            git_scan_skipped=True,
        )

    daily_since = since_dt or datetime.now(tz=timezone.utc) - timedelta(days=daily_days)
    return {
        "stats": stats_payload,
        "daily_stats": _daily_stats_from_analyzed(daily_source_stats, daily_since, daily_days),
        "skills": _skill_stats_from_analyzed(all_stats),
    }


def _get_version_update():
    """检查版本更新（供 Web API 使用）"""
    try:
        from cc_stats.version_checker import check_for_update
        result = check_for_update()
        if result is not None:
            return {
                "has_update": True,
                "current_version": result.current_version,
                "latest_version": result.latest_version,
                "upgrade_command": result.upgrade_command,
            }
    except Exception:
        pass
    return {"has_update": False}


class ApiHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=_web_dir, **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)
        source = params.get("source", [None])[0]

        try:
            if path in {"", "/"}:
                self._serve_index()
            elif path == "/api/health":
                self._json({"status": "ok"})
            elif path == "/api/projects":
                self._json(_get_projects(source=source))
            elif path == "/api/stats":
                project = params.get("project", [None])[0]
                days = params.get("days", [None])[0]
                self._json(_get_stats(
                    project_dir_name=project or None,
                    since_days=int(days) if days and days != "0" else None,
                    source=source,
                ))
            elif path == "/api/dashboard":
                project = params.get("project", [None])[0]
                days = params.get("days", [None])[0]
                daily_days = params.get("daily_days", ["30"])[0]
                period = params.get("period", [None])[0]
                self._json(_get_dashboard_payload(
                    project_dir_name=project or None,
                    since_days=(
                        int(days) if not period and days and days != "0" else None
                    ),
                    daily_days=int(daily_days),
                    source=source,
                    period=period,
                ))
            elif path == "/api/daily_stats":
                project = params.get("project", [None])[0]
                days = params.get("days", ["14"])[0]
                self._json(_get_daily_stats(
                    project_dir_name=project or None,
                    days=int(days),
                    source=source,
                ))
            elif path == "/api/skills":
                project = params.get("project", [None])[0]
                days = params.get("days", [None])[0]
                self._json(_get_skill_stats(
                    project_dir_name=project or None,
                    since_days=int(days) if days and days != "0" else None,
                    source=source,
                ))
            elif path == "/api/version_check":
                self._json(_get_version_update())
            else:
                super().do_GET()
        except ValueError as exc:
            self._json({"error": str(exc)})

    def _json(self, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_index(self):
        index_path = Path(_web_dir) / "index.html"
        try:
            body = index_path.read_bytes()
        except OSError:
            self.send_error(404, "Dashboard index not found")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class CcStatsHTTPServer(ThreadingHTTPServer):
    daemon_threads = True


def _warm_dashboard_cache() -> None:
    try:
        _get_cached_analyzed_stats()
        _get_projects()
    except Exception:
        pass


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_server(warm_cache: bool = True) -> tuple[CcStatsHTTPServer, int]:
    port = find_free_port()
    server = CcStatsHTTPServer(("127.0.0.1", port), ApiHandler)
    if warm_cache:
        threading.Thread(target=_warm_dashboard_cache, daemon=True).start()
    return server, port
