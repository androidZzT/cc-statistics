"""统一模型定价与匹配逻辑。"""

from __future__ import annotations

from typing import Any, TypedDict


class Pricing(TypedDict):
    """USD per 1M tokens."""

    input: float
    output: float
    cache_read: float
    cache_create: float


# 价格来源（2026-06-10 校准）：
# - OpenAI: https://developers.openai.com/api/docs/pricing
# - Anthropic: https://platform.claude.com/docs/en/about-claude/pricing
# - Gemini: https://ai.google.dev/gemini-api/docs/pricing
#
# 注：
# - 默认按 Standard / Paid / short context 或 <=200k 档位计算。
# - Batch/Flex/Priority/Fast mode/Data residency/长上下文等需要请求模式或上下文字段，当前日志无法稳定区分。
# - OpenAI 暂无“cache write”单独价格字段，cache_create 退化为 input 单价。
MODEL_PRICING: dict[str, Pricing] = {
    # Claude
    "claude-fable-5": {"input": 10.0, "output": 50.0, "cache_read": 1.00, "cache_create": 12.50},
    "claude-mythos-5": {"input": 10.0, "output": 50.0, "cache_read": 1.00, "cache_create": 12.50},
    "claude-opus-4.8": {"input": 5.0, "output": 25.0, "cache_read": 0.50, "cache_create": 6.25},
    "claude-opus-4.7": {"input": 5.0, "output": 25.0, "cache_read": 0.50, "cache_create": 6.25},
    "claude-opus-4.6": {"input": 5.0, "output": 25.0, "cache_read": 0.50, "cache_create": 6.25},
    "claude-opus-4.5": {"input": 5.0, "output": 25.0, "cache_read": 0.50, "cache_create": 6.25},
    "claude-opus-4.1": {"input": 15.0, "output": 75.0, "cache_read": 1.50, "cache_create": 18.75},
    "claude-opus-4": {"input": 15.0, "output": 75.0, "cache_read": 1.50, "cache_create": 18.75},
    "claude-sonnet-4.6": {"input": 3.0, "output": 15.0, "cache_read": 0.30, "cache_create": 3.75},
    "claude-sonnet-4.5": {"input": 3.0, "output": 15.0, "cache_read": 0.30, "cache_create": 3.75},
    "claude-sonnet-4": {"input": 3.0, "output": 15.0, "cache_read": 0.30, "cache_create": 3.75},
    "claude-haiku-4.5": {"input": 1.0, "output": 5.0, "cache_read": 0.10, "cache_create": 1.25},
    # 兼容旧会话（历史模型）
    "claude-haiku-legacy": {"input": 0.8, "output": 4.0, "cache_read": 0.08, "cache_create": 1.0},
    # OpenAI (GPT/Codex)
    "gpt-5.5": {"input": 5.00, "output": 30.00, "cache_read": 0.50, "cache_create": 5.00},
    "gpt-5.5-pro": {"input": 30.00, "output": 180.00, "cache_read": 30.00, "cache_create": 30.00},
    "gpt-5.4": {"input": 2.50, "output": 15.00, "cache_read": 0.25, "cache_create": 2.50},
    "gpt-5.4-mini": {"input": 0.75, "output": 4.50, "cache_read": 0.075, "cache_create": 0.75},
    "gpt-5.4-nano": {"input": 0.20, "output": 1.25, "cache_read": 0.020, "cache_create": 0.20},
    "gpt-5.4-pro": {"input": 30.00, "output": 180.00, "cache_read": 30.00, "cache_create": 30.00},
    "chat-latest": {"input": 5.00, "output": 30.00, "cache_read": 0.50, "cache_create": 5.00},
    "gpt-5.3-codex": {"input": 1.75, "output": 14.00, "cache_read": 0.175, "cache_create": 1.75},
    "gpt-5.3-chat-latest": {"input": 5.00, "output": 30.00, "cache_read": 0.50, "cache_create": 5.00},
    # 兼容旧会话（历史模型）
    "gpt-4o": {"input": 2.50, "output": 10.00, "cache_read": 1.25, "cache_create": 2.50},
    "gpt-4o-mini": {"input": 0.15, "output": 0.60, "cache_read": 0.075, "cache_create": 0.15},
    "o1": {"input": 15.00, "output": 60.00, "cache_read": 7.50, "cache_create": 15.00},
    "o3": {"input": 10.00, "output": 40.00, "cache_read": 2.50, "cache_create": 10.00},
    "o3-mini": {"input": 1.10, "output": 4.40, "cache_read": 0.55, "cache_create": 1.10},
    "o4-mini": {"input": 1.10, "output": 4.40, "cache_read": 0.55, "cache_create": 1.10},
    # Gemini
    "gemini-3.5-flash": {"input": 1.50, "output": 9.00, "cache_read": 0.15, "cache_create": 1.50},
    "gemini-3.1-pro": {"input": 2.00, "output": 12.00, "cache_read": 0.20, "cache_create": 2.00},
    "gemini-3.1-flash-lite": {"input": 0.25, "output": 1.50, "cache_read": 0.025, "cache_create": 0.25},
    "gemini-3-flash": {"input": 0.50, "output": 3.00, "cache_read": 0.05, "cache_create": 0.50},
    "gemini-2.5-pro": {"input": 1.25, "output": 10.00, "cache_read": 0.125, "cache_create": 1.25},
    "gemini-2.5-flash": {"input": 0.30, "output": 2.50, "cache_read": 0.03, "cache_create": 0.30},
    "gemini-2.5-flash-lite": {"input": 0.10, "output": 0.40, "cache_read": 0.01, "cache_create": 0.10},
    # 兼容旧会话（历史模型）
    "gemini-2.0-flash": {"input": 0.10, "output": 0.40, "cache_read": 0.025, "cache_create": 0.10},
}


