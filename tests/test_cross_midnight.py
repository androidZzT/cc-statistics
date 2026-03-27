"""跨日 session 按消息时间戳归日的单元测试 (Issue #15)"""

from __future__ import annotations

from datetime import datetime, timezone

from pathlib import Path

import pytest

from cc_stats.analyzer import (
    SessionStats,
    TokenUsage,
    analyze_session,
    merge_stats,
)
from cc_stats.parser import Message, Session, ToolCall


def _make_session(messages: list[Message]) -> Session:
    return Session(
        session_id="cross-midnight-session",
        project_path="/tmp/test-project",
        file_path=Path("/tmp/test.jsonl"),
        messages=messages,
    )


def _ts(year: int, month: int, day: int, hour: int, minute: int = 0) -> str:
    """生成 UTC ISO 格式时间戳"""
    return f"{year}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:00+00:00"


def _assistant_msg_with_usage(
    ts: str,
    input_tokens: int = 100,
    output_tokens: int = 50,
    model: str = "claude-sonnet-4-20250514",
) -> Message:
    """创建带 token usage 的 assistant 消息"""
    return Message(
        role="assistant",
        timestamp=ts,
        content="response",
        model=model,
        usage={
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 0,
        },
    )


class TestTokenByDate:
    """测试 token_by_date 按消息时间戳归日"""

    def test_single_day_session(self):
        """单日 session，所有 token 归到同一天"""
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 15, 10), content="hello"),
            _assistant_msg_with_usage(_ts(2026, 3, 15, 10, 1), input_tokens=200, output_tokens=100),
            Message(role="user", timestamp=_ts(2026, 3, 15, 11), content="continue"),
            _assistant_msg_with_usage(_ts(2026, 3, 15, 11, 1), input_tokens=300, output_tokens=150),
        ])
        stats = analyze_session(session)

        # token_usage 总量不变（向后兼容）
        assert stats.token_usage.input_tokens == 500
        assert stats.token_usage.output_tokens == 250

        # token_by_date 只有一个日期
        assert len(stats.token_by_date) == 1
        # 注意：key 是本地日期，取决于时区。UTC 10:00 在 UTC+8 是 18:00 同一天
        # 所以我们只验证总量
        total_by_date = sum(tu.input_tokens for tu in stats.token_by_date.values())
        assert total_by_date == 500

    def test_cross_midnight_session(self):
        """跨午夜 session，token 分配到两个不同日期

        使用间隔足够大的 UTC 时间（跨越 24h），确保无论本地时区
        是什么，两条 assistant 消息都落在不同的本地自然日。
        """
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 15, 3), content="start"),
            _assistant_msg_with_usage(_ts(2026, 3, 15, 4), input_tokens=200, output_tokens=100),
            Message(role="user", timestamp=_ts(2026, 3, 16, 14), content="next day"),
            _assistant_msg_with_usage(_ts(2026, 3, 16, 15), input_tokens=300, output_tokens=150),
        ])
        stats = analyze_session(session)

        # token_usage 总量保持不变（向后兼容）
        assert stats.token_usage.input_tokens == 500
        assert stats.token_usage.output_tokens == 250

        # token_by_date 应该有两个日期
        assert len(stats.token_by_date) == 2

        # 两个日期的 token 总和等于 token_usage
        total_input = sum(tu.input_tokens for tu in stats.token_by_date.values())
        total_output = sum(tu.output_tokens for tu in stats.token_by_date.values())
        assert total_input == 500
        assert total_output == 250

    def test_cross_midnight_correct_date_assignment(self):
        """验证 token 归属到正确的本地日期

        使用 UTC 时间构造跨日场景，验证 token_by_date 的 key
        包含正确的两个日期。
        """
        # 使用差距足够大的时间确保无论什么时区都跨日
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 15, 2), content="early morning"),
            _assistant_msg_with_usage(_ts(2026, 3, 15, 3), input_tokens=100, output_tokens=50),
            Message(role="user", timestamp=_ts(2026, 3, 16, 14), content="afternoon next day"),
            _assistant_msg_with_usage(_ts(2026, 3, 16, 15), input_tokens=200, output_tokens=80),
        ])
        stats = analyze_session(session)

        # 无论本地时区如何，两条 assistant 消息的本地日期应该不同
        assert len(stats.token_by_date) == 2

        # 获取两个日期的 token
        dates = sorted(stats.token_by_date.keys())
        day1_tokens = stats.token_by_date[dates[0]]
        day2_tokens = stats.token_by_date[dates[1]]

        assert day1_tokens.input_tokens == 100
        assert day1_tokens.output_tokens == 50
        assert day2_tokens.input_tokens == 200
        assert day2_tokens.output_tokens == 80

    def test_three_day_session(self):
        """跨三天的 session"""
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 14, 3), content="day 1"),
            _assistant_msg_with_usage(_ts(2026, 3, 14, 4), input_tokens=100, output_tokens=50),
            Message(role="user", timestamp=_ts(2026, 3, 15, 14), content="day 2"),
            _assistant_msg_with_usage(_ts(2026, 3, 15, 15), input_tokens=200, output_tokens=100),
            Message(role="user", timestamp=_ts(2026, 3, 16, 14), content="day 3"),
            _assistant_msg_with_usage(_ts(2026, 3, 16, 15), input_tokens=300, output_tokens=150),
        ])
        stats = analyze_session(session)

        assert len(stats.token_by_date) == 3
        total_input = sum(tu.input_tokens for tu in stats.token_by_date.values())
        assert total_input == 600
        assert stats.token_usage.input_tokens == 600  # 向后兼容

    def test_no_usage_messages(self):
        """无 usage 的消息不影响 token_by_date"""
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 15, 10), content="hello"),
            Message(role="assistant", timestamp=_ts(2026, 3, 15, 10, 1), content="hi"),
        ])
        stats = analyze_session(session)
        assert stats.token_by_date == {}
        assert stats.token_usage.total == 0

    def test_cache_tokens_in_token_by_date(self):
        """cache tokens 也正确归日"""
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 15, 3), content="q1"),
            Message(
                role="assistant",
                timestamp=_ts(2026, 3, 15, 4),
                content="a1",
                model="claude-sonnet-4-20250514",
                usage={
                    "input_tokens": 100,
                    "output_tokens": 50,
                    "cache_read_input_tokens": 500,
                    "cache_creation_input_tokens": 200,
                },
            ),
        ])
        stats = analyze_session(session)
        assert len(stats.token_by_date) == 1
        date_key = list(stats.token_by_date.keys())[0]
        tu = stats.token_by_date[date_key]
        assert tu.cache_read_input_tokens == 500
        assert tu.cache_creation_input_tokens == 200


