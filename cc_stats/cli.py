"""CLI 入口"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .analyzer import analyze_session, merge_stats
from .formatter import format_stats
from .parser import find_sessions, find_sessions_by_keyword, parse_jsonl


def _parse_time_arg(value: str) -> datetime:
    """解析时间参数，支持多种格式：

    绝对时间:
      2026-03-13
      2026-03-13T10:00
      2026-03-13T10:00:00

    相对时间 (相对于当前时刻):
      1h    → 1 小时前
      3d    → 3 天前
      2w    → 2 周前
    """
    value = value.strip()

    # 相对时间
    if value and value[-1] in ("h", "d", "w") and value[:-1].isdigit():
        n = int(value[:-1])
        unit = value[-1]
        delta = {"h": timedelta(hours=n), "d": timedelta(days=n), "w": timedelta(weeks=n)}[unit]
        return datetime.now(tz=timezone.utc) - delta

    # 绝对时间（视为本地时间）
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.strptime(value, fmt)
            return dt.astimezone(timezone.utc)
        except ValueError:
            continue

    raise argparse.ArgumentTypeError(
        f"无法解析时间: {value}（支持 2026-03-13, 2026-03-13T10:00, 3d, 2w, 1h）"
    )


def _resolve_project_name(proj_dir: Path, jsonl_files: list[Path]) -> str:
    """从 JSONL 文件中的 cwd 字段还原项目真实路径"""
    import json
    for jf in jsonl_files:
        with open(jf, encoding="utf-8") as fh:
            for ln in fh:
                try:
                    obj = json.loads(ln)
                    if obj.get("cwd"):
                        return obj["cwd"]
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
    # fallback: 目录名本身
    return proj_dir.name


def _compare_projects(args) -> None:
    """对比所有项目的关键指标"""
    from .formatter import _fmt_duration, _fmt_tokens

    claude_projects = Path.home() / ".claude" / "projects"
    if not claude_projects.exists():
        print("未找到 Claude Code 项目数据")
        return

    projects: list[dict] = []

    for proj in sorted(claude_projects.iterdir()):
        if not proj.is_dir():
            continue
        jsonl_files = list(proj.glob("*.jsonl"))
        if not jsonl_files:
            continue

        name = _resolve_project_name(proj, jsonl_files)
        # 简化路径显示
        short_name = Path(name).name if "/" in name else name

        all_stats = []
        for f in jsonl_files:
            try:
                session = parse_jsonl(f)
                stats = analyze_session(session)

                # 时间过滤
                if args.since and stats.end_time and stats.end_time < args.since:
                    continue
                if args.until and stats.start_time and stats.start_time > args.until:
                    continue

                all_stats.append(stats)
            except Exception:
                continue

        if not all_stats:
            continue

        merged = merge_stats(all_stats) if len(all_stats) > 1 else all_stats[0]

        from .reporter import _estimate_cost
        cost = _estimate_cost(merged)

        projects.append({
            "name": short_name,
            "sessions": len(all_stats),
            "instructions": merged.user_message_count,
            "duration": merged.active_duration,
            "tokens": merged.token_usage.total,
            "cost": cost,
            "added": merged.total_added + merged.git_total_added,
            "removed": merged.total_removed + merged.git_total_removed,
            "grade": merged.efficiencyGrade if hasattr(merged, 'efficiencyGrade') else "",
        })

    if not projects:
        print("没有项目数据")
        return

    # 按 token 总量降序排列
    projects.sort(key=lambda p: p["tokens"], reverse=True)

    # 计算列宽
    max_name = max(len(p["name"]) for p in projects)
    max_name = max(max_name, 4)  # 最小宽度

    # 表头
    print()
    print(f"  {'项目':<{max_name}}  {'会话':>4}  {'指令':>5}  {'活跃时长':>10}  {'Token':>8}  {'费用':>8}  {'代码':>10}")
    print("─" * (max_name + 60))

    total_sessions = 0
    total_instructions = 0
    total_tokens = 0
    total_cost = 0.0

    for p in projects:
        dur_str = _fmt_duration(p["duration"])
        tok_str = _fmt_tokens(p["tokens"])
        cost_str = f"${p['cost']:.0f}" if p["cost"] >= 1 else f"${p['cost']:.2f}"
        code_str = f"+{p['added']}/-{p['removed']}"

        print(f"  {p['name']:<{max_name}}  {p['sessions']:>4}  {p['instructions']:>5}  {dur_str:>10}  {tok_str:>8}  {cost_str:>8}  {code_str:>10}")

        total_sessions += p["sessions"]
        total_instructions += p["instructions"]
        total_tokens += p["tokens"]
        total_cost += p["cost"]

    print("─" * (max_name + 60))
    print(f"  {'合计':<{max_name}}  {total_sessions:>4}  {total_instructions:>5}  {'':>10}  {_fmt_tokens(total_tokens):>8}  ${total_cost:>7.0f}")
    print()


def _list_projects() -> None:
    """列出所有已知项目"""
    claude_projects = Path.home() / ".claude" / "projects"
    if not claude_projects.exists():
        print("未找到 Claude Code 项目数据")
        return

    print("\n可用项目:")
    print("─" * 60)
    for proj in sorted(claude_projects.iterdir()):
        if not proj.is_dir():
            continue
        jsonl_files = list(proj.glob("*.jsonl"))
        if not jsonl_files:
            continue
        display_name = _resolve_project_name(proj, jsonl_files)
        print(f"  {display_name}  ({len(jsonl_files)} 个会话)")
    print()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="cc-stats",
        description="Claude Code 会话统计工具 — 分析 AI Coding 工程指标",
    )
    parser.add_argument(
        "path",
        nargs="?",
        help="JSONL 文件路径，或项目目录路径。不指定则分析当前目录的所有会话。",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="分析所有项目的所有会话",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        dest="list_projects",
        help="列出所有已知项目",
    )
    parser.add_argument(
        "--last",
        type=int,
        metavar="N",
        help="只分析最近 N 个会话",
    )
    parser.add_argument(
        "--since",
        type=_parse_time_arg,
        metavar="TIME",
        help="只包含此时间之后的会话（如 2026-03-13, 3d, 2w, 1h）",
    )
    parser.add_argument(
        "--until",
        type=_parse_time_arg,
        metavar="TIME",
        help="只包含此时间之前的会话（如 2026-03-14, 1d）",
    )

    parser.add_argument(
        "--report",
        choices=["week", "month"],
        metavar="PERIOD",
        help="生成周报(week)或月报(month)，输出 Markdown 格式",
    )
    parser.add_argument(
        "--compare",
        action="store_true",
        help="对比所有项目的关键指标",
    )
    parser.add_argument(
        "--notify",
        metavar="WEBHOOK_URL",
        help="发送今日统计到 Webhook（自动检测飞书/钉钉/Slack）",
    )
    parser.add_argument(
        "--platform",
        choices=["feishu", "dingtalk", "slack"],
        help="指定 Webhook 平台（配合 --notify 使用）",
    )

    args = parser.parse_args(argv)

    if args.report:
        from .reporter import generate_report
        print(generate_report(args.report))
        return

    if args.notify:
        from .webhook import send_notification
        send_notification(args.notify, args.platform or "auto")
        return

    if args.compare:
        _compare_projects(args)
        return

    if args.list_projects:
        _list_projects()
        return

    # 确定要分析的 JSONL 文件
    jsonl_files: list[Path] = []

    if args.path:
        p = Path(args.path)
        if p.is_file() and p.suffix == ".jsonl":
            jsonl_files = [p]
        elif p.is_dir():
            jsonl_files = find_sessions(p)
        if not jsonl_files:
            # 作为关键词模糊搜索（同时搜索目录名和 JSONL 中的 cwd）
            jsonl_files = find_sessions_by_keyword(args.path)
        if not jsonl_files:
            print(f"找不到: {args.path}", file=sys.stderr)
            sys.exit(1)
    elif args.all:
        jsonl_files = find_sessions()
    else:
        # 默认：当前目录
        jsonl_files = find_sessions(Path.cwd())

    if not jsonl_files:
        print("未找到 JSONL 会话文件。使用 --list 查看可用项目。", file=sys.stderr)
        sys.exit(1)

    # 按修改时间排序
    jsonl_files.sort(key=lambda f: f.stat().st_mtime)

    if args.last:
        jsonl_files = jsonl_files[-args.last:]

    # 解析 & 分析（按时间范围过滤）
    all_stats = []
    for f in jsonl_files:
        session = parse_jsonl(f)
        stats = analyze_session(session)

        # --since: 跳过结束时间在 since 之前的会话
        if args.since and stats.end_time and stats.end_time < args.since:
            continue
        # --until: 跳过开始时间在 until 之后的会话
        if args.until and stats.start_time and stats.start_time > args.until:
            continue

        all_stats.append(stats)

    if not all_stats:
        print("指定时间范围内无会话。", file=sys.stderr)
        sys.exit(1)

    if len(all_stats) == 1:
        result = all_stats[0]
    else:
        result = merge_stats(all_stats)

    print(format_stats(result, session_count=len(all_stats)))


if __name__ == "__main__":
    main()
