"""日期过滤精度的单元测试 (Issue #20 Bug 2)

验证：
1. _parse_time_arg 的 as_end_of_day 参数正确补全 23:59:59
2. _trim_stats_by_date_range 正确裁剪 token_by_date 并重算 token_usage
3. 端到端：--since/--until 只统计范围内日期的 token
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from cc_stats.analyzer import SessionStats, TokenUsage
from cc_stats.cli import _parse_time_arg, _trim_stats_by_date_range


# ── _parse_time_arg 测试 ─────────────────────────────────────


class TestParseTimeArg:
    def test_date_only_default_midnight(self):
        """纯日期格式默认解析为 00:00:00"""
        dt = _parse_time_arg("2026-04-03")
        local = dt.astimezone()
        assert local.hour == 0
        assert local.minute == 0
        assert local.second == 0

    def test_date_only_as_end_of_day(self):
        """纯日期格式 + as_end_of_day=True 补全为 23:59:59"""
        dt = _parse_time_arg("2026-04-03", as_end_of_day=True)
        local = dt.astimezone()
        assert local.hour == 23
        assert local.minute == 59
        assert local.second == 59

    def test_datetime_format_ignores_end_of_day(self):
        """带时间的格式不受 as_end_of_day 影响"""
        dt = _parse_time_arg("2026-04-03T10:30", as_end_of_day=True)
        local = dt.astimezone()
        assert local.hour == 10
        assert local.minute == 30

    def test_relative_time_ignores_end_of_day(self):
        """相对时间不受 as_end_of_day 影响"""
        dt1 = _parse_time_arg("1d")
        dt2 = _parse_time_arg("1d", as_end_of_day=True)
        # 两者应该非常接近（几毫秒内）
        assert abs((dt1 - dt2).total_seconds()) < 1

    def test_invalid_format_raises(self):
        """无效格式应抛出异常"""
        with pytest.raises(Exception):
            _parse_time_arg("not-a-date")


# ── _trim_stats_by_date_range 测试 ──────────────────────────


def _make_stats_with_dates(
    date_tokens: dict[str, tuple[int, int, int, int]],
) -> SessionStats:
    """创建带 token_by_date 的 SessionStats

    date_tokens: {"YYYY-MM-DD": (input, output, cache_read, cache_create)}
    """
    stats = SessionStats(session_id="test", project_path="/tmp")
    total = TokenUsage()
    for date_key, (inp, out, cr, cc) in date_tokens.items():
        tu = TokenUsage(
            input_tokens=inp,
            output_tokens=out,
            cache_read_input_tokens=cr,
            cache_creation_input_tokens=cc,
        )
        stats.token_by_date[date_key] = tu
        total.input_tokens += inp
        total.output_tokens += out
        total.cache_read_input_tokens += cr
        total.cache_creation_input_tokens += cc
    stats.token_usage = total
    return stats


class TestTrimStatsByDateRange:
    def test_trim_both_sides(self):
        """同时指定 since 和 until，只保留范围内的日期"""
        stats = _make_stats_with_dates({
            "2026-03-31": (100, 50, 0, 0),
            "2026-04-01": (200, 100, 0, 0),
            "2026-04-02": (300, 150, 0, 0),
            "2026-04-03": (400, 200, 0, 0),
            "2026-04-04": (500, 250, 0, 0),
        })
        _trim_stats_by_date_range(stats, "2026-04-02", "2026-04-03")

        assert set(stats.token_by_date.keys()) == {"2026-04-02", "2026-04-03"}
        assert stats.token_usage.input_tokens == 700  # 300 + 400
        assert stats.token_usage.output_tokens == 350  # 150 + 200
        assert stats.token_usage.total == 1050

    def test_trim_since_only(self):
        """只指定 since，排除早于 since 的日期"""
        stats = _make_stats_with_dates({
            "2026-04-01": (100, 50, 0, 0),
            "2026-04-02": (200, 100, 0, 0),
            "2026-04-03": (300, 150, 0, 0),
        })
        _trim_stats_by_date_range(stats, "2026-04-02", None)

        assert set(stats.token_by_date.keys()) == {"2026-04-02", "2026-04-03"}
        assert stats.token_usage.input_tokens == 500

    def test_trim_until_only(self):
        """只指定 until，排除晚于 until 的日期"""
        stats = _make_stats_with_dates({
            "2026-04-01": (100, 50, 0, 0),
            "2026-04-02": (200, 100, 0, 0),
            "2026-04-03": (300, 150, 0, 0),
        })
        _trim_stats_by_date_range(stats, None, "2026-04-02")

        assert set(stats.token_by_date.keys()) == {"2026-04-01", "2026-04-02"}
        assert stats.token_usage.input_tokens == 300

    def test_no_range_no_change(self):
        """不指定范围时不裁剪"""
        stats = _make_stats_with_dates({
            "2026-04-01": (100, 50, 0, 0),
            "2026-04-02": (200, 100, 0, 0),
        })
        original_total = stats.token_usage.input_tokens
        _trim_stats_by_date_range(stats, None, None)

        assert len(stats.token_by_date) == 2
        assert stats.token_usage.input_tokens == original_total

    def test_empty_token_by_date(self):
        """token_by_date 为空时不报错"""
        stats = SessionStats(session_id="test", project_path="/tmp")
        _trim_stats_by_date_range(stats, "2026-04-02", "2026-04-03")
        assert stats.token_by_date == {}

    def test_all_dates_outside_range(self):
        """所有日期都不在范围内，token 清零"""
        stats = _make_stats_with_dates({
            "2026-03-30": (100, 50, 0, 0),
            "2026-03-31": (200, 100, 0, 0),
        })
        _trim_stats_by_date_range(stats, "2026-04-02", "2026-04-03")

        assert stats.token_by_date == {}
        assert stats.token_usage.total == 0

    def test_cache_tokens_preserved(self):
        """裁剪后 cache token 也正确重算"""
        stats = _make_stats_with_dates({
            "2026-04-01": (100, 50, 1000, 200),
            "2026-04-02": (200, 100, 2000, 400),
            "2026-04-03": (300, 150, 3000, 600),
        })
        _trim_stats_by_date_range(stats, "2026-04-02", "2026-04-02")

        assert stats.token_usage.input_tokens == 200
        assert stats.token_usage.output_tokens == 100
        assert stats.token_usage.cache_read_input_tokens == 2000
        assert stats.token_usage.cache_creation_input_tokens == 400


# ── 端到端场景测试 ──────────────────────────────────────────


class TestDateFilterEndToEnd:
    """模拟 Issue #20 的场景：跨日 session 在日期过滤后应只计入范围内 token"""

    def test_cross_day_session_trimmed(self):
        """一个从 03-31 到 04-04 的 session，过滤 04-02~04-03 只计这两天"""
        stats = _make_stats_with_dates({
            "2026-03-31": (1000, 500, 0, 0),
            "2026-04-01": (2000, 1000, 0, 0),
            "2026-04-02": (3000, 1500, 0, 0),
            "2026-04-03": (4000, 2000, 0, 0),
            "2026-04-04": (5000, 2500, 0, 0),
        })
        # 设置原始时间范围
        stats.start_time = datetime(2026, 3, 31, tzinfo=timezone.utc)
        stats.end_time = datetime(2026, 4, 4, tzinfo=timezone.utc)

        # 裁剪
        _trim_stats_by_date_range(stats, "2026-04-02", "2026-04-03")

        # 只保留 04-02 和 04-03
        assert stats.token_usage.input_tokens == 7000  # 3000 + 4000
        assert stats.token_usage.output_tokens == 3500  # 1500 + 2000
        assert stats.token_usage.total == 10500
