"""Webhook 通知：推送统计摘要到飞书/钉钉/Slack"""

from __future__ import annotations

import json
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .analyzer import SessionStats, analyze_session, merge_stats
from .parser import find_gemini_sessions, find_sessions, parse_gemini_json, parse_jsonl


def _collect_today_stats() -> SessionStats | None:
    """收集今天的统计数据（Claude + Gemini）

    使用 token_by_date 按消息时间戳归日：只要 session 中有消息
    落在今天，该 session 就会被纳入统计。
    """
    today_key = datetime.now().strftime("%Y-%m-%d")
    all_files: list = list(find_sessions())
    all_files.extend(find_gemini_sessions())
    today_stats = []

    for f in all_files:
        try:
            session = parse_gemini_json(f) if f.suffix == ".json" else parse_jsonl(f)
            stats = analyze_session(session)
            # 按消息时间戳归日：token_by_date 包含今天的 key
            has_today_tokens = today_key in stats.token_by_date
            # 回退：无 token_by_date 时，按 end_time 判断
            if not has_today_tokens and not stats.token_by_date:
                today_start = datetime.now(tz=timezone.utc).replace(
                    hour=0, minute=0, second=0, microsecond=0
                )
                has_today_tokens = (
                    stats.end_time is not None and stats.end_time >= today_start
                )
            if has_today_tokens:
                today_stats.append(stats)
        except Exception:
            continue

    if not today_stats:
        return None
    return merge_stats(today_stats) if len(today_stats) > 1 else today_stats[0]


def _estimate_cost(stats: SessionStats) -> float:
    MODEL_PRICING = {
        "claude-opus-4": {"input": 15, "output": 75, "cache_read": 1.5, "cache_create": 18.75},
        "claude-sonnet-4": {"input": 3, "output": 15, "cache_read": 0.3, "cache_create": 3.75},
        "claude-haiku-4": {"input": 0.8, "output": 4, "cache_read": 0.08, "cache_create": 1},
        "gemini-2.5-pro": {"input": 1.25, "output": 10, "cache_read": 0.31, "cache_create": 1.25},
        "gemini-2.5-flash": {"input": 0.15, "output": 0.60, "cache_read": 0.04, "cache_create": 0.15},
        "gemini-2.0-flash": {"input": 0.10, "output": 0.40, "cache_read": 0.025, "cache_create": 0.10},
    }
    cost = 0.0
    for model, usage in stats.token_by_model.items():
        lower = model.lower()
        p = None
        # Gemini 模型精确匹配
        for key in ("gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"):
            if key in lower:
                p = MODEL_PRICING[key]
                break
        # Claude 模型关键词匹配
        if not p:
            for key in MODEL_PRICING:
                if key.startswith("claude-") and key.split("-")[1] in lower:
                    p = MODEL_PRICING[key]
                    break
        if not p:
            p = MODEL_PRICING.get("gemini-2.5-flash") if "gemini" in lower else MODEL_PRICING["claude-opus-4"]
        cost += usage.input_tokens / 1e6 * p["input"]
        cost += usage.output_tokens / 1e6 * p["output"]
        cost += usage.cache_read_input_tokens / 1e6 * p["cache_read"]
        cost += usage.cache_creation_input_tokens / 1e6 * p["cache_create"]
    return cost


def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000_000:
        return f"{n / 1e9:.1f}B"
    if n >= 1_000_000:
        return f"{n / 1e6:.1f}M"
    if n >= 1_000:
        return f"{n / 1e3:.1f}K"
    return str(n)


def _fmt_duration(seconds: float) -> str:
    h = int(seconds) // 3600
    m = (int(seconds) % 3600) // 60
    if h > 0:
        return f"{h}h {m}m"
    return f"{m}m"


def _build_message(stats: SessionStats) -> dict:
    """构建通知消息内容"""
    cost = _estimate_cost(stats)
    today = datetime.now().strftime("%Y-%m-%d")
    active = stats.active_duration.total_seconds()
    ai_pct = (
        round(stats.ai_duration.total_seconds() / active * 100)
        if active > 0 else 0
    )

    # 效率评分
    total_tokens = stats.token_usage.total
    total_code = stats.total_added + stats.total_removed
    code_per_1k = round(total_code / max(total_tokens / 1000, 1), 2) if total_tokens > 0 else 0
    avg_tpm = total_tokens // max(stats.user_message_count, 1)
    code_score = min(40, int(code_per_1k / 0.5 * 40))
    precision_score = max(0, min(30, int((1 - min(avg_tpm, 200_000) / 200_000) * 30)))
    util_score = min(30, int(ai_pct / 70 * 30))
    total_score = code_score + precision_score + util_score
    grade = "S" if total_score >= 90 else "A" if total_score >= 75 else "B" if total_score >= 60 else "C" if total_score >= 40 else "D"

    return {
        "date": today,
        "sessions": len([s for s in [stats]]),  # merged = 1
        "instructions": stats.user_message_count,
        "active_time": _fmt_duration(active),
        "ai_ratio": f"{ai_pct}%",
        "tokens": _fmt_tokens(total_tokens),
        "cost": f"${cost:.2f}",
        "code_added": stats.total_added + stats.git_total_added,
        "code_removed": stats.total_removed + stats.git_total_removed,
        "grade": grade,
        "score": total_score,
        "git_commits": stats.git_commit_count,
    }


