"""Usage Quota 预测器 — 基于滑动窗口的用量额度分析"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from .analyzer import SessionStats

# 默认限制：Claude Pro Sonnet 系列 5 分钟滑动窗口
DEFAULT_WINDOW_LIMIT = 40_000  # output tokens / 5 min
DEFAULT_WINDOW_MINUTES = 5


@dataclass
class RateLimitStatus:
    """用量额度状态"""
    status: str          # "safe" | "warning" | "critical" | "idle"
    window_limit: int    # 5 分钟窗口 limit（默认 40000）
    window_used: int     # 5 分钟内已用 output tokens
    pct: float           # window_used / window_limit (0.0 ~ 1.0+)
    rate_per_min: float  # tokens/min（最近窗口内）
    minutes_until_limit: float | None  # None = 不会触发


def analyze_rate_limit(
    stats: SessionStats,
    window_limit: int = DEFAULT_WINDOW_LIMIT,
    window_minutes: int = DEFAULT_WINDOW_MINUTES,
) -> RateLimitStatus:
    """基于 token_by_minute 数据计算用量额度预测

    Args:
        stats: 会话统计结果（需要 token_by_minute 数据）
        window_limit: 滑动窗口的 output token 上限
        window_minutes: 滑动窗口大小（分钟）
    """
    if not stats.token_by_minute:
        return RateLimitStatus(
            status="idle",
            window_limit=window_limit,
            window_used=0,
            pct=0.0,
            rate_per_min=0.0,
            minutes_until_limit=None,
        )

    # 找到数据中最新的时间点作为窗口终点
    sorted_keys = sorted(stats.token_by_minute.keys())
    latest_key = sorted_keys[-1]

    try:
        latest_dt = datetime.strptime(latest_key, "%Y-%m-%d %H:%M")
    except ValueError:
        return RateLimitStatus(
            status="idle",
            window_limit=window_limit,
            window_used=0,
            pct=0.0,
            rate_per_min=0.0,
            minutes_until_limit=None,
        )

    # 窗口起点（不含）：latest - window_minutes
    window_start_dt = latest_dt - timedelta(minutes=window_minutes)
    window_start_key = window_start_dt.strftime("%Y-%m-%d %H:%M")

    # 累加窗口内的 output tokens
    window_used = 0
    active_minutes = 0
    for key in sorted_keys:
        if key > window_start_key:
            window_used += stats.token_by_minute[key].output_tokens
            active_minutes += 1

    if active_minutes == 0:
        return RateLimitStatus(
            status="idle",
            window_limit=window_limit,
            window_used=0,
            pct=0.0,
            rate_per_min=0.0,
            minutes_until_limit=None,
        )

    pct = window_used / window_limit if window_limit > 0 else 0.0
    rate_per_min = window_used / window_minutes

    # 预测剩余时间
    remaining = window_limit - window_used
    if rate_per_min > 0 and remaining > 0:
        minutes_until_limit = remaining / rate_per_min
    elif remaining <= 0:
        minutes_until_limit = 0.0
    else:
        minutes_until_limit = None

    # 状态分级
    if pct >= 0.85:
        status = "critical"
    elif pct >= 0.60:
        status = "warning"
    else:
        status = "safe"

    return RateLimitStatus(
        status=status,
        window_limit=window_limit,
        window_used=window_used,
        pct=pct,
        rate_per_min=rate_per_min,
        minutes_until_limit=minutes_until_limit,
    )
