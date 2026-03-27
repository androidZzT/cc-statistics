"""HTTP server: static files + JSON API"""

from __future__ import annotations

import json
import os
import socket
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

from cc_stats.analyzer import SessionStats, TokenUsage, analyze_session, merge_stats
from cc_stats.parser import (
    find_gemini_sessions,
    find_sessions,
    parse_gemini_json,
    parse_jsonl,
)

_web_dir = os.path.join(os.path.dirname(__file__), "web")

# Model pricing ($/M tokens)
_PRICING = {
    "opus": {"input": 15, "output": 75, "cache_read": 1.5, "cache_create": 18.75},
    "sonnet": {"input": 3, "output": 15, "cache_read": 0.3, "cache_create": 3.75},
    "haiku": {"input": 0.8, "output": 4, "cache_read": 0.08, "cache_create": 1.0},
    "gpt-4o": {"input": 2.5, "output": 10, "cache_read": 1.25, "cache_create": 2.5},
    "o1": {"input": 15, "output": 60, "cache_read": 7.5, "cache_create": 15},
    "o3": {"input": 10, "output": 40, "cache_read": 2.5, "cache_create": 10},
    "gemini-2.5-pro": {"input": 1.25, "output": 10, "cache_read": 0.31, "cache_create": 1.25},
    "gemini-2.5-flash": {"input": 0.15, "output": 0.60, "cache_read": 0.04, "cache_create": 0.15},
    "gemini-2.0-flash": {"input": 0.10, "output": 0.40, "cache_read": 0.025, "cache_create": 0.10},
}


def _match_pricing(model: str) -> dict:
    lower = model.lower()
    # Gemini models (exact match first)
    for key in ("gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"):
        if key in lower:
            return _PRICING[key]
    if "gemini" in lower:
        return _PRICING["gemini-2.5-flash"]
    for key in ["opus", "haiku", "sonnet", "gpt-4o", "o1", "o3"]:
        if key in lower:
            return _PRICING[key]
    return _PRICING["sonnet"]


def _estimate_cost(tu: TokenUsage, model: str = "") -> float:
    p = _match_pricing(model)
    cost = 0.0
    cost += tu.input_tokens / 1e6 * p["input"]
    cost += tu.output_tokens / 1e6 * p["output"]
    cost += tu.cache_read_input_tokens / 1e6 * p["cache_read"]
    cost += tu.cache_creation_input_tokens / 1e6 * p["cache_create"]
    return cost


def _resolve_project_name(proj_dir, jsonl_files):
    for jf in jsonl_files:
        try:
            with open(jf, encoding="utf-8") as fh:
                for ln in fh:
                    try:
                        obj = json.loads(ln)
                        if obj.get("cwd"):
                            return obj["cwd"]
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        continue
        except OSError:
            continue
    return proj_dir.name


def _stats_to_dict(stats: SessionStats, session_count: int = 1) -> dict:
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
        cost = _estimate_cost(usage, model)
        total_cost += cost
        model_tokens.append({
            "model": model,
            **_token_dict(usage),
            "cost": round(cost, 4),
        })

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
        "token_usage": _token_dict(stats.token_usage),
        "token_by_model": model_tokens,
        "estimated_cost": round(total_cost, 2),
    }


def _get_projects():
    from pathlib import Path
    projects = []

    # Claude projects
    claude_projects = Path.home() / ".claude" / "projects"
    if claude_projects.exists():
        for proj in sorted(claude_projects.iterdir()):
            if not proj.is_dir():
                continue
            jsonl_files = [f for f in proj.glob("*.jsonl") if not f.name.startswith("agent-")]
            if not jsonl_files:
                continue
            display_name = _resolve_project_name(proj, jsonl_files)
            projects.append({
                "dir_name": proj.name,
                "display_name": display_name,
                "session_count": len(jsonl_files),
                "source": "claude",
            })

    # Gemini projects
    gemini_files = find_gemini_sessions()
    if gemini_files:
        gemini_by_dir: dict[str, list] = {}
        for gf in gemini_files:
            dir_key = gf.parent.parent.name  # project hash
            gemini_by_dir.setdefault(dir_key, []).append(gf)
        for dir_key, files in gemini_by_dir.items():
            # Try to get project path from first session
            display_name = dir_key
            try:
                session = parse_gemini_json(files[0])
                if session.project_path:
                    display_name = session.project_path
            except Exception:
                pass
            projects.append({
                "dir_name": f"gemini:{dir_key}",
                "display_name": display_name,
                "session_count": len(files),
                "source": "gemini",
            })

    projects.sort(key=lambda x: x["session_count"], reverse=True)
    return projects


