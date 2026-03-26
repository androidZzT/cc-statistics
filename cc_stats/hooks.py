"""Claude Code Hook 事件处理器

通过 Claude Code 的 hook 系统触发通知。Hook 事件通过 stdin 传入 JSON。

支持的 hook 事件:
- Stop: 会话结束时发送完成通知
- PreToolUse: 需要权限确认时发送通知（仅 AskUserQuestion / Bash 等需确认的工具）
- Notification: Claude Code 空闲等待用户输入时通知

用法:
  在 ~/.claude/settings.json 中配置 hooks，
  或通过 cc-stats --install-hooks 自动安装。

  手动调用: echo '{"event":"Stop","session_id":"xxx"}' | python -m cc_stats.hooks
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


def _read_hook_event() -> dict[str, Any] | None:
    """从 stdin 读取 Claude Code hook 事件 JSON"""
    try:
        if sys.stdin.isatty():
            return None
        raw = sys.stdin.read().strip()
        if not raw:
            return None
        return json.loads(raw)
    except (json.JSONDecodeError, OSError):
        return None


def _get_project_name() -> str:
    """从环境变量或 CWD 获取项目名"""
    cwd = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
    return Path(cwd).name


def handle_stop(event: dict[str, Any]) -> None:
    """处理 Stop 事件 — 会话完成通知"""
    from .notifier import notify_session_complete

    # Stop 事件的 JSON 结构: {"event": "Stop", "session_id": "...", ...}
    # 尝试从 cc-stats 缓存获取会话统计
    session_id = event.get("session_id", "")
    project = _get_project_name()

    # 尝试快速统计当前会话
    duration = 0.0
    tokens = 0
    cost = 0.0

    # 从 stop_reason 判断是否正常结束
    stop_reason = event.get("stop_reason", "end_turn")
    if stop_reason == "user_cancelled":
        return  # 用户主动取消不通知

    # 尝试解析最近的会话文件获取统计
    stats = _quick_session_stats(session_id)
    if stats:
        duration = stats.get("duration", 0)
        tokens = stats.get("tokens", 0)
        cost = stats.get("cost", 0)

    notify_session_complete(
        duration_seconds=duration,
        tokens=tokens,
        cost=cost,
        project=project,
    )


def _quick_session_stats(session_id: str) -> dict[str, Any] | None:
    """快速获取会话统计（轻量级，不做完整解析）"""
    if not session_id:
        return None

    # 在 ~/.claude/projects/ 下搜索对应的 JSONL 文件
    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.exists():
        return None

    target_file = None
    for proj_dir in projects_dir.iterdir():
        if not proj_dir.is_dir():
            continue
        candidate = proj_dir / f"{session_id}.jsonl"
        if candidate.exists():
            target_file = candidate
            break

    if not target_file:
        return None

    try:
        from .parser import parse_jsonl
        from .analyzer import analyze_session

        session = parse_jsonl(target_file)
        stats = analyze_session(session)

        total_tokens = stats.token_usage.total
        # 快速费用估算
        cost = total_tokens / 1e6 * 10  # 粗略估算
        duration = stats.active_duration.total_seconds()

        return {
            "duration": duration,
            "tokens": total_tokens,
            "cost": cost,
        }
    except Exception:
        return None


def handle_pre_tool_use(event: dict[str, Any]) -> None:
    """处理 PreToolUse 事件 — 权限请求通知

    仅当工具需要用户确认权限时通知（如 Bash 危险命令、文件写入等）。
    Claude Code 内部已有权限判断逻辑，这里只处理 hook 传来的事件。
    """
    from .notifier import notify_permission_request

    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input", {})

    # 只通知需要用户确认的工具调用
    # Claude Code 只会在需要确认时触发 PreToolUse hook
    description = ""
    if isinstance(tool_input, dict):
        # 提取有意义的描述
        description = (
            tool_input.get("command", "")
            or tool_input.get("file_path", "")
            or tool_input.get("description", "")
        )

    notify_permission_request(tool_name, description)


def handle_notification(event: dict[str, Any]) -> None:
    """处理 Notification 事件 — Claude Code 空闲等待"""
    from .notifier import send_notification

    notification_type = event.get("notification_type", "")
    message = event.get("message", "")

    if notification_type == "idle_prompt":
        send_notification(
            "Claude Code 等待输入",
            message or "Claude Code is waiting for your input",
            notify_type="permission_request",
            sound="Ping",
        )


def process_hook_event(event: dict[str, Any]) -> None:
    """路由 hook 事件到对应处理函数"""
    event_type = event.get("event", "")

    handlers = {
        "Stop": handle_stop,
        "PreToolUse": handle_pre_tool_use,
        "Notification": handle_notification,
    }

    handler = handlers.get(event_type)
    if handler:
        handler(event)


# ---------------------------------------------------------------------------
# Hook Installation
# ---------------------------------------------------------------------------

def get_hook_command() -> str:
    """获取当前环境的 hook 命令"""
    # 优先使用 python -m 方式，兼容性最好
    return f"{sys.executable} -m cc_stats.hooks"


def install_hooks(scope: str = "user") -> bool:
    """安装 Claude Code hooks 到 settings.json

    Args:
        scope: "user" (全局) 或 "project" (当前项目)

    Returns:
        是否安装成功
    """
    if scope == "project":
        settings_path = Path.cwd() / ".claude" / "settings.local.json"
    else:
        settings_path = Path.home() / ".claude" / "settings.json"

    # 读取现有配置
    settings: dict[str, Any] = {}
    if settings_path.exists():
        try:
            with open(settings_path, encoding="utf-8") as f:
                settings = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    hook_cmd = get_hook_command()

    # 构建 hooks 配置
    hooks = settings.get("hooks", {})

    # Stop hook — 会话完成通知
    stop_hooks = hooks.get("Stop", [])
    stop_entry = {
        "type": "command",
        "command": hook_cmd,
    }
    if not _hook_exists(stop_hooks, hook_cmd):
        stop_hooks.append(stop_entry)
    hooks["Stop"] = stop_hooks

    # PreToolUse hook — 权限请求通知
    pre_tool_hooks = hooks.get("PreToolUse", [])
    pre_tool_entry = {
        "type": "command",
        "command": hook_cmd,
    }
    if not _hook_exists(pre_tool_hooks, hook_cmd):
        pre_tool_hooks.append(pre_tool_entry)
    hooks["PreToolUse"] = pre_tool_hooks

    settings["hooks"] = hooks

    # 写入配置
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    with open(settings_path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)

    return True


def uninstall_hooks(scope: str = "user") -> bool:
    """卸载 Claude Code hooks"""
    if scope == "project":
        settings_path = Path.cwd() / ".claude" / "settings.local.json"
    else:
        settings_path = Path.home() / ".claude" / "settings.json"

    if not settings_path.exists():
        return True

    try:
        with open(settings_path, encoding="utf-8") as f:
            settings = json.load(f)
    except (json.JSONDecodeError, OSError):
        return False

    hooks = settings.get("hooks", {})
    hook_cmd = get_hook_command()

    for event_type in ("Stop", "PreToolUse"):
        event_hooks = hooks.get(event_type, [])
        hooks[event_type] = [
            h for h in event_hooks
            if not _hook_matches(h, hook_cmd)
        ]
        # 清理空列表
        if not hooks[event_type]:
            del hooks[event_type]

    if hooks:
        settings["hooks"] = hooks
    elif "hooks" in settings:
        del settings["hooks"]

    with open(settings_path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)

    return True


def _hook_exists(hooks_list: list, hook_cmd: str) -> bool:
    """检查 hook 是否已安装"""
    return any(_hook_matches(h, hook_cmd) for h in hooks_list)


def _hook_matches(hook: dict[str, Any] | Any, hook_cmd: str) -> bool:
    """检查 hook 条目是否匹配"""
    if not isinstance(hook, dict):
        return False
    cmd = hook.get("command", "")
    return "cc_stats.hooks" in cmd


# ---------------------------------------------------------------------------
# Module entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """模块入口 — 从 stdin 读取 hook 事件并处理"""
    event = _read_hook_event()
    if event:
        process_hook_event(event)


if __name__ == "__main__":
    main()
