"""macOS 系统通知：会话完成、费用预警、权限请求

通知发送策略：
1. 优先使用 UserNotifications (通过 Swift App 中转)
2. 降级使用 osascript (AppleScript) 作为 fallback
3. 可配置 webhook 转发到飞书/钉钉/Slack

智能抑制：
- 终端窗口有焦点时不弹通知（避免打扰正在看的用户）
- 可通过配置文件关闭指定类型的通知
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_CONFIG_DIR = Path.home() / ".cc-stats"
_CONFIG_FILE = _CONFIG_DIR / "notify_config.json"

_DEFAULT_CONFIG: dict[str, Any] = {
    "enabled": True,
    "session_complete": True,
    "cost_alert": True,
    "permission_request": True,
    "smart_suppress": True,
    "sound": "Glass",
    "webhook_url": "",
    "webhook_platform": "auto",
    # 终端 bundle ID 列表，用于焦点检测
    "terminal_bundle_ids": [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.kitty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.microsoft.VSCode",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.todesktop.230313mzl4w4u92",  # Cursor
    ],
}


def load_config() -> dict[str, Any]:
    """加载通知配置，不存在则返回默认值"""
    if _CONFIG_FILE.exists():
        try:
            with open(_CONFIG_FILE, encoding="utf-8") as f:
                saved = json.load(f)
            # 合并默认值（确保新字段有值）
            merged = {**_DEFAULT_CONFIG, **saved}
            return merged
        except (json.JSONDecodeError, OSError):
            pass
    return dict(_DEFAULT_CONFIG)


def save_config(config: dict[str, Any]) -> None:
    """保存通知配置"""
    _CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(_CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Focus Detection (Smart Suppress)
# ---------------------------------------------------------------------------

def is_terminal_focused() -> bool:
    """检测终端应用是否在前台（有焦点）

    通过 AppleScript 获取当前 frontmost 应用的 bundle ID，
    与已知终端 bundle ID 列表比较。
    """
    script = (
        'tell application "System Events" to get bundle identifier '
        'of first application process whose frontmost is true'
    )
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode != 0:
            return False
        bundle_id = result.stdout.strip()
        config = load_config()
        return bundle_id in config.get("terminal_bundle_ids", [])
    except (subprocess.TimeoutExpired, OSError):
        return False


def should_suppress(config: dict[str, Any] | None = None) -> bool:
    """是否应该抑制通知"""
    if config is None:
        config = load_config()
    if not config.get("enabled", True):
        return True
    if config.get("smart_suppress", True) and is_terminal_focused():
        return True
    return False


# ---------------------------------------------------------------------------
# Notification Sending
# ---------------------------------------------------------------------------

def _escape_applescript(text: str) -> str:
    """转义 AppleScript 字符串中的特殊字符"""
    return (
        text
        .replace("\\", "\\\\")
        .replace('"', '\\"')
    )


def send_notification(
    title: str,
    body: str,
    *,
    sound: str | None = None,
    notify_type: str = "general",
    force: bool = False,
) -> bool:
    """发送 macOS 系统通知

    Args:
        title: 通知标题
        body: 通知内容
        sound: 系统声音名称（如 Glass, Ping, Pop 等），None 则用配置值
        notify_type: 通知类型 (session_complete / cost_alert / permission_request / general)
        force: 跳过智能抑制，强制发送

    Returns:
        是否成功发送
    """
    config = load_config()

    # 检查该类型通知是否开启
    if notify_type != "general" and not config.get(notify_type, True):
        return False

    # 智能抑制
    if not force and should_suppress(config):
        return False

    if sound is None:
        sound = config.get("sound", "Glass")

    # 发送 macOS 通知
    sent = _send_osascript(title, body, sound)

    # 同时发送 webhook（如果配置了）
    webhook_url = config.get("webhook_url", "")
    if webhook_url:
        _send_webhook(title, body, webhook_url, config.get("webhook_platform", "auto"))

    return sent


def _send_osascript(title: str, body: str, sound: str = "Glass") -> bool:
    """通过 osascript 发送系统通知"""
    safe_title = _escape_applescript(title)
    safe_body = _escape_applescript(body)
    safe_sound = _escape_applescript(sound)
    script = (
        f'display notification "{safe_body}" '
        f'with title "{safe_title}" '
        f'sound name "{safe_sound}"'
    )
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True, timeout=5,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def _send_webhook(
    title: str, body: str, webhook_url: str, platform: str = "auto",
) -> bool:
    """转发通知到 webhook"""
    import urllib.request
    import urllib.error

    # 自动检测平台
    if platform == "auto":
        if "feishu.cn" in webhook_url or "larksuite.com" in webhook_url:
            platform = "feishu"
        elif "dingtalk.com" in webhook_url:
            platform = "dingtalk"
        elif "hooks.slack.com" in webhook_url:
            platform = "slack"
        elif "discord.com" in webhook_url:
            platform = "discord"
        else:
            platform = "slack"  # 默认用 Slack 格式

    if platform == "feishu":
        payload = {
            "msg_type": "text",
            "content": {"text": f"📢 {title}\n{body}"},
        }
    elif platform == "dingtalk":
        payload = {
            "msgtype": "text",
            "text": {"content": f"📢 {title}\n{body}"},
        }
    elif platform == "discord":
        payload = {"content": f"**{title}**\n{body}"}
    else:
        payload = {"text": f"*{title}*\n{body}"}

    data = json.dumps(payload, ensure_ascii=False).encode()
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status == 200
    except (urllib.error.URLError, OSError):
        return False


# ---------------------------------------------------------------------------
# High-Level Notification Functions
# ---------------------------------------------------------------------------

def notify_session_complete(
    duration_seconds: float = 0,
    tokens: int = 0,
    cost: float = 0,
    project: str = "",
) -> bool:
    """会话完成通知"""
    parts = []
    if project:
        parts.append(project)
    if duration_seconds > 0:
        mins = int(duration_seconds) // 60
        parts.append(f"{mins}min" if mins > 0 else f"{int(duration_seconds)}s")
    if tokens > 0:
        if tokens >= 1_000_000:
            parts.append(f"{tokens / 1e6:.1f}M tokens")
        elif tokens >= 1_000:
            parts.append(f"{tokens / 1e3:.1f}K tokens")
        else:
            parts.append(f"{tokens} tokens")
    if cost > 0:
        parts.append(f"${cost:.2f}")

    body = " · ".join(parts) if parts else "Task finished"
    return send_notification(
        "Claude Code 会话完成",
        body,
        notify_type="session_complete",
    )


def notify_cost_alert(current_cost: float, limit: float, period: str = "daily") -> bool:
    """费用预警通知"""
    label = "单日" if period == "daily" else "每周"
    return send_notification(
        "⚠️ 费用预警",
        f"{label}费用 ${current_cost:.2f} 已超过上限 ${limit:.2f}",
        notify_type="cost_alert",
        sound="Sosumi",
        force=True,  # 费用预警不抑制
    )


def notify_permission_request(tool_name: str = "", description: str = "") -> bool:
    """权限请求通知 — Claude Code 需要用户确认时提醒"""
    body = tool_name
    if description:
        # 截断过长的描述
        desc = description[:120] + "..." if len(description) > 120 else description
        body = f"{tool_name}: {desc}" if tool_name else desc
    if not body:
        body = "Claude Code is waiting for your approval"

    return send_notification(
        "🔐 需要确认权限",
        body,
        notify_type="permission_request",
        sound="Ping",
    )


# ---------------------------------------------------------------------------
# CLI entry for testing
# ---------------------------------------------------------------------------

def _cli_main() -> None:
    """简单的命令行入口，用于测试通知"""
    import argparse

    parser = argparse.ArgumentParser(description="cc-stats notification test")
    parser.add_argument("--type", choices=["session", "cost", "permission", "test"],
                        default="test", help="notification type")
    parser.add_argument("--title", default="CC Stats Test", help="notification title")
    parser.add_argument("--body", default="This is a test notification", help="notification body")
    parser.add_argument("--force", action="store_true", help="skip smart suppress")
    args = parser.parse_args()

    if args.type == "session":
        ok = notify_session_complete(duration_seconds=300, tokens=50000, cost=1.5, project="test-project")
    elif args.type == "cost":
        ok = notify_cost_alert(15.0, 10.0)
    elif args.type == "permission":
        ok = notify_permission_request("Bash", "rm -rf /tmp/test")
    else:
        ok = send_notification(args.title, args.body, force=args.force)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    _cli_main()
