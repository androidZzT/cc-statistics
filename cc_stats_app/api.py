"""Python → JS 数据桥接层（pywebview js_api）"""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cc_stats.analyzer import SessionStats, TokenUsage, analyze_session, merge_stats
from cc_stats.parser import find_sessions, parse_jsonl


def _resolve_project_name(proj_dir: Path, jsonl_files: list[Path]) -> str:
    """从 JSONL 文件中的 cwd 字段还原项目真实路径"""
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
    """将 SessionStats 序列化为 JSON 可传输的 dict"""

    def _td_seconds(td: timedelta) -> float:
        return td.total_seconds()

    def _fmt_duration(td: timedelta) -> str:
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

    def _token_usage_dict(tu: TokenUsage) -> dict:
        return {
            "input_tokens": tu.input_tokens,
            "output_tokens": tu.output_tokens,
            "cache_read": tu.cache_read_input_tokens,
            "cache_creation": tu.cache_creation_input_tokens,
            "total": tu.total,
        }

    # 工具调用按数量排序
    sorted_tools = sorted(stats.tool_call_counts.items(), key=lambda x: x[1], reverse=True)

    # 语言统计按 added 排序
    sorted_langs = sorted(stats.lines_by_lang.items(), key=lambda x: x[1]["added"], reverse=True)

    # Git 语言统计
    sorted_git_langs = sorted(stats.git_lines_by_lang.items(), key=lambda x: x[1]["added"], reverse=True)

    # Token by model
    model_tokens = []
    for model, usage in sorted(stats.token_by_model.items(), key=lambda x: x[1].total, reverse=True):
        model_tokens.append({"model": model, **_token_usage_dict(usage)})

    return {
        "session_count": session_count,
        "user_message_count": stats.user_message_count,
        "tool_call_total": stats.tool_call_total,
        "tool_calls": [{"name": name, "count": count} for name, count in sorted_tools],
        "start_time": stats.start_time.isoformat() if stats.start_time else None,
        "end_time": stats.end_time.isoformat() if stats.end_time else None,
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
        "lines_by_lang": [{"lang": lang, **counts} for lang, counts in sorted_langs],
        "git_available": stats.git_available,
        "git_total_added": stats.git_total_added,
        "git_total_removed": stats.git_total_removed,
        "git_commit_count": stats.git_commit_count,
        "git_lines_by_lang": [{"lang": lang, **counts} for lang, counts in sorted_git_langs],
        "token_usage": _token_usage_dict(stats.token_usage),
        "token_by_model": model_tokens,
    }


def _get_project_sessions(project_dir: Path) -> list[Path]:
    """获取指定项目目录下的所有会话文件"""
    return find_sessions(project_dir)


class Api:
    """pywebview js_api — 前端通过 window.pywebview.api.xxx() 调用"""

    def get_projects(self) -> list[dict]:
        """返回所有项目列表"""
        claude_projects = Path.home() / ".claude" / "projects"
        if not claude_projects.exists():
            return []

        projects = []
        for proj in sorted(claude_projects.iterdir()):
            if not proj.is_dir():
                continue
            jsonl_files = list(proj.glob("*.jsonl"))
            if not jsonl_files:
                continue
            display_name = _resolve_project_name(proj, jsonl_files)
            projects.append({
                "dir_name": proj.name,
                "display_name": display_name,
                "session_count": len(jsonl_files),
            })

        # 按会话数量降序
        projects.sort(key=lambda x: x["session_count"], reverse=True)
        return projects

    def get_stats(
        self,
        project_dir_name: str | None = None,
        last_n: int | None = None,
        since_days: int | None = None,
    ) -> dict:
        """获取项目统计数据

        Args:
            project_dir_name: 项目目录名（如 -Users-foo-bar），None 表示全部
            last_n: 只分析最近 N 个会话
            since_days: 只包含最近 N 天的会话
        """
        claude_projects = Path.home() / ".claude" / "projects"

        if project_dir_name:
            proj_dir = claude_projects / project_dir_name
            jsonl_files = sorted(proj_dir.glob("*.jsonl"))
        else:
            jsonl_files = find_sessions()

        if not jsonl_files:
            return {"error": "未找到会话文件"}

        # 按修改时间排序
        jsonl_files.sort(key=lambda f: f.stat().st_mtime)

        if last_n:
            jsonl_files = jsonl_files[-last_n:]

        # 时间过滤
        since_dt = None
        if since_days:
            since_dt = datetime.now(tz=timezone.utc) - timedelta(days=since_days)

        all_stats = []
        for f in jsonl_files:
            try:
                session = parse_jsonl(f)
                stats = analyze_session(session)

                if since_dt and stats.end_time and stats.end_time < since_dt:
                    continue

                all_stats.append(stats)
            except Exception:
                continue

        if not all_stats:
            return {"error": "无有效会话数据"}

        if len(all_stats) == 1:
            result = all_stats[0]
        else:
            result = merge_stats(all_stats)

        return _stats_to_dict(result, session_count=len(all_stats))

    def get_daily_stats(
        self,
        project_dir_name: str | None = None,
        days: int = 30,
    ) -> list[dict]:
        """按天聚合统计数据，用于趋势图

        返回最近 N 天每天的统计摘要。
        """
        claude_projects = Path.home() / ".claude" / "projects"

        if project_dir_name:
            proj_dir = claude_projects / project_dir_name
            jsonl_files = sorted(proj_dir.glob("*.jsonl"))
        else:
            jsonl_files = find_sessions()

        if not jsonl_files:
            return []

        since_dt = datetime.now(tz=timezone.utc) - timedelta(days=days)

        # 按天分组
        daily: dict[str, list[SessionStats]] = defaultdict(list)

        for f in jsonl_files:
            try:
                session = parse_jsonl(f)
                stats = analyze_session(session)

                if stats.end_time and stats.end_time < since_dt:
                    continue
                if not stats.start_time:
                    continue

                # 以本地日期为 key
                day_key = stats.start_time.astimezone().strftime("%Y-%m-%d")
                daily[day_key].append(stats)
            except Exception:
                continue

        # 生成每日摘要
        result = []
        today = datetime.now().date()
        for i in range(days - 1, -1, -1):
            d = today - timedelta(days=i)
            day_key = d.strftime("%Y-%m-%d")
            day_stats = daily.get(day_key, [])

            if day_stats:
                merged = merge_stats(day_stats) if len(day_stats) > 1 else day_stats[0]
                result.append({
                    "date": day_key,
                    "sessions": len(day_stats),
                    "messages": merged.user_message_count,
                    "tool_calls": merged.tool_call_total,
                    "active_minutes": round(merged.active_duration.total_seconds() / 60, 1),
                    "lines_added": merged.total_added,
                    "lines_removed": merged.total_removed,
                    "tokens": merged.token_usage.total,
                })
            else:
                result.append({
                    "date": day_key,
                    "sessions": 0,
                    "messages": 0,
                    "tool_calls": 0,
                    "active_minutes": 0,
                    "lines_added": 0,
                    "lines_removed": 0,
                    "tokens": 0,
                })

        return result