def send_feishu(webhook_url: str, stats: SessionStats) -> bool:
    """发送飞书机器人通知"""
    msg = _build_message(stats)
    payload = {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {"tag": "plain_text", "content": f"Claude Code 日报 {msg['date']}"},
                "template": "blue",
            },
            "elements": [
                {
                    "tag": "div",
                    "fields": [
                        {"is_short": True, "text": {"tag": "lark_md", "content": f"**会话数**\n{msg['instructions']} 条指令"}},
                        {"is_short": True, "text": {"tag": "lark_md", "content": f"**活跃时长**\n{msg['active_time']} (AI {msg['ai_ratio']})"}},
                        {"is_short": True, "text": {"tag": "lark_md", "content": f"**Token**\n{msg['tokens']}"}},
                        {"is_short": True, "text": {"tag": "lark_md", "content": f"**费用**\n{msg['cost']}"}},
                        {"is_short": True, "text": {"tag": "lark_md", "content": f"**代码**\n+{msg['code_added']} / -{msg['code_removed']}"}},
                        {"is_short": True, "text": {"tag": "lark_md", "content": f"**效率**\n{msg['grade']} ({msg['score']}/100)"}},
                    ],
                },
            ],
        },
    }
    return _post_json(webhook_url, payload)


def send_dingtalk(webhook_url: str, stats: SessionStats) -> bool:
    """发送钉钉机器人通知"""
    msg = _build_message(stats)
    text = (
        f"### Claude Code 日报 {msg['date']}\n\n"
        f"| 指标 | 数值 |\n"
        f"|------|------|\n"
        f"| 指令数 | {msg['instructions']} |\n"
        f"| 活跃时长 | {msg['active_time']} (AI {msg['ai_ratio']}) |\n"
        f"| Token | {msg['tokens']} |\n"
        f"| 费用 | {msg['cost']} |\n"
        f"| 代码 | +{msg['code_added']} / -{msg['code_removed']} |\n"
        f"| 效率 | {msg['grade']} ({msg['score']}/100) |\n"
        f"| Git | {msg['git_commits']} commits |"
    )
    payload = {"msgtype": "markdown", "markdown": {"title": "Claude Code 日报", "text": text}}
    return _post_json(webhook_url, payload)


def send_slack(webhook_url: str, stats: SessionStats) -> bool:
    """发送 Slack 通知"""
    msg = _build_message(stats)
    text = (
        f"*Claude Code Daily Report {msg['date']}*\n"
        f"• Instructions: {msg['instructions']} | Active: {msg['active_time']} (AI {msg['ai_ratio']})\n"
        f"• Tokens: {msg['tokens']} | Cost: {msg['cost']}\n"
        f"• Code: +{msg['code_added']} / -{msg['code_removed']} | {msg['git_commits']} commits\n"
        f"• Efficiency: {msg['grade']} ({msg['score']}/100)"
    )
    payload = {"text": text}
    return _post_json(webhook_url, payload)


def _post_json(url: str, payload: dict) -> bool:
    """POST JSON 到 webhook URL"""
    data = json.dumps(payload, ensure_ascii=False).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except (urllib.error.URLError, OSError) as e:
        print(f"Webhook 发送失败: {e}")
        return False


def send_notification(webhook_url: str, platform: str = "auto") -> bool:
    """发送今日统计通知

    Args:
        webhook_url: Webhook URL
        platform: feishu/dingtalk/slack/auto (自动检测)
    """
    stats = _collect_today_stats()
    if not stats:
        print("今天暂无会话数据")
        return False

    # 自动检测平台
    if platform == "auto":
        if "feishu.cn" in webhook_url or "larksuite.com" in webhook_url:
            platform = "feishu"
        elif "dingtalk.com" in webhook_url or "oapi.dingtalk" in webhook_url:
            platform = "dingtalk"
        elif "hooks.slack.com" in webhook_url:
            platform = "slack"
        else:
            print("无法自动检测平台，请指定 --platform feishu/dingtalk/slack")
            return False

    senders = {
        "feishu": send_feishu,
        "dingtalk": send_dingtalk,
        "slack": send_slack,
    }
    sender = senders.get(platform)
    if not sender:
        print(f"不支持的平台: {platform}")
        return False

    if sender(webhook_url, stats):
        print(f"已发送到 {platform}")
        return True
    return False