def match_model_pricing(model: str) -> Pricing:
    """根据模型名匹配单价，未知模型按同厂商主力模型保守回退。"""
    lower = model.lower()

    # OpenAI / Codex
    if "gpt-5.5-pro" in lower:
        return MODEL_PRICING["gpt-5.5-pro"]
    if "gpt-5.5" in lower:
        return MODEL_PRICING["gpt-5.5"]
    if "gpt-5.4-pro" in lower:
        return MODEL_PRICING["gpt-5.4-pro"]
    if "gpt-5.4-mini" in lower:
        return MODEL_PRICING["gpt-5.4-mini"]
    if "gpt-5.4-nano" in lower:
        return MODEL_PRICING["gpt-5.4-nano"]
    if "gpt-5.4" in lower:
        return MODEL_PRICING["gpt-5.4"]
    if "chat-latest" in lower:
        return MODEL_PRICING["chat-latest"]
    if "gpt-5.3-chat-latest" in lower:
        return MODEL_PRICING["gpt-5.3-chat-latest"]
    if "gpt-5.3-codex" in lower:
        return MODEL_PRICING["gpt-5.3-codex"]
    if "gpt-5" in lower and "codex" in lower:
        return MODEL_PRICING["gpt-5.3-codex"]
    if "gpt-5" in lower:
        return MODEL_PRICING["gpt-5.5"]
    if "gpt-4o-mini" in lower:
        return MODEL_PRICING["gpt-4o-mini"]
    if "gpt-4o" in lower:
        return MODEL_PRICING["gpt-4o"]
    if "o4-mini" in lower:
        return MODEL_PRICING["o4-mini"]
    if "o3-mini" in lower:
        return MODEL_PRICING["o3-mini"]
    if "o3" in lower:
        return MODEL_PRICING["o3"]
    if "o1" in lower:
        return MODEL_PRICING["o1"]

    # Gemini
    if "gemini-3.5-flash" in lower:
        return MODEL_PRICING["gemini-3.5-flash"]
    if "gemini-3.1-pro" in lower:
        return MODEL_PRICING["gemini-3.1-pro"]
    if "gemini-3.1-flash-lite" in lower:
        return MODEL_PRICING["gemini-3.1-flash-lite"]
    if "gemini-3-flash" in lower:
        return MODEL_PRICING["gemini-3-flash"]
    if "gemini-3" in lower:
        return MODEL_PRICING["gemini-3.5-flash"]
    if "gemini-2.5-pro" in lower:
        return MODEL_PRICING["gemini-2.5-pro"]
    if "gemini-2.5-flash-lite" in lower:
        return MODEL_PRICING["gemini-2.5-flash-lite"]
    if "gemini-2.5-flash" in lower:
        return MODEL_PRICING["gemini-2.5-flash"]
    if "gemini-2.0-flash" in lower:
        return MODEL_PRICING["gemini-2.0-flash"]
    if "gemini" in lower:
        return MODEL_PRICING["gemini-3.5-flash"]

    # Claude
    if "fable" in lower:
        return MODEL_PRICING["claude-fable-5"]
    if "mythos" in lower:
        return MODEL_PRICING["claude-mythos-5"]
    if "opus" in lower:
        if "4.8" in lower or "4-8" in lower:
            return MODEL_PRICING["claude-opus-4.8"]
        if "4.7" in lower or "4-7" in lower:
            return MODEL_PRICING["claude-opus-4.7"]
        if "4.6" in lower or "4-6" in lower:
            return MODEL_PRICING["claude-opus-4.6"]
        if "4.5" in lower or "4-5" in lower:
            return MODEL_PRICING["claude-opus-4.5"]
        if "4.1" in lower or "4-1" in lower:
            return MODEL_PRICING["claude-opus-4.1"]
        if "4" in lower:
            return MODEL_PRICING["claude-opus-4"]
        return MODEL_PRICING["claude-opus-4.8"]
    if "haiku" in lower:
        if "4.5" in lower or "4-5" in lower:
            return MODEL_PRICING["claude-haiku-4.5"]
        return MODEL_PRICING["claude-haiku-legacy"]
    if "sonnet" in lower:
        if "4.6" in lower or "4-6" in lower:
            return MODEL_PRICING["claude-sonnet-4.6"]
        if "4.5" in lower or "4-5" in lower:
            return MODEL_PRICING["claude-sonnet-4.5"]
        return MODEL_PRICING["claude-sonnet-4"]

    # 厂商回退（防止历史脏数据导致费用完全丢失）
    if "gpt" in lower or lower.startswith("o"):
        return MODEL_PRICING["gpt-5.5"]
    if "gemini" in lower:
        return MODEL_PRICING["gemini-3.5-flash"]
    return MODEL_PRICING["claude-sonnet-4.6"]


def is_claude_model(model: str) -> bool:
    lower = model.lower()
    return (
        "claude" in lower
        or "sonnet" in lower
        or "opus" in lower
        or "haiku" in lower
        or "fable" in lower
        or "mythos" in lower
    )


def estimate_cost_from_token_by_model(token_by_model: dict[str, Any]) -> float:
    """按 token_by_model 估算总费用。"""
    total = 0.0
    for model, usage in token_by_model.items():
        p = match_model_pricing(model)
        input_tokens = int(getattr(usage, "input_tokens", 0) or 0)
        output_tokens = int(getattr(usage, "output_tokens", 0) or 0)
        cache_read_tokens = int(getattr(usage, "cache_read_input_tokens", 0) or 0)
        cache_create_tokens = int(getattr(usage, "cache_creation_input_tokens", 0) or 0)

        total += input_tokens / 1_000_000 * p["input"]
        total += output_tokens / 1_000_000 * p["output"]
        total += cache_read_tokens / 1_000_000 * p["cache_read"]
        total += cache_create_tokens / 1_000_000 * p["cache_create"]
    return total
