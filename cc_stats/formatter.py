"""格式化统计结果输出（带 ANSI 色彩）"""

from __future__ import annotations

import os
import unicodedata
from datetime import timedelta

from .analyzer import (
    TOOL_DESCRIPTIONS,
    CacheStats,
    SessionStats,
    SkillUsage,
    compute_cache_stats,
)
from .rate_limiter import RateLimitStatus


# ── ANSI 色彩 ──────────────────────────────────────────────
def _supports_color() -> bool:
    """检测终端是否支持色彩"""
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    return hasattr(os, "isatty") and os.isatty(1)


_COLOR = _supports_color()


def _c(code: str, text: str) -> str:
    """给文本加 ANSI 色彩"""
    if not _COLOR:
        return text
    return f"\033[{code}m{text}\033[0m"


# 常用颜色快捷方式
def _bold(t: str) -> str: return _c("1", t)
def _dim(t: str) -> str: return _c("2", t)
def _cyan(t: str) -> str: return _c("36", t)
def _green(t: str) -> str: return _c("32", t)
def _red(t: str) -> str: return _c("31", t)
def _yellow(t: str) -> str: return _c("33", t)
def _blue(t: str) -> str: return _c("34", t)
def _magenta(t: str) -> str: return _c("35", t)
def _white_bold(t: str) -> str: return _c("1;37", t)
def _cyan_bold(t: str) -> str: return _c("1;36", t)
def _green_bold(t: str) -> str: return _c("1;32", t)


# ── 格式化辅助 ─────────────────────────────────────────────

def _fmt_duration(td: timedelta) -> str:
    """将 timedelta 格式化为可读字符串"""
    total_seconds = int(td.total_seconds())
    if total_seconds < 0:
        return "0s"
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    parts = []
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    if seconds or not parts:
        parts.append(f"{seconds}s")
    return " ".join(parts)


def _display_width(s: str) -> int:
    """计算字符串的终端显示宽度（CJK 字符占 2 列）"""
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)


def _report_title(sources: set[str]) -> str:
    """根据会话来源选择报告标题"""
    if not sources or sources == {"claude"}:
        return "Claude Code 会话统计报告"
    if sources == {"codex"}:
        return "Codex 会话统计报告"
    if sources == {"gemini"}:
        return "Gemini CLI 会话统计报告"
    return "AI Coding 会话统计报告"


def _fmt_tokens(n: int) -> str:
    """格式化 token 数量"""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K"
    return str(n)


def _bar(value: int, max_value: int, width: int = 20) -> str:
    """生成带颜色的柱状图"""
    if max_value == 0:
        return ""
    filled = int(value / max_value * width)
    bar_filled = "█" * filled
    bar_empty = "░" * (width - filled)
    return _cyan(bar_filled) + _dim(bar_empty)


def _net_str(net: int) -> str:
    """格式化净增数（带颜色）"""
    if net > 0:
        return _green(f"+{net}")
    elif net < 0:
        return _red(str(net))
    return _dim("0")


# ── 缓存命中率 ─────────────────────────────────────────────

_CACHE_GRADE_COLORS = {
    "excellent": _green,
    "good": _blue,
    "fair": _yellow,
    "poor": _red,
    "na": _dim,
}

_CACHE_GRADE_TIPS = {
    "excellent": "Great! Prompts are well-cached",
    "good": "Good cache utilization",
    "fair": "Room to improve caching",
    "poor": "Low cache hit rate",
    "na": "No cache data available",
}


