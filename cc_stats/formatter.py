"""格式化统计结果输出（带 ANSI 色彩）"""

from __future__ import annotations

import os
from datetime import timedelta

from .analyzer import TOOL_DESCRIPTIONS, SessionStats


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


# ── 主格式化 ───────────────────────────────────────────────

def format_stats(stats: SessionStats, session_count: int = 1) -> str:
    """将统计结果格式化为终端输出"""
    lines: list[str] = []
    sep = _dim("─" * 60)

    # ── Header ──
    lines.append("")
    lines.append(_cyan("  ╔══════════════════════════════════════════════════════════╗"))
    lines.append(_cyan("  ║") + _white_bold("        Claude Code 会话统计报告") + "                   " + _cyan("║"))
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

    return "\n".join(lines)