class TestTokenByDateMerge:
    """测试 merge_stats 对 token_by_date 的合并"""

    def test_merge_token_by_date(self):
        """合并两个会话的 token_by_date"""
        s1 = SessionStats(session_id="s1", project_path="/tmp")
        s1.token_by_date["2026-03-15"] = TokenUsage(
            input_tokens=100, output_tokens=50,
        )

        s2 = SessionStats(session_id="s2", project_path="/tmp")
        s2.token_by_date["2026-03-15"] = TokenUsage(
            input_tokens=200, output_tokens=80,
        )
        s2.token_by_date["2026-03-16"] = TokenUsage(
            input_tokens=300, output_tokens=120,
        )

        merged = merge_stats([s1, s2])

        assert "2026-03-15" in merged.token_by_date
        assert "2026-03-16" in merged.token_by_date
        assert merged.token_by_date["2026-03-15"].input_tokens == 300
        assert merged.token_by_date["2026-03-15"].output_tokens == 130
        assert merged.token_by_date["2026-03-16"].input_tokens == 300
        assert merged.token_by_date["2026-03-16"].output_tokens == 120

    def test_merge_empty_token_by_date(self):
        """合并时空 token_by_date 不影响结果"""
        s1 = SessionStats(session_id="s1", project_path="/tmp")
        s2 = SessionStats(session_id="s2", project_path="/tmp")
        s2.token_by_date["2026-03-15"] = TokenUsage(input_tokens=100)

        merged = merge_stats([s1, s2])
        assert merged.token_by_date["2026-03-15"].input_tokens == 100


class TestBackwardCompatibility:
    """确保 token_usage 向后兼容"""

    def test_token_usage_unchanged(self):
        """token_usage 不受 token_by_date 影响，保持完整总量"""
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 15, 23), content="start"),
            _assistant_msg_with_usage(_ts(2026, 3, 15, 23, 30), input_tokens=100, output_tokens=50),
            Message(role="user", timestamp=_ts(2026, 3, 16, 1), content="continue"),
            _assistant_msg_with_usage(_ts(2026, 3, 16, 1, 30), input_tokens=200, output_tokens=80),
        ])
        stats = analyze_session(session)

        # token_usage 是全量总和，与以前行为一致
        assert stats.token_usage.input_tokens == 300
        assert stats.token_usage.output_tokens == 130
        assert stats.token_usage.total == 430

        # token_by_date 各日之和也等于总量
        by_date_total = sum(tu.total for tu in stats.token_by_date.values())
        assert by_date_total == 430

    def test_token_by_model_unchanged(self):
        """token_by_model 不受影响"""
        session = _make_session([
            Message(role="user", timestamp=_ts(2026, 3, 15, 10), content="q"),
            _assistant_msg_with_usage(
                _ts(2026, 3, 15, 10, 1),
                input_tokens=100, output_tokens=50,
                model="claude-sonnet-4-20250514",
            ),
        ])
        stats = analyze_session(session)
        assert "claude-sonnet-4-20250514" in stats.token_by_model
        assert stats.token_by_model["claude-sonnet-4-20250514"].input_tokens == 100