def format_cache_stats(cache: CacheStats) -> str:
    """格式化缓存命中率分析子区块"""
    lines: list[str] = []

    color_fn = _CACHE_GRADE_COLORS.get(cache.grade, _dim)
    tip = _CACHE_GRADE_TIPS.get(cache.grade, "")

    lines.append(f"  {_dim('缓存命中率:')}")

    if cache.grade == "na":
        lines.append(f"    {_dim('N/A')} — {_dim(tip)}")
        lines.append("")
        return "\n".join(lines)

    pct = f"{cache.hit_rate * 100:.1f}%"
    lines.append(f"    {color_fn(f'{cache.grade_label} ({pct})')} — {_dim(tip)}")
    lines.append(
        f"    cache_read: {_fmt_tokens(cache.cache_read_tokens)} / "
        f"total_input: {_fmt_tokens(cache.total_input_tokens)}"
    )

    if cache.savings_usd > 0:
        lines.append(f"    节省费用: {_green(f'~${cache.savings_usd:.2f}')}")

    if len(cache.by_model) > 1:
        lines.append(f"    {_dim('按模型:')}")
        for model, rate in sorted(cache.by_model.items(), key=lambda x: x[1], reverse=True):
            m_color = _CACHE_GRADE_COLORS.get(_cache_grade_key(rate), _dim)
            lines.append(f"      {_cyan(model)}: {m_color(f'{rate * 100:.1f}%')}")

    lines.append("")
    return "\n".join(lines)


def _cache_grade_key(hit_rate: float) -> str:
    """返回命中率对应的 grade key（用于颜色查找）"""
    if hit_rate >= 0.80:
        return "excellent"
    if hit_rate >= 0.60:
        return "good"
    if hit_rate >= 0.40:
        return "fair"
    return "poor"


# ── 主格式化 ───────────────────────────────────────────────

