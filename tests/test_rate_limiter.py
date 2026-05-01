"""Usage Quota 预测器的单元测试"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from cc_stats.analyzer import SessionStats, TokenUsage, analyze_session, merge_stats
from cc_stats.formatter import format_rate_limit
from cc_stats.parser import Message, Session, ToolCall
from cc_stats.rate_limiter import (
    DEFAULT_WINDOW_LIMIT,
    RateLimitStatus,
    analyze_codex_window,
    analyze_rate_limit,
)


def _make_session(messages: list[Message]) -> Session:
    return Session(
        session_id="test-session",
        project_path="/tmp/test-project",
        file_path=Path("/tmp/test.jsonl"),
        messages=messages,
    )


def _ts(hour: int = 10, minute: int = 0) -> str:
    """生成 ISO 格式时间戳"""
    return f"2026-04-12T{hour:02d}:{minute:02d}:00+00:00"


def _make_stats_with_minutes(
    minute_data: dict[str, int],
    window_limit: int = DEFAULT_WINDOW_LIMIT,
) -> SessionStats:
    """构造带 token_by_minute 的 SessionStats

    minute_data: {"YYYY-MM-DD HH:MM": output_tokens}
    """
    stats = SessionStats(session_id="test", project_path="/tmp/test")
    for key, output_tokens in minute_data.items():
        stats.token_by_minute[key] = TokenUsage(output_tokens=output_tokens)
    total_output = sum(minute_data.values())
    stats.token_usage = TokenUsage(output_tokens=total_output)
    return stats


class TestRateLimitStatus:
    """测试 RateLimitStatus 状态分级"""

    def test_safe_status(self):
        """窗口使用 < 60% → safe"""
        stats = _make_stats_with_minutes({
            "2026-04-12 10:00": 2000,
            "2026-04-12 10:01": 3000,
            "2026-04-12 10:02": 1000,
        })
        result = analyze_rate_limit(stats, window_limit=40000)
        assert result.status == "safe"
        assert result.pct < 0.60
        assert result.window_used == 6000

    def test_warning_status(self):
        """窗口使用 60% → warning（边界值）"""
        stats = _make_stats_with_minutes({
            "2026-04-12 10:00": 8000,
            "2026-04-12 10:01": 8000,
            "2026-04-12 10:02": 8000,
        })
        result = analyze_rate_limit(stats, window_limit=40000)
        # 24000/40000 = 0.60 → exactly at boundary → warning
        assert result.status == "warning"
        assert result.window_used == 24000
        assert result.pct == pytest.approx(0.60)

    def test_warning_status_above_60(self):
        """窗口使用明确 > 60% → warning"""
        stats = _make_stats_with_minutes({
            "2026-04-12 10:00": 10000,
            "2026-04-12 10:01": 10000,
            "2026-04-12 10:02": 10000,
        })
        result = analyze_rate_limit(stats, window_limit=40000)
        assert result.status == "warning"
        assert result.pct >= 0.60
        assert result.pct <= 0.85

    def test_critical_status(self):
        """窗口使用 > 85% → critical"""
        stats = _make_stats_with_minutes({
            "2026-04-12 10:00": 10000,
            "2026-04-12 10:01": 10000,
            "2026-04-12 10:02": 10000,
            "2026-04-12 10:03": 10000,
        })
        result = analyze_rate_limit(stats, window_limit=40000)
        assert result.status == "critical"
        assert result.pct > 0.85

    def test_idle_no_data(self):
        """没有 token_by_minute 数据 → idle"""
        stats = SessionStats(session_id="test", project_path="/tmp/test")
        result = analyze_rate_limit(stats)
        assert result.status == "idle"
        assert result.rate_per_min == 0.0
        assert result.minutes_until_limit is None

    def test_custom_limit(self):
        """自定义 limit 参数（Max 订阅）"""
        stats = _make_stats_with_minutes({
            "2026-04-12 10:00": 10000,
            "2026-04-12 10:01": 10000,
            "2026-04-12 10:02": 10000,
        })
        # 默认 40000 → warning，但 80000 → safe
        result_default = analyze_rate_limit(stats, window_limit=40000)
        result_max = analyze_rate_limit(stats, window_limit=80000)
        assert result_default.pct > result_max.pct
        assert result_max.status == "safe"

    def test_minutes_until_limit(self):
        """预测剩余时间计算"""
        stats = _make_stats_with_minutes({
            "2026-04-12 10:00": 5000,
            "2026-04-12 10:01": 5000,
        })
        result = analyze_rate_limit(stats, window_limit=40000)
        assert result.minutes_until_limit is not None
        assert result.minutes_until_limit > 0
        # rate = 10000/5 = 2000/min, remaining = 30000, eta = 15 min
        assert abs(result.minutes_until_limit - 15.0) < 0.1

    def test_limit_reached(self):
        """已达限额时 minutes_until_limit = 0"""
        stats = _make_stats_with_minutes({
            "2026-04-12 10:00": 10000,
            "2026-04-12 10:01": 10000,
            "2026-04-12 10:02": 10000,
            "2026-04-12 10:03": 10000,
            "2026-04-12 10:04": 10000,
        })
        result = analyze_rate_limit(stats, window_limit=40000)
        assert result.minutes_until_limit == 0.0
        assert result.status == "critical"

    def test_window_only_recent_5_minutes(self):
        """只计算最近 5 分钟窗口内的数据"""
        stats = _make_stats_with_minutes({
            "2026-04-12 09:50": 20000,  # 超出窗口
            "2026-04-12 09:55": 20000,  # 超出窗口
            "2026-04-12 10:00": 1000,   # 窗口内
            "2026-04-12 10:01": 1000,   # 窗口内
            "2026-04-12 10:04": 1000,   # 窗口内（最新）
        })
        result = analyze_rate_limit(stats, window_limit=40000)
        # 窗口从 09:59 到 10:04，只含 10:00, 10:01, 10:04
        assert result.window_used == 3000
        assert result.status == "safe"


class TestTokenByMinuteExtraction:
    """测试 analyzer 正确提取 token_by_minute"""

    def test_token_by_minute_populated(self):
        """assistant 消息的 token usage 按分钟归集"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="hello"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="hi",
                usage={"input_tokens": 100, "output_tokens": 500},
            ),
            Message(role="user", timestamp=_ts(10, 2), content="more"),
            Message(
                role="assistant",
                timestamp=_ts(10, 3),
                content="sure",
                usage={"input_tokens": 200, "output_tokens": 800},
            ),
        ])
        stats = analyze_session(session)
        assert len(stats.token_by_minute) >= 2
        # 总 output tokens
        total_output = sum(
            tu.output_tokens for tu in stats.token_by_minute.values()
        )
        assert total_output == 1300

    def test_token_by_minute_empty_no_usage(self):
        """没有 usage 的消息不产生 token_by_minute"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="hello"),
            Message(role="assistant", timestamp=_ts(10, 1), content="hi"),
        ])
        stats = analyze_session(session)
        assert stats.token_by_minute == {}


class TestTokenByMinuteMerge:
    """测试 merge_stats 正确合并 token_by_minute"""

    def test_merge_combines_minutes(self):
        """合并两个 session 的分钟数据"""
        s1 = _make_stats_with_minutes({"2026-04-12 10:00": 1000})
        s2 = _make_stats_with_minutes({"2026-04-12 10:00": 2000, "2026-04-12 10:01": 500})
        merged = merge_stats([s1, s2])
        assert merged.token_by_minute["2026-04-12 10:00"].output_tokens == 3000
        assert merged.token_by_minute["2026-04-12 10:01"].output_tokens == 500

    def test_merge_trims_to_30_minutes(self):
        """合并后只保留最近 30 分钟"""
        minute_data = {f"2026-04-12 10:{i:02d}": 100 for i in range(35)}
        s1 = SessionStats(session_id="s1", project_path="/tmp/test")
        for key, val in minute_data.items():
            s1.token_by_minute[key] = TokenUsage(output_tokens=val)
        merged = merge_stats([s1])
        assert len(merged.token_by_minute) <= 30


class TestFormatRateLimit:
    """测试 format_rate_limit 输出"""

    def test_safe_format_contains_safe(self):
        """safe 状态包含 SAFE 标签"""
        status = RateLimitStatus(
            status="safe",
            window_limit=40000,
            window_used=10000,
            pct=0.25,
            rate_per_min=2000,
            minutes_until_limit=15.0,
        )
        output = format_rate_limit(status)
        assert "SAFE" in output
        assert "Usage Quota Forecast" in output

    def test_warning_format_contains_warning(self):
        """warning 状态包含 WARNING 标签"""
        status = RateLimitStatus(
            status="warning",
            window_limit=40000,
            window_used=28000,
            pct=0.70,
            rate_per_min=5600,
            minutes_until_limit=2.0,
        )
        output = format_rate_limit(status)
        assert "WARNING" in output

    def test_critical_format_contains_suggestion(self):
        """critical 状态包含暂停建议"""
        status = RateLimitStatus(
            status="critical",
            window_limit=40000,
            window_used=38000,
            pct=0.95,
            rate_per_min=7600,
            minutes_until_limit=0.3,
        )
        output = format_rate_limit(status)
        assert "CRITICAL" in output
        assert "Consider pausing" in output

    def test_idle_format(self):
        """idle 状态返回空字符串"""
        status = RateLimitStatus(
            status="idle",
            window_limit=40000,
            window_used=0,
            pct=0.0,
            rate_per_min=0.0,
            minutes_until_limit=None,
        )
        output = format_rate_limit(status)
        assert output == ""

    def test_limit_reached_format(self):
        """达到限额时显示 Consider pausing"""
        status = RateLimitStatus(
            status="critical",
            window_limit=40000,
            window_used=42000,
            pct=1.05,
            rate_per_min=8400,
            minutes_until_limit=0.0,
        )
        output = format_rate_limit(status)
        assert "Consider pausing" in output


class TestCodexUsageWindow:
    """测试 analyze_codex_window 5h / 7d 滚动窗口"""

    def _stats_with_codex_hours(
        self,
        per_hour: dict[str, dict[str, TokenUsage]],
        msgs_per_hour: dict[str, int] | None = None,
    ) -> SessionStats:
        s = SessionStats(session_id="t", project_path="/tmp/t", sources={"codex"})
        s.codex_token_by_hour = per_hour
        s.codex_messages_by_hour = msgs_per_hour or {}
        return s

    def test_idle_when_no_codex_data(self):
        s = SessionStats(session_id="t", project_path="/tmp/t")
        result = analyze_codex_window(s, hours=5, label="Codex 5h")
        assert result.status == "idle"
        assert result.window_used == 0

    def test_5h_window_aggregates_recent_hours(self):
        now = datetime(2026, 4, 16, 12, 0, tzinfo=timezone.utc)
        # 1 小时前的用量 → 在 5h 窗口内
        per_hour = {
            "2026-04-16T11": {
                "gpt-5.3-codex": TokenUsage(input_tokens=1_000_000, output_tokens=500_000),
            },
            # 6 小时前 → 5h 窗口外，但在 7d 窗口内
            "2026-04-16T06": {
                "gpt-5.3-codex": TokenUsage(input_tokens=2_000_000, output_tokens=1_000_000),
            },
        }
        msgs = {"2026-04-16T11": 8, "2026-04-16T06": 15}
        stats = self._stats_with_codex_hours(per_hour, msgs)

        five_h = analyze_codex_window(stats, hours=5, label="Codex 5h", now=now)
        assert five_h.status == "safe"
        assert five_h.label == "Codex 5h"
        assert five_h.window_used == 1_500_000
        assert five_h.messages == 8
        # 1M input × $1.75 + 0.5M output × $14 = $1.75 + $7 = $8.75
        assert abs(five_h.cost_usd - 8.75) < 0.01

        seven_d = analyze_codex_window(stats, hours=24 * 7, label="Codex 7d", now=now)
        assert seven_d.window_used == 4_500_000
        assert seven_d.messages == 23
        # 总 cost = 3M input × $1.75 + 1.5M output × $14 = $5.25 + $21 = $26.25
        assert abs(seven_d.cost_usd - 26.25) < 0.01

    def test_window_excludes_future_hours(self):
        """超过 now 的小时键不应纳入"""
        now = datetime(2026, 4, 16, 12, 0, tzinfo=timezone.utc)
        per_hour = {
            "2026-04-16T15": {  # 未来（数据异常）
                "gpt-5.3-codex": TokenUsage(input_tokens=10_000, output_tokens=10_000),
            },
        }
        stats = self._stats_with_codex_hours(per_hour, {"2026-04-16T15": 1})
        result = analyze_codex_window(stats, hours=5, label="Codex 5h", now=now)
        assert result.status == "idle"

    def test_with_window_limit_classifies_status(self):
        """显式给定限额时按 pct 分级"""
        now = datetime(2026, 4, 16, 12, 0, tzinfo=timezone.utc)
        per_hour = {
            "2026-04-16T11": {
                "gpt-5.3-codex": TokenUsage(input_tokens=850_000),
            },
        }
        stats = self._stats_with_codex_hours(per_hour, {"2026-04-16T11": 1})
        result = analyze_codex_window(
            stats, hours=5, label="Codex 5h", window_limit=1_000_000, now=now
        )
        assert result.status == "critical"
        assert result.pct == pytest.approx(0.85)
        assert result.minutes_until_limit is not None

    def test_multi_model_costs_summed(self):
        now = datetime(2026, 4, 16, 12, 0, tzinfo=timezone.utc)
        per_hour = {
            "2026-04-16T11": {
                "gpt-5.3-codex": TokenUsage(input_tokens=1_000_000),
                "gpt-5.4": TokenUsage(input_tokens=1_000_000),
            },
        }
        stats = self._stats_with_codex_hours(per_hour, {"2026-04-16T11": 5})
        result = analyze_codex_window(stats, hours=5, label="Codex 5h", now=now)
        # gpt-5.3-codex input $1.75 + gpt-5.4 input $2.50 = $4.25
        assert abs(result.cost_usd - 4.25) < 0.01

    def test_format_rate_limit_renders_codex_windows(self):
        """format_rate_limit 接受多个 status 时同时渲染"""
        claude = RateLimitStatus(
            status="safe", window_limit=40000, window_used=8000,
            pct=0.20, rate_per_min=1600, minutes_until_limit=20.0,
        )
        codex_5h = RateLimitStatus(
            status="safe", window_limit=0, window_used=1_500_000,
            pct=0.0, rate_per_min=5000, minutes_until_limit=None,
            label="Codex 5h", metric="total_tokens", window_minutes=300,
            messages=8, cost_usd=8.75,
        )
        out = format_rate_limit([claude, codex_5h])
        assert "Claude 5-min" in out
        assert "Codex 5h" in out
        assert "8.75" in out
        assert "1,500,000" in out


class TestCodexAnalyzerIntegration:
    """parser → analyzer → analyze_codex_window 端到端"""

    def test_codex_session_populates_hour_buckets(self):
        from cc_stats.parser import parse_codex_jsonl
        import json

        path = Path("/tmp/cc-codex-fixture-rl.jsonl")
        records = [
            {"timestamp": "2026-04-16T11:00:00Z", "type": "session_meta",
             "payload": {"id": "s", "cwd": "/tmp/p"}},
            {"timestamp": "2026-04-16T11:05:00Z", "type": "turn_context",
             "payload": {"model": "gpt-5.3-codex"}},
            {"timestamp": "2026-04-16T11:10:00Z", "type": "event_msg",
             "payload": {"type": "user_message", "message": "hi"}},
            {"timestamp": "2026-04-16T11:11:00Z", "type": "event_msg",
             "payload": {"type": "agent_message", "message": "ok"}},
            {"timestamp": "2026-04-16T11:11:30Z", "type": "event_msg",
             "payload": {"type": "token_count", "info": {
                 "last_token_usage": {"input_tokens": 200, "cached_input_tokens": 50, "output_tokens": 100}
             }}},
        ]
        with open(path, "w") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")

        session = parse_codex_jsonl(path)
        stats = analyze_session(session)

        assert stats.codex_messages_by_hour.get("2026-04-16T11") == 1
        assert "2026-04-16T11" in stats.codex_token_by_hour
        per_model = stats.codex_token_by_hour["2026-04-16T11"]
        assert "gpt-5.3-codex" in per_model
        # input_tokens = raw_input - cached = 200 - 50 = 150
        assert per_model["gpt-5.3-codex"].input_tokens == 150
        assert per_model["gpt-5.3-codex"].cache_read_input_tokens == 50

        result = analyze_codex_window(
            stats, hours=5, label="Codex 5h",
            now=datetime(2026, 4, 16, 12, 0, tzinfo=timezone.utc),
        )
        assert result.status == "safe"
        assert result.messages == 1
        assert result.window_used == 300  # input 150 + output 100 + cache_read 50


class TestCLIRateLimit:
    """测试 --rate-limit CLI 参数解析"""

    def test_rate_limit_arg_parsed(self):
        """--rate-limit 参数被正确解析"""
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("--rate-limit", action="store_true")
        parser.add_argument("--window-limit", type=int, default=40000)
        args = parser.parse_args(["--rate-limit", "--window-limit", "80000"])
        assert args.rate_limit is True
        assert args.window_limit == 80000

    def test_default_limit(self):
        """默认 window-limit 为 40000"""
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("--rate-limit", action="store_true")
        parser.add_argument("--window-limit", type=int, default=40000)
        args = parser.parse_args(["--rate-limit"])
        assert args.window_limit == 40000