def _collect_session_files(project_dir_name=None):
    """Collect session files (Claude JSONL + Gemini JSON)"""
    from pathlib import Path
    files = []

    if project_dir_name and project_dir_name.startswith("gemini:"):
        # Gemini project
        dir_key = project_dir_name[7:]
        for gf in find_gemini_sessions():
            if gf.parent.parent.name == dir_key:
                files.append(gf)
    elif project_dir_name:
        # Claude project
        claude_projects = Path.home() / ".claude" / "projects"
        proj_dir = claude_projects / project_dir_name
        files = sorted(f for f in proj_dir.glob("*.jsonl") if not f.name.startswith("agent-"))
    else:
        # All sources
        files = [f for f in find_sessions() if not f.name.startswith("agent-")]
        files.extend(find_gemini_sessions())

    return files


def _parse_session_file(f):
    """Parse a session file based on its extension"""
    if f.suffix == ".json":
        return parse_gemini_json(f)
    return parse_jsonl(f)


def _get_stats(project_dir_name=None, since_days=None):
    files = _collect_session_files(project_dir_name)
    if not files:
        return {"error": "No sessions found"}

    files.sort(key=lambda f: f.stat().st_mtime)

    since_dt = None
    if since_days:
        since_dt = datetime.now(tz=timezone.utc) - timedelta(days=since_days)

    all_stats = []
    for f in files:
        try:
            session = _parse_session_file(f)
            stats = analyze_session(session)
            if since_dt and stats.end_time and stats.end_time < since_dt:
                continue
            all_stats.append(stats)
        except Exception:
            continue

    if not all_stats:
        return {"error": "No valid sessions"}

    result = all_stats[0] if len(all_stats) == 1 else merge_stats(all_stats)
    return _stats_to_dict(result, session_count=len(all_stats))


def _get_daily_stats(project_dir_name=None, days=14):
    files = _collect_session_files(project_dir_name)

    since_dt = datetime.now(tz=timezone.utc) - timedelta(days=days)
    daily: dict[str, list] = defaultdict(list)

    for f in files:
        try:
            session = _parse_session_file(f)
            stats = analyze_session(session)
            if stats.end_time and stats.end_time < since_dt:
                continue
            if not stats.start_time:
                continue
            day_key = stats.start_time.astimezone().strftime("%Y-%m-%d")
            daily[day_key].append(stats)
        except Exception:
            continue

    result = []
    today = datetime.now().date()
    for i in range(days - 1, -1, -1):
        d = today - timedelta(days=i)
        day_key = d.strftime("%Y-%m-%d")
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


def _get_skill_stats(project_dir_name=None, since_days=None):
    """Return skill usage statistics as a list sorted by call_count.

    Skill stats always cover ALL sessions (ignoring since_days) because
    skill usage patterns are more meaningful at the all-time level.
    """
    files = _collect_session_files(project_dir_name)
    if not files:
        return []

    files.sort(key=lambda f: f.stat().st_mtime)

    all_stats = []
    for f in files:
        try:
            session = _parse_session_file(f)
            stats = analyze_session(session)
            all_stats.append(stats)
        except Exception:
            continue

    if not all_stats:
        return []

    result = all_stats[0] if len(all_stats) == 1 else merge_stats(all_stats)

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

        if path == "/api/projects":
            self._json(_get_projects())
        elif path == "/api/stats":
            project = params.get("project", [None])[0]
            days = params.get("days", [None])[0]
            self._json(_get_stats(
                project_dir_name=project or None,
                since_days=int(days) if days and days != "0" else None,
            ))
        elif path == "/api/daily_stats":
            project = params.get("project", [None])[0]
            days = params.get("days", ["14"])[0]
            self._json(_get_daily_stats(
                project_dir_name=project or None,
                days=int(days),
            ))
        elif path == "/api/skills":
            project = params.get("project", [None])[0]
            days = params.get("days", [None])[0]
            self._json(_get_skill_stats(
                project_dir_name=project or None,
                since_days=int(days) if days and days != "0" else None,
            ))
        elif path == "/api/version_check":
            self._json(_get_version_update())
        else:
            super().do_GET()

    def _json(self, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_server() -> tuple[HTTPServer, int]:
    port = find_free_port()
    server = HTTPServer(("127.0.0.1", port), ApiHandler)
    return server, port
