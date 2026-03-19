"""生成 Markdown 周报/月报"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .analyzer import SessionStats, merge_stats, analyze_session
from .parser import find_sessions, parse_jsonl

# 模型定价 ($/M tokens)
_PRICING = {
    "opus": {"input": 15, "output": 75, "cache_read": 1.5, "cache_create": 18.75},
    "sonnet": {"input": 3, "output": 15, "cache_read": 0.3, "cache_create": 3.75},
    "haiku": {"input": 0.8, "output": 4, "cache_read": 0.08, "cache_create": 1.0},
}


def _match_pricing(model: str) -> dict:
    lower = model.lower()
    for key in ["opus", "haiku", "sonnet"]:
        if key in lower:
            return _PRICING[key]
    return _PRICING["sonnet"]


def _estimate_cost(stats: SessionStats) -> float:
    cost = 0.0
    for model, usage in stats.token_by_model.items():
        p = _match_pricing(model)
        cost += usage.input_tokens / 1e6 * p["input"]
        cost += usage.output_tokens / 1e6 * p["output"]
        cost += usage.cache_read_input_tokens / 1e6 * p["cache_read"]
        cost += usage.cache_creation_input_tokens / 1e6 * p["cache_create"]
    return cost


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


def _fmt_tokens(n: int) -> str:
    if n >= 1e9:
        return f"{n / 1e9:.1f}B"
    if n >= 1e6:
        return f"{n / 1e6:.1f}M"
    if n >= 1e3:
        return f"{n / 1e3:.1f}K"
    return str(n)


def _fmt_cost(n: float) -> str:
    if n >= 100:
        return f"${n:.0f}"
    if n >= 1:
        return f"${n:.2f}"
    return f"${n:.3f}"


def generate_report(period: str = "week") -> str:
    """生成周报或月报 Markdown

    Args:
        period: "week" 或 "month"
    """
    now = datetime.now(tz=timezone.utc)
    if period == "month":
        since = now - timedelta(days=30)
        title = "月报"
        title_en = "Monthly Report"
        days = 30
    else:
        since = now - timedelta(days=7)
        title = "周报"
        title_en = "Weekly Report"
        days = 7

    start_str = since.astimezone().strftime("%Y-%m-%d")
    end_str = now.astimezone().strftime("%Y-%m-%d")

    # 收集所有会话
    jsonl_files = [f for f in find_sessions() if not f.name.startswith("agent-")]
    jsonl_files.sort(key=lambda f: f.stat().st_mtime)

    all_stats: list[SessionStats] = []
    daily: dict[str, list[SessionStats]] = defaultdict(list)

    for f in jsonl_files:
        try:
            session = parse_jsonl(f)
            stats = analyze_session(session)
            if stats.end_time and stats.end_time < since:
                continue
            all_stats.append(stats)
            if stats.start_time:
                day_key = stats.start_time.astimezone().strftime("%Y-%m-%d")
                daily[day_key].append(stats)
        except Exception:
            continue

    if not all_stats:
        return f"# Claude Code {title} ({start_str} ~ {end_str})\n\n> 该时段无会话数据。\n"

    merged = merge_stats(all_stats) if len(all_stats) > 1 else all_stats[0]
    cost = _estimate_cost(merged)

    # 按项目分组
    project_stats: dict[str, list[SessionStats]] = defaultdict(list)
    for s in all_stats:
        proj = s.project_path or "Unknown"
        proj_name = Path(proj).name if proj != "all" else proj
        project_stats[proj_name].append(s)

    # 每日统计
    daily_lines = []
    today = datetime.now().date()
    for i in range(days - 1, -1, -1):
        d = today - timedelta(days=i)
        day_key = d.strftime("%Y-%m-%d")
        day_stats_list = daily.get(day_key, [])
        if day_stats_list:
            ds = merge_stats(day_stats_list) if len(day_stats_list) > 1 else day_stats_list[0]
            dc = _estimate_cost(ds)
            daily_lines.append(
                f"| {day_key} | {len(day_stats_list)} | {ds.user_message_count} | "
                f"{_fmt_duration(ds.active_duration)} | {_fmt_tokens(ds.token_usage.total)} | {_fmt_cost(dc)} |"
            )

    # 工具调用 Top 5
    sorted_tools = sorted(merged.tool_call_counts.items(), key=lambda x: x[1], reverse=True)[:5]

    # 语言统计
    sorted_langs = sorted(merged.lines_by_lang.items(), key=lambda x: x[1]["added"], reverse=True)[:5]

    # 生成 Markdown
    lines = [
        f"# Claude Code {title}",
        f"",
        f"**{start_str} ~ {end_str}**",
        f"",
        f"## 概览",
        f"",
        f"| 指标 | 数值 |",
        f"|------|------|",
        f"| 会话数 | {len(all_stats)} |",
        f"| 指令数 | {merged.user_message_count} |",
        f"| 工具调用 | {merged.tool_call_total} |",
        f"| 活跃时长 | {_fmt_duration(merged.active_duration)} |",
        f"| AI 处理 | {_fmt_duration(merged.ai_duration)} |",
        f"| 用户活跃 | {_fmt_duration(merged.user_duration)} |",
        f"| Token 消耗 | {_fmt_tokens(merged.token_usage.total)} |",
        f"| 预估费用 | {_fmt_cost(cost)} |",
        f"| 代码新增 | +{merged.total_added} |",
        f"| 代码删除 | -{merged.total_removed} |",
    ]

    if merged.git_available:
        lines.append(f"| Git Commits | {merged.git_commit_count} |")

    lines += [
        f"",
        f"## 每日明细",
        f"",
        f"| 日期 | 会话 | 指令 | 活跃时长 | Token | 费用 |",
        f"|------|------|------|----------|-------|------|",
    ]
    lines.extend(daily_lines)

    if sorted_tools:
        lines += [
            f"",
            f"## 工具调用 Top 5",
            f"",
            f"| 工具 | 次数 |",
            f"|------|------|",
        ]
        for name, count in sorted_tools:
            lines.append(f"| {name} | {count} |")

    if sorted_langs:
        lines += [
            f"",
            f"## 代码变更（按语言）",
            f"",
            f"| 语言 | 新增 | 删除 | 净增 |",
            f"|------|------|------|------|",
        ]
        for lang, counts in sorted_langs:
            net = counts["added"] - counts["removed"]
            sign = "+" if net >= 0 else ""
            lines.append(f"| {lang} | +{counts['added']} | -{counts['removed']} | {sign}{net} |")

    if merged.token_by_model:
        lines += [
            f"",
            f"## Token 消耗（按模型）",
            f"",
            f"| 模型 | Token | 费用 |",
            f"|------|-------|------|",
        ]
        for model, usage in sorted(merged.token_by_model.items(), key=lambda x: x[1].total, reverse=True):
            mc = 0.0
            p = _match_pricing(model)
            mc += usage.input_tokens / 1e6 * p["input"]
            mc += usage.output_tokens / 1e6 * p["output"]
            mc += usage.cache_read_input_tokens / 1e6 * p["cache_read"]
            mc += usage.cache_creation_input_tokens / 1e6 * p["cache_create"]
            lines.append(f"| {model} | {_fmt_tokens(usage.total)} | {_fmt_cost(mc)} |")

    if len(project_stats) > 1:
        lines += [
            f"",
            f"## 项目分布",
            f"",
            f"| 项目 | 会话 | 指令 | 费用 |",
            f"|------|------|------|------|",
        ]
        for proj_name, stats_list in sorted(project_stats.items(), key=lambda x: len(x[1]), reverse=True)[:10]:
            pm = merge_stats(stats_list) if len(stats_list) > 1 else stats_list[0]
            pc = _estimate_cost(pm)
            lines.append(f"| {proj_name} | {len(stats_list)} | {pm.user_message_count} | {_fmt_cost(pc)} |")

    lines += [
        f"",
        f"---",
        f"*Generated by [cc-statistics](https://github.com/androidZzT/cc-statistics)*",
    ]

    return "\n".join(lines)
