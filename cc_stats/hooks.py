"""Claude Code Hook 事件处理器

通过 Claude Code 的 hook 系统触发通知。Hook 事件通过 stdin 传入 JSON。

支持的 hook 事件:
- Stop: 会话结束时发送完成通知
- PreToolUse: 工具调用前发送进度通知
- PermissionRequest: 需要确权时推送审批并支持回写 allow/deny
- Notification: Claude Code 空闲等待用户输入时通知

用法:
  在 ~/.claude/settings.json 中配置 hooks，
  或通过 cc-stats --install-hooks 自动安装。

  手动调用: echo '{"event":"Stop","session_id":"xxx"}' | python -m cc_stats.hooks
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib import error, request
from uuid import uuid4

_DEFAULT_BRIDGE_BASE_URL = "http://127.0.0.1:8765"
_ACTIVE_EVENTS = {
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "Notification",
    "Elicitation",
    "WorktreeCreate",
    "PermissionRequest",
    "PermissionDenied",
}
_IDLE_EVENTS = {
    "Stop",
    "StopFailure",
    "SessionStart",
    "SessionEnd",
}

_HOOK_INSTALL_SPECS: tuple[tuple[str, int | None], ...] = (
    ("SessionStart", None),
    ("SessionEnd", None),
    ("UserPromptSubmit", None),
    ("PreToolUse", None),
    ("PostToolUse", None),
    ("PostToolUseFailure", None),
    ("SubagentStart", None),
    ("SubagentStop", None),
    ("Notification", None),
    ("Elicitation", None),
    ("WorktreeCreate", None),
    ("PreCompact", None),
    ("PostCompact", None),
    ("PermissionRequest", 86400),
    ("Stop", None),
    ("StopFailure", None),
)


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


def _event_name(event: dict[str, Any]) -> str:
    """兼容 Claude hook 字段名差异"""
    name = event.get("event")
    if isinstance(name, str) and name:
        return name
    name = event.get("hook_event_name")
    if isinstance(name, str) and name:
        return name
    return ""


def _extract_action_description(tool_input: Any) -> str:
    if not isinstance(tool_input, dict):
        return ""
    return (
        str(tool_input.get("command", "") or "")
        or str(tool_input.get("file_path", "") or "")
        or str(tool_input.get("description", "") or "")
    )


def _approval_id_from_event(event: dict[str, Any]) -> str:
    for key in ("approval_id", "tool_use_id", "toolUseId", "id"):
        value = event.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return f"apr_{uuid4().hex}"


def _env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def _env_float(name: str, default: float) -> float:
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _derive_activity_state(event: dict[str, Any], event_name: str) -> str | None:
    if event_name == "Notification":
        notification_type = str(event.get("notification_type") or "")
        if notification_type == "idle_prompt":
            return "idle"
    if event_name in _ACTIVE_EVENTS:
        return "active"
    if event_name in _IDLE_EVENTS:
        return "idle"
    return None


def _read_existing_activity_state(state_file: Path) -> dict[str, Any]:
    try:
        if not state_file.exists():
            return {}
        return json.loads(state_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _should_preserve_waiting_approval(
    previous_payload: dict[str, Any],
    event: dict[str, Any],
    event_name: str,
) -> bool:
    previous_event = str(previous_payload.get("event") or "")
    approval_id = str(previous_payload.get("approval_id") or "")
    if previous_event != "PermissionRequest" or not approval_id:
        return False
    if event_name != "Notification":
        return False
    notification_type = str(event.get("notification_type") or "")
    return notification_type == "idle_prompt"


def _write_activity_state(event: dict[str, Any], event_name: str) -> None:
    state = _derive_activity_state(event, event_name)
    if not state:
        return

    state_file = Path.home() / ".cc-stats" / "activity-state.json"
    previous_payload = _read_existing_activity_state(state_file)
    if _should_preserve_waiting_approval(previous_payload, event, event_name):
        return

    tool_name = str(event.get("tool_name") or "")
    action = _extract_action_description(event.get("tool_input"))

    payload: dict[str, Any] = {
        "state": state,
        "event": event_name,
        "timestamp": int(datetime.now(timezone.utc).timestamp() * 1000),
        "bridge_enabled": bool(_bridge_base_url()),
    }
    approval_id = str(event.get("approval_id") or "")
    if approval_id:
        payload["approval_id"] = approval_id
    if tool_name:
        payload["tool_name"] = tool_name
    if action:
        payload["action"] = action
    notification_type = str(event.get("notification_type") or "")
    if notification_type:
        payload["notification_type"] = notification_type

    try:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    except OSError:
        # State file is best-effort only; do not block Claude hooks.
        return


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
    _publish_bridge_event(
        raw_event=event,
        event_type="task_completed",
        payload={
            "duration_sec": int(duration),
            "usage": {"input_tokens": 0, "output_tokens": int(tokens), "cost_usd": float(cost)},
            "result_summary": "Claude task completed",
        },
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
        from .pricing import estimate_cost_from_token_by_model

        session = parse_jsonl(target_file)
        stats = analyze_session(session)

        total_tokens = stats.token_usage.total
        cost = estimate_cost_from_token_by_model(stats.token_by_model)
        duration = stats.active_duration.total_seconds()

        return {
            "duration": duration,
            "tokens": total_tokens,
            "cost": cost,
        }
    except Exception:
        return None


def handle_pre_tool_use(event: dict[str, Any]) -> None:
    """处理 PreToolUse 事件 — 工具进度上报（默认不发权限通知）

    注意：PreToolUse 在实际运行中会覆盖常规工具调用（例如 Read），
    不应默认视为“需要确权”。权限提醒应由 PermissionRequest 事件触发。
    如需兼容旧行为，可设置环境变量 CC_STATS_NOTIFY_PRE_TOOL_USE=1。
    """
    from .notifier import notify_permission_request

    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input", {})
    description = _extract_action_description(tool_input)

    if _env_bool("CC_STATS_NOTIFY_PRE_TOOL_USE", False):
        notify_permission_request(tool_name, description)
    _publish_bridge_event(
        raw_event=event,
        event_type="task_progress",
        payload={
            "phase": "pre_tool_use",
            "summary": description or f"Preparing tool: {tool_name or 'Unknown'}",
            "duration_sec": 0,
            "usage": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
            "last_tool": {
                "name": tool_name or "Unknown",
                "command_preview": description,
                "status": "running",
            },
        },
    )


def handle_permission_request(event: dict[str, Any]) -> dict[str, Any] | None:
    """处理 PermissionRequest 事件 — 发送审批并等待桥接决策。

    返回:
      - None: 不拦截 Claude 默认审批流
      - dict: Claude hookSpecificOutput JSON
    """
    tool_name = str(event.get("tool_name", "") or "")
    tool_input = event.get("tool_input", {})
    description = _extract_action_description(tool_input)
    approval_id = _approval_id_from_event(event)

    _publish_bridge_event(
        raw_event=event,
        event_type="approval_required",
        payload={
            "approval_id": approval_id,
            "tool": tool_name or "Unknown",
            "action": description or "Action requires approval",
            "risk": "medium",
            "reason": "",
            "expires_in_sec": max(1, _env_int("CC_STATS_APPROVAL_EXPIRES_SEC", 300)),
        },
    )

    decision = _wait_bridge_approval_decision(approval_id)
    if decision is None:
        return None

    approved, message = decision
    if approved:
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }
    return {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "deny",
                "message": message or "Denied by user via cc-stats bridge",
            },
        }
    }


def _wait_bridge_approval_decision(approval_id: str) -> tuple[bool, str] | None:
    """轮询 bridge 审批状态，直到 resolved 或超时。"""
    base_url = _bridge_base_url()
    if not base_url:
        return None

    timeout_sec = max(
        1.0,
        _env_float("CC_STATS_BRIDGE_APPROVAL_WAIT_SEC", 300.0),
    )
    poll_sec = max(
        0.2,
        _env_float("CC_STATS_BRIDGE_APPROVAL_POLL_SEC", 0.8),
    )
    deadline = time.monotonic() + timeout_sec

    while time.monotonic() < deadline:
        req = request.Request(f"{base_url}/v1/approvals/{approval_id}", method="GET")
        try:
            with request.urlopen(req, timeout=min(2.0, poll_sec + 0.8)) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except error.HTTPError as exc:
            if exc.code == 404:
                time.sleep(poll_sec)
                continue
            time.sleep(poll_sec)
            continue
        except (error.URLError, OSError, json.JSONDecodeError):
            time.sleep(poll_sec)
            continue

        if not isinstance(data, dict):
            time.sleep(poll_sec)
            continue

        resolved = bool(data.get("resolved", False))
        if not resolved:
            time.sleep(poll_sec)
            continue

        approved = bool(data.get("approved", False))
        reason = str(data.get("reason", "") or "")
        return approved, reason

    return None


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
        _publish_bridge_event(
            raw_event=event,
            event_type="task_progress",
            payload={
                "phase": "waiting_user",
                "summary": message or "Waiting for user input",
                "duration_sec": 0,
                "usage": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
            },
        )


def process_hook_event(event: dict[str, Any]) -> dict[str, Any] | None:
    """路由 hook 事件到对应处理函数"""
    mutable_event = dict(event)
    event_type = _event_name(mutable_event)
    if event_type == "PermissionRequest" and not str(mutable_event.get("approval_id") or "").strip():
        mutable_event["approval_id"] = _approval_id_from_event(mutable_event)
    if event_type:
        _write_activity_state(mutable_event, event_type)

    handlers = {
        "Stop": handle_stop,
        "PreToolUse": handle_pre_tool_use,
        "PermissionRequest": handle_permission_request,
        "Notification": handle_notification,
    }

    handler = handlers.get(event_type)
    if handler:
        result = handler(mutable_event)
        if isinstance(result, dict):
            return result
    return None


def _bridge_base_url() -> str:
    explicit = os.environ.get("CC_STATS_BRIDGE_URL", "").strip().rstrip("/")
    if explicit:
        return explicit
    health_url = f"{_DEFAULT_BRIDGE_BASE_URL}/v1/health"
    req = request.Request(health_url, method="GET")
    try:
        with request.urlopen(req, timeout=0.2) as resp:
            if 200 <= resp.status < 300:
                return _DEFAULT_BRIDGE_BASE_URL
    except (error.URLError, OSError):
        return ""
    return ""


def _publish_bridge_event(raw_event: dict[str, Any], event_type: str, payload: dict[str, Any]) -> None:
    """Optional: forward hook events to local bridge daemon.

    Controlled by env:
    - CC_STATS_BRIDGE_URL, e.g. http://127.0.0.1:8765
    """
    base_url = _bridge_base_url()
    if not base_url:
        return
    session_id = str(raw_event.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", "") or "")
    task_id = str(raw_event.get("task_id") or session_id or f"task_{uuid4().hex}")
    envelope = {
        "version": 1,
        "event_id": f"evt_{uuid4().hex}",
        "type": event_type,
        "task_id": task_id,
        "session_id": session_id,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": "hook",
        "payload": payload,
    }

    body = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    req = request.Request(
        f"{base_url}/v1/events",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=1.5):
            pass
    except (error.URLError, OSError):
        # Bridge is optional. Do not block hooks on network failures.
        return


# ---------------------------------------------------------------------------
# Hook Installation
# ---------------------------------------------------------------------------

def get_hook_command() -> str:
    """获取当前环境的 hook 命令

    优先查找 cc-stats-hooks entry-point binary（uv/pipx 安装场景下可靠），
    找不到时 fallback 到 python -m cc_stats.hooks。
    """
    entry_point = shutil.which("cc-stats-hooks")
    if entry_point:
        return entry_point
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

    hooks = settings.get("hooks", {})
    for event_type, timeout in _HOOK_INSTALL_SPECS:
        event_hooks = hooks.get(event_type, [])
        entry: dict[str, Any] = {
            "type": "command",
            "command": hook_cmd,
        }
        if timeout is not None:
            entry["timeout"] = timeout
        if not _hook_exists(event_hooks, hook_cmd):
            event_hooks.append(entry)
        hooks[event_type] = event_hooks

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

    for event_type, _ in _HOOK_INSTALL_SPECS:
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
    """检查 hook 条目是否匹配（兼容旧格式和新格式）"""
    if not isinstance(hook, dict):
        return False
    cmd = hook.get("command", "")
    if isinstance(cmd, str) and ("cc_stats.hooks" in cmd or "cc-stats-hooks" in cmd):
        return True
    nested = hook.get("hooks")
    if isinstance(nested, list):
        for item in nested:
            if isinstance(item, dict):
                nested_cmd = item.get("command", "")
                if isinstance(nested_cmd, str) and ("cc_stats.hooks" in nested_cmd or "cc-stats-hooks" in nested_cmd):
                    return True
    return False


# ---------------------------------------------------------------------------
# Module entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """模块入口 — 从 stdin 读取 hook 事件并处理"""
    event = _read_hook_event()
    if event:
        response = process_hook_event(event)
        if response:
            print(json.dumps(response, ensure_ascii=False))


if __name__ == "__main__":
    main()
