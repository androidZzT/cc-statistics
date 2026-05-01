"""Usage Quota 预测器 — 基于滑动窗口的用量额度分析

支持多种窗口画像：
- Claude Pro Sonnet：5 分钟 output token 滚动窗口（默认 40_000 tokens）
- Codex 订阅：5 小时 / 7 天滚动窗口（OpenAI Plus/Pro 限额因档位而异，本工具不假设具体限额）
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from .analyzer import SessionStats
from .pricing import match_model_pricing

# Claude 默认限制：Pro Sonnet 系列 5 分钟滑动窗口
DEFAULT_WINDOW_LIMIT = 40_000  # output tokens / 5 min
DEFAULT_WINDOW_MINUTES = 5


@dataclass
class RateLimitStatus:
    """单个滚动窗口的用量状态。

    同一份字段服务于不同画像：Claude 5-min 关注 output_tokens，
    Codex 5h/7d 关注 total_tokens 与 messages（user 交互轮数）。

    保持位置参数与旧调用方兼容，新增字段带默认值放在尾部。
    """
    status: str          # "safe" | "warning" | "critical" | "idle"
    window_limit: int    # 0 表示未设定限额
    window_used: int     # 当前窗口已用 token 数（按 metric）
    pct: float           # window_used / window_limit；limit=0 时为 0.0
    rate_per_min: float  # 窗口内平均 tokens/min
    minutes_until_limit: float | None  # None = 无限额或不会触发
    # —— 多窗口扩展（带默认值，向后兼容旧构造方式） ——
    label: str = "Claude 5-min"             # "Claude 5-min" / "Codex 5h" / "Codex 7d"
    metric: str = "output_tokens"           # "output_tokens" | "total_tokens" | "used_percent"
    window_minutes: int = DEFAULT_WINDOW_MINUTES
    messages: int = 0                       # 窗口内交互轮数（Codex 用）
    cost_usd: float = 0.0                   # 窗口内估算费用（按真实模型单价）
    # —— 直读自 Codex JSONL 里 OpenAI 后端 snapshot 的字段（snapshot 模式专用） ——
    source_kind: str = "estimated"          # "estimated" | "api_snapshot"
    resets_at_unix: int | None = None       # 窗口重置 Unix 时间戳（snapshot 模式提供）
    snapshot_age_minutes: float | None = None  # 此 snapshot 距今多少分钟（陈旧提示用）


def _classify(pct: float) -> str:
    if pct >= 0.85:
        return "critical"
    if pct >= 0.60:
        return "warning"
    return "safe"


def _idle(label: str, metric: str, window_minutes: int, window_limit: int) -> RateLimitStatus:
    return RateLimitStatus(
        label=label,
        metric=metric,
        status="idle",
        window_minutes=window_minutes,
        window_limit=window_limit,
        window_used=0,
        pct=0.0,
        rate_per_min=0.0,
        minutes_until_limit=None,
    )


def analyze_rate_limit(
    stats: SessionStats,
    window_limit: int = DEFAULT_WINDOW_LIMIT,
    window_minutes: int = DEFAULT_WINDOW_MINUTES,
) -> RateLimitStatus:
    """Claude Pro Sonnet 5 分钟滚动窗口预测（基于 token_by_minute）。"""
    if not stats.token_by_minute:
        return _idle("Claude 5-min", "output_tokens", window_minutes, window_limit)

    sorted_keys = sorted(stats.token_by_minute.keys())
    latest_key = sorted_keys[-1]

    try:
        latest_dt = datetime.strptime(latest_key, "%Y-%m-%d %H:%M")
    except ValueError:
        return _idle("Claude 5-min", "output_tokens", window_minutes, window_limit)

    window_start_dt = latest_dt - timedelta(minutes=window_minutes)
    window_start_key = window_start_dt.strftime("%Y-%m-%d %H:%M")

    window_used = 0
    active_minutes = 0
    for key in sorted_keys:
        if key > window_start_key:
            window_used += stats.token_by_minute[key].output_tokens
            active_minutes += 1

    if active_minutes == 0:
        return _idle("Claude 5-min", "output_tokens", window_minutes, window_limit)

    pct = window_used / window_limit if window_limit > 0 else 0.0
    rate_per_min = window_used / window_minutes

    remaining = window_limit - window_used
    if rate_per_min > 0 and remaining > 0:
        minutes_until_limit: float | None = remaining / rate_per_min
    elif remaining <= 0:
        minutes_until_limit = 0.0
    else:
        minutes_until_limit = None

    return RateLimitStatus(
        label="Claude 5-min",
        metric="output_tokens",
        status=_classify(pct),
        window_minutes=window_minutes,
        window_limit=window_limit,
        window_used=window_used,
        pct=pct,
        rate_per_min=rate_per_min,
        minutes_until_limit=minutes_until_limit,
        messages=0,
        cost_usd=0.0,
    )


def _parse_iso(ts: str) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def analyze_codex_quota_snapshot(
    stats: SessionStats,
    now: datetime | None = None,
) -> list[RateLimitStatus]:
    """从 Codex JSONL 缓存的 OpenAI 后端 snapshot 直接构建 RateLimitStatus。

    Codex CLI 在每次 token_count 事件里都会写下 `rate_limits.primary`（5h 滚动窗口）
    和 `rate_limits.secondary`（周窗口）的 `used_percent`，本函数把 snapshot 翻译成
    与本工具其余统计一致的 RateLimitStatus 列表。

    无 snapshot 时返回空列表，调用方可以回退到本地估算（analyze_codex_window）。
    """
    rl = getattr(stats, "codex_rate_limits", None)
    if not isinstance(rl, dict) or not rl:
        return []

    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    else:
        now = now.astimezone(timezone.utc)

    snapshot_dt = _parse_iso(getattr(stats, "codex_rate_limits_ts", "") or "")
    age_minutes: float | None = None
    if snapshot_dt is not None:
        age_minutes = (now - snapshot_dt.astimezone(timezone.utc)).total_seconds() / 60

    out: list[RateLimitStatus] = []

    for key, label in (("primary", "Codex 5h"), ("secondary", "Codex 7d")):
        win = rl.get(key)
        if not isinstance(win, dict):
            continue

        pct_raw = win.get("used_percent")
        if pct_raw is None:
            continue
        try:
            used_percent = float(pct_raw)
        except (TypeError, ValueError):
            continue
        if used_percent < 0:
            continue

        # 与本地 status 分级保持一致
        pct = max(min(used_percent / 100.0, 1.0), 0.0)
        # API 报告超 100% 时直接 critical
        if used_percent >= 100 or pct >= 0.85:
            status = "critical"
        elif pct >= 0.60:
            status = "warning"
        else:
            status = "safe"

        wm_raw = win.get("window_minutes")
        try:
            window_minutes = int(wm_raw) if wm_raw is not None else (
                300 if key == "primary" else 60 * 24 * 7
            )
        except (TypeError, ValueError):
            window_minutes = 300 if key == "primary" else 60 * 24 * 7

        # resets_at_unix → minutes_until_limit（剩余分钟）
        resets_at = win.get("resets_at")
        try:
            resets_at_unix = int(resets_at) if resets_at is not None else None
        except (TypeError, ValueError):
            resets_at_unix = None

        if resets_at_unix is not None:
            minutes_until_reset: float | None = max(
                (resets_at_unix - now.timestamp()) / 60, 0.0
            )
        else:
            minutes_until_reset = None

        out.append(RateLimitStatus(
            status=status,
            window_limit=100,            # 用 100 作为 used_percent 的分母
            window_used=int(round(used_percent)),
            pct=pct,
            rate_per_min=0.0,            # snapshot 不携带 burn rate
            minutes_until_limit=minutes_until_reset,
            label=label,
            metric="used_percent",
            window_minutes=window_minutes,
            messages=0,
            cost_usd=0.0,
            source_kind="api_snapshot",
            resets_at_unix=resets_at_unix,
            snapshot_age_minutes=age_minutes,
        ))

    return out


def _parse_codex_hour_key(key: str) -> datetime | None:
    """analyzer 写入的 'YYYY-MM-DDTHH' UTC 小时键"""
    try:
        return datetime.strptime(key, "%Y-%m-%dT%H").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def analyze_codex_window(
    stats: SessionStats,
    hours: int,
    label: str,
    window_limit: int = 0,
    now: datetime | None = None,
) -> RateLimitStatus:
    """Codex 订阅滚动窗口（5h / 7d 等）。

    复用 RateLimitStatus 数据形态：window_used = 总 token 数（含 cache），
    messages = 窗口内 user_message 数，cost_usd = 按模型真实单价分别计费的合计。

    数据源：analyzer 在解析 Codex 会话时填充的 codex_token_by_hour /
    codex_messages_by_hour（按 UTC 小时分桶，按模型嵌套）。
    """
    window_minutes = hours * 60
    metric = "total_tokens"

    if not stats.codex_token_by_hour and not stats.codex_messages_by_hour:
        return _idle(label, metric, window_minutes, window_limit)

    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    else:
        now = now.astimezone(timezone.utc)
    since = now - timedelta(hours=hours)

    messages = 0
    for hour_key, count in stats.codex_messages_by_hour.items():
        dt = _parse_codex_hour_key(hour_key)
        if dt is None or dt < since or dt > now:
            continue
        messages += count

    total_tokens = 0
    cost_usd = 0.0
    for hour_key, per_model in stats.codex_token_by_hour.items():
        dt = _parse_codex_hour_key(hour_key)
        if dt is None or dt < since or dt > now:
            continue
        for model, tu in per_model.items():
            total_tokens += (
                tu.input_tokens
                + tu.output_tokens
                + tu.cache_read_input_tokens
                + tu.cache_creation_input_tokens
            )
            p = match_model_pricing(model or "")
            cost_usd += tu.input_tokens / 1_000_000 * p["input"]
            cost_usd += tu.output_tokens / 1_000_000 * p["output"]
            cost_usd += tu.cache_read_input_tokens / 1_000_000 * p["cache_read"]
            cost_usd += tu.cache_creation_input_tokens / 1_000_000 * p["cache_create"]

    if messages == 0 and total_tokens == 0:
        return _idle(label, metric, window_minutes, window_limit)

    pct = total_tokens / window_limit if window_limit > 0 else 0.0
    rate_per_min = total_tokens / window_minutes if window_minutes > 0 else 0.0

    if window_limit > 0:
        remaining = window_limit - total_tokens
        if rate_per_min > 0 and remaining > 0:
            minutes_until_limit: float | None = remaining / rate_per_min
        elif remaining <= 0:
            minutes_until_limit = 0.0
        else:
            minutes_until_limit = None
        status = _classify(pct)
    else:
        # 没有限额 → 仅展示当前用量
        minutes_until_limit = None
        status = "safe"

    return RateLimitStatus(
        label=label,
        metric=metric,
        status=status,
        window_minutes=window_minutes,
        window_limit=window_limit,
        window_used=total_tokens,
        pct=pct,
        rate_per_min=rate_per_min,
        minutes_until_limit=minutes_until_limit,
        messages=messages,
        cost_usd=round(cost_usd, 4),
    )
