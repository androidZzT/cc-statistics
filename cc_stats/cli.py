"""CLI 入口"""

from __future__ import annotations

import argparse
import sys
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .analyzer import SessionStats, TokenUsage, analyze_session, merge_stats
from .formatter import format_skill_stats, format_stats
from .parser import (
    find_codex_sessions,
    find_codex_sessions_by_keyword,
    find_gemini_sessions,
    find_gemini_sessions_by_keyword,
    find_sessions,
    find_sessions_by_keyword,
    parse_session_file,
)


def _parse_session(path: Path):
    """根据文件类型选择解析器"""
    return parse_session_file(path)


def _parse_time_arg(value: str, *, as_end_of_day: bool = False) -> datetime:
    """解析时间参数，支持多种格式：

    绝对时间:
      2026-03-13
      2026-03-13T10:00
      2026-03-13T10:00:00

    相对时间 (相对于当前时刻):
      1h    → 1 小时前
      3d    → 3 天前
      2w    → 2 周前

    as_end_of_day: 当为 True 且输入为纯日期格式时，补全为当天 23:59:59
                   用于 --until 参数，使 --until 2026-04-03 包含 04-03 全天
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
            # 纯日期格式作为 until 参数时，补全为当天结束 23:59:59
            if fmt == "%Y-%m-%d" and as_end_of_day:
                dt = dt.replace(hour=23, minute=59, second=59)
            return dt.astimezone(timezone.utc)
        except ValueError:
            continue

    raise argparse.ArgumentTypeError(
        f"无法解析时间: {value}（支持 2026-03-13, 2026-03-13T10:00, 3d, 2w, 1h）"
    )


def _trim_stats_by_date_range(
    stats: SessionStats,
    since_date: str | None,
    until_date: str | None,
) -> None:
    """按本地日期范围裁剪 token_by_date，并重算 token_usage

    当 --since/--until 指定时，跨越日期范围的 session 只计入范围内日期的 token。
    since_date / until_date 格式为 "YYYY-MM-DD" 本地日期字符串。
    """
    if not stats.token_by_date:
        return
    if not since_date and not until_date:
        return

    trimmed: dict[str, TokenUsage] = {}
    for date_key, tu in stats.token_by_date.items():
        if since_date and date_key < since_date:
            continue
        if until_date and date_key > until_date:
            continue
        trimmed[date_key] = tu

    stats.token_by_date = trimmed

    # 从裁剪后的 token_by_date 重算 token_usage 总量
    new_usage = TokenUsage()
    for tu in trimmed.values():
        new_usage.input_tokens += tu.input_tokens
        new_usage.output_tokens += tu.output_tokens
        new_usage.cache_read_input_tokens += tu.cache_read_input_tokens
        new_usage.cache_creation_input_tokens += tu.cache_creation_input_tokens
    stats.token_usage = new_usage


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


def _display_width(s: str) -> int:
    """计算字符串的终端显示宽度（CJK 字符占 2 列）"""
    width = 0
    for c in s:
        if unicodedata.east_asian_width(c) in ('W', 'F'):
            width += 2
        else:
            width += 1
    return width


def _pad_right(s: str, width: int) -> str:
    """右填充空格至指定显示宽度"""
    return s + ' ' * (width - _display_width(s))


def _pad_left(s: str, width: int) -> str:
    """左填充空格至指定显示宽度（右对齐）"""
    return ' ' * (width - _display_width(s)) + s


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

        # 按日期裁剪 token
        if args.since or args.until:
            sd = args.since.astimezone().strftime("%Y-%m-%d") if args.since else None
            ud = args.until.astimezone().strftime("%Y-%m-%d") if args.until else None
            for s in all_stats:
                _trim_stats_by_date_range(s, sd, ud)

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
    max_name = max(_display_width(p["name"]) for p in projects)
    max_name = max(max_name, 4)  # 最小宽度

    # 表头
    print()
    COL_SESSIONS = 4
    COL_INSTRUCTIONS = 5
    COL_DURATION = 10
    COL_TOKENS = 8
    COL_COST = 8
    COL_CODE = 10
    print(f"  {_pad_right('项目', max_name)}  {_pad_left('会话', COL_SESSIONS)}  {_pad_left('指令', COL_INSTRUCTIONS)}  {_pad_left('活跃时长', COL_DURATION)}  {_pad_left('Token', COL_TOKENS)}  {_pad_left('费用', COL_COST)}  {_pad_left('代码', COL_CODE)}")
    sep_width = max_name + 2 + COL_SESSIONS + 2 + COL_INSTRUCTIONS + 2 + COL_DURATION + 2 + COL_TOKENS + 2 + COL_COST + 2 + COL_CODE + 2
    print("─" * sep_width)

    total_sessions = 0
    total_instructions = 0
    total_tokens = 0
    total_cost = 0.0

    for p in projects:
        dur_str = _fmt_duration(p["duration"])
        tok_str = _fmt_tokens(p["tokens"])
        cost_str = f"${p['cost']:.0f}" if p["cost"] >= 1 else f"${p['cost']:.2f}"
        code_str = f"+{p['added']}/-{p['removed']}"

        print(f"  {_pad_right(p['name'], max_name)}  {p['sessions']:>4}  {p['instructions']:>5}  {dur_str:>10}  {tok_str:>8}  {cost_str:>8}  {code_str:>10}")

        total_sessions += p["sessions"]
        total_instructions += p["instructions"]
        total_tokens += p["tokens"]
        total_cost += p["cost"]

    print("─" * sep_width)
    print(f"  {_pad_right('合计', max_name)}  {total_sessions:>4}  {total_instructions:>5}  {'':>10}  {_fmt_tokens(total_tokens):>8}  ${total_cost:>7.0f}")
    print()


def _list_projects() -> None:
    """列出所有已知项目（Claude + Codex + Gemini）"""
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

    # Codex 项目
    codex_sessions = find_codex_sessions()
    if codex_sessions:
        from collections import defaultdict
        codex_by_dir: dict[str, list[Path]] = defaultdict(list)
        for cf in codex_sessions:
            try:
                session = _parse_session(cf)
                key = session.project_path or "Unknown"
            except Exception:
                key = "Unknown"
            codex_by_dir[key].append(cf)

        print("\n可用项目 (Codex):")
        print("─" * 60)
        for name, files in sorted(codex_by_dir.items()):
            display = Path(name).name if "/" in name else name
            print(f"  {display}  ({len(files)} 个会话)")
            has_any = True

    # Gemini 项目
    gemini_sessions = find_gemini_sessions()
    if gemini_sessions:
        # 按项目目录分组
        from collections import defaultdict
        gemini_by_dir: dict[str, list[Path]] = defaultdict(list)
        for gf in gemini_sessions:
            try:
                session = _parse_session(gf)
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


def _show_rate_limit(args) -> None:
    """显示 Usage Quota 预测（分析最近 1 小时内的所有会话）"""
    from .formatter import format_rate_limit
    from .rate_limiter import analyze_rate_limit

    # 收集所有会话文件（Claude + Codex + Gemini）
    session_files: list[Path] = find_sessions()
    session_files.extend(find_codex_sessions())
    session_files.extend(find_gemini_sessions())

    if not session_files:
        print("未找到会话文件。", file=sys.stderr)
        sys.exit(1)

    # 只保留最近 1 小时内修改过的文件
    one_hour_ago = datetime.now().timestamp() - 3600
    session_files = [f for f in session_files if f.stat().st_mtime >= one_hour_ago]

    if not session_files:
        print("最近 1 小时内无活跃会话。")
        return

    all_stats = []
    for f in session_files:
        try:
            session = _parse_session(f)
            stats = analyze_session(session)
            all_stats.append(stats)
        except Exception:
            continue

    if not all_stats:
        print("无法分析会话数据。", file=sys.stderr)
        sys.exit(1)

    result = merge_stats(all_stats) if len(all_stats) > 1 else all_stats[0]
    rl_status = analyze_rate_limit(result, window_limit=args.window_limit)
    output = format_rate_limit(rl_status)
    if output:
        print(output)
    else:
        print("当前无活跃 token 消耗数据（idle）。")




def _show_git_integration(args) -> None:
    """显示 Git 集成分析：将会话按时间归属到 commit，计算每 commit 的 AI 成本"""
    from .formatter import format_git_integration
    from .git_integration import analyze_git_integration

    repo_path = Path(args.git).resolve()
    if not repo_path.exists():
        import sys
        print(f"仓库路径不存在: {repo_path}", file=sys.stderr)
        sys.exit(1)

    # 收集所有会话文件
    session_files: list[Path] = find_sessions()
    session_files.extend(find_codex_sessions())
    session_files.extend(find_gemini_sessions())

    if not session_files:
        import sys
        print("未找到会话文件。", file=sys.stderr)
        sys.exit(1)

    # 解析 & 分析
    all_stats = []
    for f in session_files:
        try:
            session = _parse_session(f)
            stats = analyze_session(session)
            if args.since and stats.end_time and stats.end_time < args.since:
                continue
            if args.until and stats.start_time and stats.start_time > args.until:
                continue
            all_stats.append(stats)
        except Exception:
            continue

    if not all_stats:
        import sys
        print("指定时间范围内无会话。", file=sys.stderr)
        sys.exit(1)

    result = analyze_git_integration(
        repo_path=str(repo_path),
        all_stats=all_stats,
        since=args.since if args.since else None,
        until=args.until if args.until else None,
    )
    print(format_git_integration(result))

def main(argv: list[str] | None = None) -> None:
    # 启动时检查更新提示（仅读缓存，无网络请求）
    update_hint = _check_update_hint()
    if update_hint:
        print(f"\033[33m💡 {update_hint}\033[0m\n")

    # 后台触发版本检查（更新缓存，供下次启动时使用）
    _trigger_background_check()

    parser = argparse.ArgumentParser(
        prog="cc-stats",
        description="AI Coding 会话统计工具 — 支持 Claude Code / Codex / Gemini CLI",
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
        "--skills",
        action="store_true",
        help="展示 Skill 使用统计（调用次数、成功率、时间分布）",
    )
    parser.add_argument(
        "--last",
        type=int,
        metavar="N",
        help="只分析最近 N 个会话",
    )
    parser.add_argument(
        "--since",
        type=str,
        metavar="TIME",
        help="只包含此时间之后的会话（如 2026-03-13, 3d, 2w, 1h）",
    )
    parser.add_argument(
        "--until",
        type=str,
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
    parser.add_argument(
        "--install-hooks",
        action="store_true",
        help="安装 Claude Code hooks（会话完成/权限请求通知）",
    )
    parser.add_argument(
        "--uninstall-hooks",
        action="store_true",
        help="卸载已安装的 Claude Code hooks",
    )
    parser.add_argument(
        "--notify-test",
        action="store_true",
        help="发送测试通知以验证通知功能",
    )
    parser.add_argument(
        "--rate-limit",
        action="store_true",
        help="显示用量额度预测（分析最近会话的 output token 速率）",
    )
    parser.add_argument(
        "--window-limit",
        type=int,
        default=40000,
        metavar="TOKENS",
        help="Usage Quota 窗口上限（默认 40000，Max 订阅可设为 80000）",
    )
    parser.add_argument(
        "--git",
        nargs="?",
        const=".",
        metavar="REPO_PATH",
        help="显示 Git 集成分析：将会话按时间归属到 commit，计算每 commit 的 Token/成本（默认当前目录）",
    )

    args = parser.parse_args(argv)

    # 手动解析时间参数：since 纯日期补全为 00:00:00，until 纯日期补全为 23:59:59
    if args.since:
        args.since = _parse_time_arg(args.since)
    if args.until:
        args.until = _parse_time_arg(args.until, as_end_of_day=True)

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

    if args.install_hooks:
        from .hooks import install_hooks, get_hook_command
        if install_hooks("user"):
            print("✅ Claude Code hooks 已安装到 ~/.claude/settings.json")
            print(f"   Hook 命令: {get_hook_command()}")
            print("   支持事件: Stop (会话完成), PreToolUse (工具进度), PermissionRequest (灵动岛确权)")
            print("\n   配置通知偏好: 编辑 ~/.cc-stats/notify_config.json")
        else:
            print("❌ 安装失败", file=sys.stderr)
            sys.exit(1)
        return

    if args.uninstall_hooks:
        from .hooks import uninstall_hooks
        if uninstall_hooks("user"):
            print("✅ Claude Code hooks 已卸载")
        else:
            print("❌ 卸载失败", file=sys.stderr)
            sys.exit(1)
        return

    if args.notify_test:
        from .notifier import send_notification
        ok = send_notification(
            "CC Stats 通知测试",
            "如果你看到这条通知，说明通知功能正常工作 ✓",
            force=True,
        )
        if ok:
            print("✅ 测试通知已发送")
        else:
            print("❌ 通知发送失败", file=sys.stderr)
            sys.exit(1)
        return

    if args.rate_limit:
        _show_rate_limit(args)
        return

    if args.git is not None:
        _show_git_integration(args)
        return

    if args.compare:
        _compare_projects(args)
        return

    if args.list_projects:
        _list_projects()
        return

    # 确定要分析的会话文件（Claude JSONL + Codex JSONL + Gemini JSON）
    session_files: list[Path] = []

    if args.path:
        p = Path(args.path)
        if p.is_file() and p.suffix in (".jsonl", ".json"):
            session_files = [p]
        elif p.is_dir():
            session_files = find_sessions(p)
            session_files.extend(find_codex_sessions(p))
        if not session_files:
            # 作为关键词模糊搜索（Claude + Codex + Gemini）
            session_files = find_sessions_by_keyword(args.path)
            session_files.extend(find_codex_sessions_by_keyword(args.path))
            session_files.extend(find_gemini_sessions_by_keyword(args.path))
        if not session_files:
            print(f"找不到: {args.path}", file=sys.stderr)
            sys.exit(1)
    elif args.all:
        session_files = find_sessions()
        session_files.extend(find_codex_sessions())
        session_files.extend(find_gemini_sessions())
    else:
        # 默认：当前目录
        session_files = find_sessions(Path.cwd())
        session_files.extend(find_codex_sessions(Path.cwd()))

    # 去重（保留原顺序）
    session_files = list(dict.fromkeys(session_files))

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

    # 按日期裁剪 token：跨越过滤范围的 session 只计入范围内日期的 token
    if args.since or args.until:
        since_date = args.since.astimezone().strftime("%Y-%m-%d") if args.since else None
        until_date = args.until.astimezone().strftime("%Y-%m-%d") if args.until else None
        for s in all_stats:
            _trim_stats_by_date_range(s, since_date, until_date)

    if len(all_stats) == 1:
        result = all_stats[0]
    else:
        result = merge_stats(all_stats)

    # 限定显示的时间范围为过滤范围，而非 session 的原始首尾时间
    if args.since and result.start_time and result.start_time < args.since:
        result.start_time = args.since
    if args.until and result.end_time and result.end_time > args.until:
        result.end_time = args.until

    if args.skills:
        print(format_skill_stats(result, session_count=len(all_stats)))
    else:
        print(format_stats(result, session_count=len(all_stats)))


if __name__ == "__main__":
    main()