def format_stats(stats: SessionStats, session_count: int = 1) -> str:
    """将统计结果格式化为终端输出"""
    lines: list[str] = []
    sep = _dim("─" * 60)

    # ── Header ──
    title = _report_title(getattr(stats, "sources", set()))
    inner_width = 58  # 与 ╔══...══╗ 顶/底边内宽保持一致
    title_w = _display_width(title)
    left_pad = max((inner_width - title_w) // 2, 0)
    right_pad = max(inner_width - title_w - left_pad, 0)
    title_line = " " * left_pad + title + " " * right_pad
    lines.append("")
    lines.append(_cyan("  ╔" + "═" * inner_width + "╗"))
    lines.append(_cyan("  ║") + _white_bold(title_line) + _cyan("║"))
    lines.append(_cyan("  ╚" + "═" * inner_width + "╝"))
    lines.append("")

    if stats.project_path and stats.project_path != "all":
        lines.append(f"  {_dim('项目:')} {_bold(stats.project_path)}")
    if session_count > 1:
        lines.append(f"  {_dim('会话数:')} {_bold(str(session_count))}")
    if stats.start_time:
        start_local = stats.start_time.astimezone()
        end_local = stats.end_time.astimezone() if stats.end_time else None
        end_str = end_local.strftime('%Y-%m-%d %H:%M') if end_local else '?'
        lines.append(f"  {_dim('时间范围:')} {start_local.strftime('%Y-%m-%d %H:%M')} ~ {end_str}")
    lines.append("")

    # ── ① 用户指令数 ──
    lines.append(f"  {_cyan_bold('①')} {_bold('用户指令数')}")
    lines.append(sep)
    lines.append(f"  对话轮次: {_yellow(str(stats.user_message_count))}")
    lines.append("")

    # ── ② AI 工具调用 ──
    lines.append(f"  {_cyan_bold('②')} {_bold('AI 工具调用')}")
    lines.append(sep)
    lines.append(f"  总调用次数: {_yellow(str(stats.tool_call_total))}")
    lines.append("")
    if stats.tool_call_counts:
        sorted_tools = sorted(
            stats.tool_call_counts.items(), key=lambda x: x[1], reverse=True
        )
        max_count = sorted_tools[0][1] if sorted_tools else 1
        max_name_len = max(len(name) for name, _ in sorted_tools)

        for name, count in sorted_tools:
            desc = TOOL_DESCRIPTIONS.get(name, "")
            bar = _bar(count, max_count, 15)
            desc_part = f"  {_dim(desc)}" if desc else ""
            lines.append(
                f"  {_bold(f'{name:<{max_name_len}}')}  {bar} {_yellow(f'{count:>5}')}{desc_part}"
            )
    lines.append("")

    # ── ③ 开发时长 ──
    lines.append(f"  {_cyan_bold('③')} {_bold('开发时长')}")
    lines.append(sep)
    lines.append(f"  活跃时长:     {_green_bold(_fmt_duration(stats.active_duration))}")
    lines.append(f"    {_blue('AI 处理:')}    {_blue(_fmt_duration(stats.ai_duration))}")
    lines.append(f"    {_magenta('用户活跃:')}  {_magenta(_fmt_duration(stats.user_duration))}")
    if stats.active_duration.total_seconds() > 0:
        ai_ratio = stats.ai_duration.total_seconds() / stats.active_duration.total_seconds() * 100
        lines.append(f"  AI 占比:      {_blue(f'{ai_ratio:.0f}%')}")
    if stats.turn_count:
        avg_ai = stats.ai_duration / stats.turn_count
        lines.append(f"  平均轮次耗时: {_fmt_duration(avg_ai)}/轮 {_dim(f'({stats.turn_count} 轮)')}")
    lines.append("")

    # ── ④ 代码变更 ──
    lines.append(f"  {_cyan_bold('④')} {_bold('代码变更')}")
    lines.append(sep)

    if stats.git_available:
        git_net = stats.git_total_added - stats.git_total_removed
        ai_pct = (
            f" ({stats.git_ai_commit_count}/{stats.git_commit_count} AI)"
            if stats.git_ai_commit_count > 0
            else ""
        )
        lines.append(f"  {_yellow('[Git 已提交]')}  {stats.git_commit_count} 个 commit{_cyan(ai_pct)}")
        lines.append(f"  总新增: {_green(f'+{stats.git_total_added}')}  总删除: {_red(f'-{stats.git_total_removed}')}  净增: {_net_str(git_net)}")
        if stats.git_ai_commit_count > 0:
            ai_code_pct = round(
                (stats.git_ai_added + stats.git_ai_removed)
                / max(stats.git_total_added + stats.git_total_removed, 1)
                * 100
            )
            lines.append(
                f"  AI 代码: {_cyan(f'+{stats.git_ai_added}')} {_cyan(f'-{stats.git_ai_removed}')}  "
                f"占比: {_cyan(f'{ai_code_pct}%')}"
            )
        lines.append("")

        if stats.git_lines_by_lang:
            sorted_langs = sorted(
                stats.git_lines_by_lang.items(),
                key=lambda x: x[1]["added"] + x[1]["removed"],
                reverse=True,
            )
            max_lang_len = max(len(lang) for lang, _ in sorted_langs)
            for lang, counts in sorted_langs:
                added = counts["added"]
                removed = counts["removed"]
                net_l = added - removed
                lines.append(
                    f"  {_dim(f'{lang:<{max_lang_len}}')}  {_green(f'+{added:<6}')} {_red(f'-{removed:<6}')} net {_net_str(net_l)}"
                )
        lines.append("")

    ai_net = stats.total_added - stats.total_removed
    lines.append(f"  {_blue('[AI 工具变更]')}  {_dim('来自 Edit/Write 调用')}")
    lines.append(f"  总新增: {_green(f'+{stats.total_added}')}  总删除: {_red(f'-{stats.total_removed}')}  净增: {_net_str(ai_net)}")
    lines.append("")

    if stats.lines_by_lang:
        sorted_langs = sorted(
            stats.lines_by_lang.items(),
            key=lambda x: x[1]["added"] + x[1]["removed"],
            reverse=True,
        )
        max_lang_len = max(len(lang) for lang, _ in sorted_langs)
        for lang, counts in sorted_langs:
            added = counts["added"]
            removed = counts["removed"]
            net_l = added - removed
            lines.append(
                f"  {_dim(f'{lang:<{max_lang_len}}')}  {_green(f'+{added:<6}')} {_red(f'-{removed:<6}')} net {_net_str(net_l)}"
            )
    lines.append("")

    # ── ⑤ Token 消耗 ──
    lines.append(f"  {_cyan_bold('⑤')} {_bold('Token 消耗')}")
    lines.append(sep)
    tu = stats.token_usage
    lines.append(f"  Input tokens:          {_fmt_tokens(tu.input_tokens):>10}")
    lines.append(f"  Output tokens:         {_yellow(_fmt_tokens(tu.output_tokens)):>22}")
    lines.append(f"  Cache read tokens:     {_dim(_fmt_tokens(tu.cache_read_input_tokens)):>22}")
    lines.append(f"  Cache creation tokens: {_dim(_fmt_tokens(tu.cache_creation_input_tokens)):>22}")
    lines.append(f"  {_dim('─' * 40)}")
    lines.append(f"  合计:                  {_white_bold(_fmt_tokens(tu.total)):>22}")
    lines.append("")

    if stats.token_by_model:
        lines.append(f"  {_dim('按模型拆分:')}")
        for model, usage in sorted(stats.token_by_model.items()):
            if usage.total == 0:
                continue
            lines.append(
                f"    {_cyan(model)}: "
                f"input={_fmt_tokens(usage.input_tokens)} "
                f"output={_yellow(_fmt_tokens(usage.output_tokens))} "
                f"cache_read={_dim(_fmt_tokens(usage.cache_read_input_tokens))} "
                f"total={_bold(_fmt_tokens(usage.total))}"
            )
    lines.append("")

    # ── 缓存命中率分析（⑤ 子区块） ──
    cache = compute_cache_stats(stats.token_usage, stats.token_by_model)
    lines.append(format_cache_stats(cache))

    # ⑥ 效率评分
    total_tokens = stats.token_usage.total
    total_code = stats.total_added + stats.total_removed
    if total_tokens > 0 and stats.user_message_count > 0:
        avg_tokens_per_msg = total_tokens // stats.user_message_count
        code_per_1k = round(total_code / max(total_tokens / 1000, 1), 2)
        active_secs = stats.active_duration.total_seconds()
        ai_secs = stats.ai_duration.total_seconds()
        ai_ratio = round(ai_secs / max(active_secs, 1) * 100)

        code_score = min(40, int(code_per_1k / 0.5 * 40))
        precision_score = max(0, min(30, int((1 - min(avg_tokens_per_msg, 200_000) / 200_000) * 30)))
        util_score = min(30, int(ai_ratio / 70 * 30))
        total_score = code_score + precision_score + util_score
        grade = "S" if total_score >= 90 else "A" if total_score >= 75 else "B" if total_score >= 60 else "C" if total_score >= 40 else "D"

        grade_color = _green if grade in ("S", "A") else _yellow if grade == "B" else _red
        lines.append(f"  {_bold('⑥ 效率评分')}")
        lines.append("─" * 60)
        lines.append(f"  评分: {grade_color(f'{grade} ({total_score}/100)')}")
        lines.append(f"  代码产出: {_fmt_tokens(total_code)} 行 / {_fmt_tokens(total_tokens)} Token = {_cyan(f'{code_per_1k} 行/K')}")
        lines.append(f"  指令精准: {_fmt_tokens(avg_tokens_per_msg)} Token/条")
        lines.append(f"  AI 利用率: {ai_ratio}%")
        lines.append("")

    # ── ⑧ 编码节奏与工作模式 ──
    rhythm_block = format_coding_rhythm(stats)
    if rhythm_block:
        lines.append(rhythm_block)

    # ── ⑨ Usage Quota 预测 ──
    # 同一管道收集多个滚动窗口：
    #   Claude 5-min  — 仅当存在 Claude 用量
    #   Codex 5h / 7d — 优先用 OpenAI 后端 snapshot（rate_limits.primary/secondary 真值百分比），
    #                   会话里没带 snapshot 时回退到本地按小时分桶估算
    from .pricing import is_claude_model
    from .rate_limiter import (
        analyze_codex_quota_snapshot,
        analyze_codex_window,
        analyze_rate_limit,
    )

    statuses: list[RateLimitStatus] = []
    if any(is_claude_model(m) for m in getattr(stats, "token_by_model", {}).keys()):
        statuses.append(analyze_rate_limit(stats))

    if "codex" in getattr(stats, "sources", set()):
        snapshot_statuses = analyze_codex_quota_snapshot(stats)
        if snapshot_statuses:
            statuses.extend(snapshot_statuses)
        else:
            statuses.append(analyze_codex_window(stats, hours=5, label="Codex 5h"))
            statuses.append(analyze_codex_window(stats, hours=24 * 7, label="Codex 7d"))

    rl_block = format_rate_limit(statuses)
    if rl_block:
        lines.append(rl_block)

    return "\n".join(lines)


_PERIOD_LABELS = {
    "morning": "Morning   (06-12)",
    "afternoon": "Afternoon (12-18)",
    "evening": "Evening   (18-24)",
    "night": "Night     (00-06)",
}

_PERIOD_ORDER = ["morning", "afternoon", "evening", "night"]

_MODE_ICONS = {
    "Exploration": "🔍",
    "Building": "🏗️",
    "Execution": "⚡",
}


def format_coding_rhythm(stats: SessionStats) -> str:
    """格式化编码节奏与工作模式区块（⑧）"""
    has_rhythm = bool(stats.coding_rhythm)
    has_modes = bool(stats.work_mode_distribution)
    if not has_rhythm and not has_modes:
        return ""

    lines: list[str] = []
    sep = _dim("─" * 60)

    lines.append(f"  {_cyan_bold('⑧')} {_bold('编码节奏与工作模式')}")
    lines.append(sep)

    # Coding Rhythm — 水平柱状图（按 token 数量）
    if has_rhythm:
        lines.append(f"  {_dim('编码节奏 (按时段):')}")

        max_tokens = max(
            (int(d.get("token_count", 0)) for d in stats.coding_rhythm.values()),
            default=0,
        )
        peak_period = max(
            stats.coding_rhythm,
            key=lambda p: int(stats.coding_rhythm[p].get("token_count", 0)),
        )

        for period in _PERIOD_ORDER:
            data = stats.coding_rhythm.get(period)
            if data is None:
                label = _PERIOD_LABELS[period]
                lines.append(f"    {_dim(label)}  {_dim('░' * 20)}  {_dim('—')}")
                continue

            tokens = int(data.get("token_count", 0))
            sessions = int(data.get("session_count", 0))
            minutes = float(data.get("active_minutes", 0))
            label = _PERIOD_LABELS[period]
            bar = _bar(tokens, max_tokens, 20)
            token_str = _fmt_tokens(tokens)
            detail = f"{sessions}s {minutes:.0f}min"

            if period == peak_period:
                lines.append(
                    f"    {_yellow(label)}  {bar}  {_yellow(token_str)}  "
                    f"{_dim(detail)}  {_yellow('★')}"
                )
            else:
                lines.append(
                    f"    {label}  {bar}  {token_str}  {_dim(detail)}"
                )
        lines.append("")

    # Work Mode Distribution
    if has_modes:
        lines.append(f"  {_dim('工作模式分布:')}")
        total_sessions = sum(stats.work_mode_distribution.values())
        for mode in ("Exploration", "Building", "Execution"):
            count = stats.work_mode_distribution.get(mode, 0)
            pct = count / max(total_sessions, 1) * 100
            icon = _MODE_ICONS.get(mode, "")
            bar = _bar(count, total_sessions, 15)
            if pct >= 50:
                pct_str = _yellow(f"{pct:.0f}%")
            else:
                pct_str = f"{pct:.0f}%"
            lines.append(
                f"    {icon} {mode:<13} {bar}  {pct_str}  {_dim(f'({count}s)')}"
            )
        lines.append("")

    return "\n".join(lines)


def _format_reset_countdown(minutes: float) -> str:
    """把"距离重置还有多少分钟"格式化为 'Xd Yh Zm'"""
    minutes = max(int(round(minutes)), 0)
    if minutes <= 0:
        return "now"
    d, rem = divmod(minutes, 60 * 24)
    h, m = divmod(rem, 60)
    parts = []
    if d:
        parts.append(f"{d}d")
    if h:
        parts.append(f"{h}h")
    if m or not parts:
        parts.append(f"{m}m")
    return " ".join(parts)


def _format_rate_limit_block(status: RateLimitStatus) -> list[str]:
    """单个滚动窗口的状态块 — 不带 section header。"""
    lines: list[str] = []

    if status.status == "safe":
        status_label = f"✅ {_green('SAFE')}"
    elif status.status == "warning":
        status_label = f"⚠️  {_yellow('WARNING')}"
    elif status.status == "critical":
        status_label = f"🔴 {_red('CRITICAL')}"
    else:
        status_label = _dim("idle")

    badge = ""
    if getattr(status, "source_kind", "estimated") == "api_snapshot":
        badge = "  " + _dim("(OpenAI 后端原值)")
    lines.append(f"  [{_bold(status.label)}]   {status_label}{badge}")

    # —— Snapshot 模式：直接展示订阅百分比 + 重置时间 ——
    if getattr(status, "metric", "") == "used_percent":
        pct_display = status.pct * 100
        pct_str = f"{pct_display:.1f}%"
        if status.pct >= 0.85:
            pct_colored = _red(pct_str)
        elif status.pct >= 0.60:
            pct_colored = _yellow(pct_str)
        else:
            pct_colored = _green(pct_str)
        if status.window_minutes >= 60 * 24:
            window_unit = f"{status.window_minutes // (60 * 24)}d window"
        elif status.window_minutes >= 60:
            window_unit = f"{status.window_minutes // 60}h window"
        else:
            window_unit = f"{status.window_minutes}-min window"
        lines.append(f"  Used:        {pct_colored}  ({window_unit})")

        if status.minutes_until_limit is not None:
            countdown = _format_reset_countdown(status.minutes_until_limit)
            lines.append(f"  Resets in:   {_dim(countdown)}")

        snap_age = getattr(status, "snapshot_age_minutes", None)
        if isinstance(snap_age, (int, float)) and snap_age >= 60:
            age_str = _format_reset_countdown(snap_age)
            lines.append(f"  Snapshot:    {_dim(f'{age_str} ago')}")
        return lines

    # —— 估算模式：保留原 rate / window / messages / cost / ETA 渲染 ——
    if status.window_minutes >= 60 * 24:
        rate_unit = f"tokens/min ({status.window_minutes // (60 * 24)}d window)"
    elif status.window_minutes >= 60:
        rate_unit = f"tokens/min ({status.window_minutes // 60}h window)"
    else:
        rate_unit = f"tokens/min ({status.window_minutes}-min window)"
    rate_str = f"{status.rate_per_min:,.0f} {rate_unit}"
    lines.append(f"  Rate:        {_yellow(rate_str)}")

    if status.window_limit > 0:
        pct_str = f"{status.pct * 100:.0f}%"
        if status.pct >= 0.85:
            pct_colored = _red(pct_str)
        elif status.pct >= 0.60:
            pct_colored = _yellow(pct_str)
        else:
            pct_colored = _green(pct_str)
        lines.append(
            f"  Window:      {status.window_used:,} / "
            f"{status.window_limit:,} ({pct_colored})"
        )
    else:
        lines.append(f"  Window:      {status.window_used:,} {_dim('(无限额参考)')}")

    if status.messages > 0:
        lines.append(f"  Messages:    {status.messages:,}")

    if status.cost_usd > 0:
        lines.append(f"  Cost:        ${status.cost_usd:,.2f}")

    if status.window_limit > 0:
        if status.status == "critical":
            if status.minutes_until_limit is not None and status.minutes_until_limit <= 0:
                eta_str = _red("~0 min until quota limit — Consider pausing")
            elif status.minutes_until_limit is not None:
                eta_str = _red(f"~{status.minutes_until_limit:.0f} min until quota limit — Consider pausing")
            else:
                eta_str = _red("Consider pausing")
            lines.append(f"  ETA:         {eta_str}")
        else:
            if status.minutes_until_limit is not None:
                if status.minutes_until_limit <= 0:
                    lines.append(f"  Remaining:   {_red('limit reached')}")
                else:
                    rem_str = f"~{status.minutes_until_limit:.0f} min of headroom"
                    if status.status == "warning":
                        rem_str = _yellow(rem_str)
                    lines.append(f"  Remaining:   {rem_str}")
            else:
                lines.append(f"  Remaining:   {_dim('N/A')}")

    return lines


def format_rate_limit(statuses) -> str:
    """格式化 Usage Quota 预测结果（Claude 5-min / Codex 5h / Codex 7d 共用）。

    接受单个 RateLimitStatus 或 list；全部 idle 时返回空字符串。
    """
    if isinstance(statuses, RateLimitStatus):
        statuses = [statuses]
    elif statuses is None:
        return ""

    active = [s for s in statuses if s and s.status != "idle"]
    if not active:
        return ""

    lines: list[str] = []
    sep = _dim("─" * 60)
    lines.append(f"  {_cyan_bold('⑨')} {_bold('Usage Quota Forecast')}")
    lines.append(sep)
    for i, s in enumerate(active):
        if i > 0:
            lines.append("")
        lines.extend(_format_rate_limit_block(s))
    lines.append("")
    return "\n".join(lines)


def format_skill_stats(stats: SessionStats, session_count: int = 1) -> str:
    """将 Skill 使用统计格式化为终端输出"""
    lines: list[str] = []
    sep = _dim("─" * 60)

    # Header
    lines.append("")
    lines.append(_cyan("  ╔══════════════════════════════════════════════════════════╗"))
    lines.append(_cyan("  ║") + _white_bold("          Skill 使用统计报告") + "                     " + _cyan("║"))
    lines.append(_cyan("  ╚══════════════════════════════════════════════════════════╝"))
    lines.append("")

    if stats.project_path and stats.project_path != "all":
        lines.append(f"  {_dim('项目:')} {_bold(stats.project_path)}")
    if session_count > 1:
        lines.append(f"  {_dim('会话数:')} {_bold(str(session_count))}")
    if stats.start_time:
        start_local = stats.start_time.astimezone()
        end_local = stats.end_time.astimezone() if stats.end_time else None
        end_str = end_local.strftime('%Y-%m-%d %H:%M') if end_local else '?'
        lines.append(f"  {_dim('时间范围:')} {start_local.strftime('%Y-%m-%d %H:%M')} ~ {end_str}")
    lines.append("")

    if not stats.skill_stats:
        lines.append(f"  {_dim('未发现 Skill 调用记录')}")
        lines.append("")
        return "\n".join(lines)

    # ── ① 调用次数排行 ──
    sorted_skills = sorted(
        stats.skill_stats.values(), key=lambda s: s.call_count, reverse=True
    )
    total_calls = sum(s.call_count for s in sorted_skills)

    lines.append(f"  {_cyan_bold('①')} {_bold('Skill 调用排行')}")
    lines.append(sep)
    lines.append(f"  Skill 总数: {_yellow(str(len(sorted_skills)))}  总调用: {_yellow(str(total_calls))}")
    lines.append("")

    max_count = sorted_skills[0].call_count if sorted_skills else 1
    max_name_len = max(len(s.name) for s in sorted_skills)

    for su in sorted_skills:
        bar = _bar(su.call_count, max_count, 15)
        lines.append(
            f"  {_bold(f'{su.name:<{max_name_len}}')}  {bar} {_yellow(f'{su.call_count:>5}')}"
        )
    lines.append("")

    # ── ② 成功率 ──
    lines.append(f"  {_cyan_bold('②')} {_bold('成功/失败率')}")
    lines.append(sep)

    for su in sorted_skills:
        resolved = su.success_count + su.error_count
        if resolved > 0:
            success_rate = su.success_count / resolved * 100
            rate_color = _green if success_rate >= 90 else _yellow if success_rate >= 70 else _red
            rate_str = rate_color(f"{success_rate:.0f}%")
        else:
            rate_str = _dim("N/A")

        parts = []
        if su.success_count:
            parts.append(_green(f"✓{su.success_count}"))
        if su.error_count:
            parts.append(_red(f"✗{su.error_count}"))
        if su.unknown_count:
            parts.append(_dim(f"?{su.unknown_count}"))
        detail = " ".join(parts)

        lines.append(
            f"  {su.name:<{max_name_len}}  成功率: {rate_str}  ({detail})"
        )
    lines.append("")

    # ── ③ 时间分布（按小时） ──
    lines.append(f"  {_cyan_bold('③')} {_bold('时间分布（按小时）')}")
    lines.append(sep)

    # 合并所有 skill 的小时分布
    hourly_total: dict[int, int] = {}
    for su in sorted_skills:
        for h, c in su.hourly_dist.items():
            hourly_total[h] = hourly_total.get(h, 0) + c

    if hourly_total:
        max_hourly = max(hourly_total.values())
        for hour in range(24):
            count = hourly_total.get(hour, 0)
            if count == 0:
                continue
            bar = _bar(count, max_hourly, 20)
            lines.append(f"  {hour:02d}:00  {bar} {_yellow(f'{count:>3}')}")
    else:
        lines.append(f"  {_dim('无时间分布数据')}")
    lines.append("")

    # ── ④ 时间分布（按天） ──
    daily_total: dict[str, int] = {}
    for su in sorted_skills:
        for d, c in su.daily_dist.items():
            daily_total[d] = daily_total.get(d, 0) + c

    if daily_total:
        lines.append(f"  {_cyan_bold('④')} {_bold('时间分布（按天）')}")
        lines.append(sep)

        sorted_days = sorted(daily_total.items())
        max_daily = max(daily_total.values())
        for day, count in sorted_days:
            bar = _bar(count, max_daily, 20)
            lines.append(f"  {day}  {bar} {_yellow(f'{count:>3}')}")
        lines.append("")

    return "\n".join(lines)


def format_git_integration(result) -> str:
    """格式化 Git 集成分析结果（Top Commits by AI Cost）

    Args:
        result: GitIntegrationResult 实例

    Returns:
        格式化的终端输出字符串
    """
    from .git_integration import GitIntegrationResult

    lines: list[str] = []
    sep = _dim("─" * 60)

    lines.append("")
    lines.append(_cyan("  ╔══════════════════════════════════════════════════════════╗"))
    lines.append(_cyan("  ║") + _white_bold("        Git Integration — AI Cost per Commit") + "     " + _cyan("║"))
    lines.append(_cyan("  ╚══════════════════════════════════════════════════════════╝"))
    lines.append("")

    lines.append(f"  {_dim('仓库:')} {_bold(result.repo_path)}")
    lines.append(f"  {_dim('Commits:')} {_bold(str(result.total_commits))}")
    lines.append(f"  {_dim('Sessions matched:')} {_bold(str(result.sessions_matched))}")
    lines.append(
        f"  {_dim('Total AI cost:')} {_green(f'~${result.total_cost_usd:.3f}')}"
        f"  {_dim('(')} {_fmt_tokens(result.total_tokens)} tokens {_dim(')')}"
    )
    lines.append("")

    if not result.commit_costs:
        lines.append(f"  {_dim('No commits found in the specified range.')}")
        lines.append("")
        return "\n".join(lines)

    # Top 10 commits by cost
    sorted_costs = sorted(result.commit_costs, key=lambda c: c.estimated_cost_usd, reverse=True)
    top = sorted_costs[:10]

    lines.append(f"  {_cyan_bold('Top Commits by AI Cost')}")
    lines.append(sep)

    max_cost = max((c.estimated_cost_usd for c in top), default=0)

    for cc in top:
        if cc.total_tokens == 0:
            continue

        commit = cc.commit
        # Short hash
        short_hash = commit.hash[:7]
        # Truncate message
        msg = commit.message[:40] + ("…" if len(commit.message) > 40 else "")
        # Date
        local_ts = commit.timestamp.astimezone()
        date_str = local_ts.strftime("%m-%d %H:%M")
        # Cost
        cost_str = f"${cc.estimated_cost_usd:.3f}"
        # Bar
        bar = _bar(int(cc.estimated_cost_usd * 10000), int(max_cost * 10000), 12)

        lines.append(
            f"  {_dim(date_str)}  {_cyan(short_hash)}  {bar}  "
            f"{_yellow(cost_str):>10}  {_fmt_tokens(cc.total_tokens):>7}  "
            f"{_dim(f'{cc.session_count}s')}  {msg}"
        )

    lines.append("")

    # All commits summary table (if more than top 10)
    if len(result.commit_costs) > 10:
        lines.append(f"  {_dim(f'(showing top 10 of {len(result.commit_costs)} commits with AI activity)')}")
        lines.append("")

    return "\n".join(lines)
