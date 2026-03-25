"""CLI 入口"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .analyzer import analyze_session, merge_stats
from .formatter import format_stats
from .parser import (
    find_gemini_sessions,
    find_gemini_sessions_by_keyword,
    find_sessions,
    find_sessions_by_keyword,
    parse_gemini_json,
    parse_jsonl,
)


def _parse_session(path: Path):
    """根据文件类型选择解析器"""
    if path.suffix == ".json":
        return parse_gemini_json(path)
    return parse_jsonl(path)


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
                session = _parse_session(f)
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
    """列出所有已知项目（Claude + Gemini）"""
    has_any = False

    # Claude 项目
    claude_projects = Path.home() / ".claude" / "projects"
    if claude_projects.exists():
        print("\n可用项目 (Claude Code):")
        print("─" * 60)
        for proj in sorted(claude_projects.iterdir()):
            if not proj.is_dir():
                continue
            jsonl_files = list(proj.glob("*.jsonl"))
            if not jsonl_files:
                continue
            display_name = _resolve_project_name(proj, jsonl_files)
            print(f"  {display_name}  ({len(jsonl_files)} 个会话)")
            has_any = True

    # Gemini 项目
    gemini_sessions = find_gemini_sessions()
    if gemini_sessions:
        # 按项目目录分组
        from collections import defaultdict
        gemini_by_dir: dict[str, list[Path]] = defaultdict(list)
        for gf in gemini_sessions:
            try:
                session = parse_gemini_json(gf)
                key = session.project_path or gf.parent.parent.name
            except Exception:
                key = gf.parent.parent.name
            gemini_by_dir[key].append(gf)

        print("\n可用项目 (Gemini CLI):")
        print("─" * 60)
        for name, files in sorted(gemini_by_dir.items()):
            display = Path(name).name if "/" in name else name
            print(f"  {display}  ({len(files)} 个会话)")
            has_any = True

    if not has_any:
        print("未找到项目数据")
    print()


def _check_update_hint() -> str | None:
    """启动时检查缓存中的更新信息（不发起网络请求，不阻塞）"""
    try:
        from .version_checker import get_cached_update, format_update_message
        result = get_cached_update()
        if result is not None:
            return format_update_message(result)
    except Exception:
        pass
    return None


def _trigger_background_check() -> None:
    """在后台线程触发版本检查（不阻塞 CLI 主流程）"""
    import threading

    def _run() -> None:
        try:
            from .version_checker import check_for_update
            check_for_update()
        except Exception:
            pass

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()


def main(argv: list[str] | None = None) -> None:
    # 启动时检查更新提示（仅读缓存，无网络请求）
    update_hint = _check_update_hint()
    if update_hint:
        print(f"\033[33m💡 {update_hint}\033[0m\n")

    # 后台触发版本检查（更新缓存，供下次启动时使用）
    _trigger_background_check()

    parser = argparse.ArgumentParser(
        prog="cc-stats",
        description="AI Coding 会话统计工具 — 支持 Claude Code / Gemini CLI",
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
    parser.add_argument(
        "--export-chat",
        metavar="KEYWORD",
        help="导出会话为 Markdown（按会话ID前缀或内容关键词搜索）",
    )
    parser.add_argument(
        "--include-tools",
        action="store_true",
        help="导出时包含工具调用（配合 --export-chat 使用）",
    )

    args = parser.parse_args(argv)

    if args.export_chat:
        from .exporter import find_and_export
        result = find_and_export(
            args.export_chat,
            include_tools=args.include_tools,
        )
        if result:
            # 保存到桌面
            desktop = Path.home() / "Desktop"
            out_file = desktop / f"chat-{args.export_chat[:12]}.md"
            out_file.write_text(result, encoding="utf-8")
            print(f"已导出到 {out_file}")
        else:
            print(f"未找到匹配的会话: {args.export_chat}", file=sys.stderr)
        return

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

    # 确定要分析的会话文件（Claude JSONL + Gemini JSON）
    session_files: list[Path] = []

    if args.path:
        p = Path(args.path)
        if p.is_file() and p.suffix in (".jsonl", ".json"):
            session_files = [p]
        elif p.is_dir():
            session_files = find_sessions(p)
        if not session_files:
            # 作为关键词模糊搜索（Claude + Gemini）
            session_files = find_sessions_by_keyword(args.path)
            session_files.extend(find_gemini_sessions_by_keyword(args.path))
        if not session_files:
            print(f"找不到: {args.path}", file=sys.stderr)
            sys.exit(1)
    elif args.all:
        session_files = find_sessions()
        session_files.extend(find_gemini_sessions())
    else:
        # 默认：当前目录
        session_files = find_sessions(Path.cwd())

    if not session_files:
        print("未找到会话文件。使用 --list 查看可用项目。", file=sys.stderr)
        sys.exit(1)

    # 按修改时间排序
    session_files.sort(key=lambda f: f.stat().st_mtime)

    if args.last:
        session_files = session_files[-args.last:]

    # 解析 & 分析（按时间范围过滤）
    all_stats = []
    for f in session_files:
        session = _parse_session(f)
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
