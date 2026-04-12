"""缓存命中率分析的单元测试"""

import os
import pytest

from cc_stats.analyzer import (
    CacheStats,
    TokenUsage,
    compute_cache_stats,
)
from cc_stats.formatter import format_cache_stats


# ── compute_cache_stats 测试 ──────────────────────────────


class TestComputeCacheStats:
    """compute_cache_stats() 核心逻辑测试"""

    def test_no_cache_tokens_returns_na(self):
        """cache_read = 0 → grade = na"""
        tu = TokenUsage(input_tokens=1000, output_tokens=500)
        result = compute_cache_stats(tu, {})
        assert result.grade == "na"
        assert result.grade_label == "N/A"
        assert result.hit_rate == 0.0
        assert result.savings_usd == 0.0

    def test_excellent_grade(self):
        """命中率 >= 80% → excellent"""
        tu = TokenUsage(input_tokens=200, cache_read_input_tokens=800)
        result = compute_cache_stats(tu, {"claude-sonnet-4-6-20250514": tu})
        assert result.grade == "excellent"
        assert result.grade_label == "Excellent"
        assert result.hit_rate == 0.8

    def test_good_grade(self):
        """命中率 >= 60% → good"""
        tu = TokenUsage(input_tokens=400, cache_read_input_tokens=600)
        result = compute_cache_stats(tu, {"claude-sonnet-4-6-20250514": tu})
        assert result.grade == "good"
        assert result.grade_label == "Good"
        assert result.hit_rate == 0.6

    def test_fair_grade(self):
        """命中率 >= 40% → fair"""
        tu = TokenUsage(input_tokens=600, cache_read_input_tokens=400)
        result = compute_cache_stats(tu, {"claude-sonnet-4-6-20250514": tu})
        assert result.grade == "fair"
        assert result.grade_label == "Fair"
        assert result.hit_rate == 0.4

    def test_poor_grade(self):
        """命中率 < 40% → poor"""
        tu = TokenUsage(input_tokens=800, cache_read_input_tokens=200)
        result = compute_cache_stats(tu, {"claude-sonnet-4-6-20250514": tu})
        assert result.grade == "poor"
        assert result.grade_label == "Poor"
        assert result.hit_rate == 0.2

    def test_hit_rate_calculation(self):
        """hit_rate = cache_read / (input + cache_read)"""
        tu = TokenUsage(input_tokens=300_000, cache_read_input_tokens=700_000)
        result = compute_cache_stats(tu, {"claude-sonnet-4-6-20250514": tu})
        assert result.hit_rate == pytest.approx(0.7)
        assert result.total_input_tokens == 1_000_000
        assert result.cache_read_tokens == 700_000

    def test_savings_usd_calculation(self):
        """节省费用 = cache_read * (input_price - cache_read_price) / 1M"""
        tu = TokenUsage(input_tokens=200_000, cache_read_input_tokens=1_000_000)
        result = compute_cache_stats(tu, {"claude-sonnet-4-6-20250514": tu})
        # savings = 1_000_000 * (3.0 - 0.3) / 1_000_000 = $2.70
        assert result.savings_usd == pytest.approx(2.70)

    def test_gemini_model_no_savings(self):
        """Gemini 模型不计算节省费用"""
        tu = TokenUsage(input_tokens=200, cache_read_input_tokens=800)
        result = compute_cache_stats(tu, {"gemini-2.5-pro": tu})
        assert result.savings_usd == 0.0
        # 但命中率仍然计算
        assert result.hit_rate == 0.8
        assert result.grade == "excellent"

    def test_mixed_models_savings(self):
        """混合模型：只对 Claude 模型计算节省费用"""
        claude_tu = TokenUsage(input_tokens=100, cache_read_input_tokens=500)
        gemini_tu = TokenUsage(input_tokens=100, cache_read_input_tokens=500)
        total_tu = TokenUsage(input_tokens=200, cache_read_input_tokens=1000)

        by_model = {
            "claude-sonnet-4-6-20250514": claude_tu,
            "gemini-2.5-pro": gemini_tu,
        }
        result = compute_cache_stats(total_tu, by_model)
        # 只算 claude 的 500 tokens
        expected = 500 * (3.0 - 0.3) / 1_000_000
        assert result.savings_usd == pytest.approx(expected)

    def test_by_model_hit_rates(self):
        """按模型拆分命中率"""
        model_a = TokenUsage(input_tokens=200, cache_read_input_tokens=800)
        model_b = TokenUsage(input_tokens=500, cache_read_input_tokens=500)
        total_tu = TokenUsage(input_tokens=700, cache_read_input_tokens=1300)

        by_model = {"model-a": model_a, "model-b": model_b}
        result = compute_cache_stats(total_tu, by_model)

        assert result.by_model["model-a"] == pytest.approx(0.8)
        assert result.by_model["model-b"] == pytest.approx(0.5)

    def test_by_model_excludes_zero_cache(self):
        """by_model 不包含 cache_read = 0 的模型"""
        model_a = TokenUsage(input_tokens=200, cache_read_input_tokens=800)
        model_b = TokenUsage(input_tokens=500, cache_read_input_tokens=0)
        total_tu = TokenUsage(input_tokens=700, cache_read_input_tokens=800)

        by_model = {"model-a": model_a, "model-b": model_b}
        result = compute_cache_stats(total_tu, by_model)

        assert "model-a" in result.by_model
        assert "model-b" not in result.by_model

    def test_boundary_80_percent(self):
        """边界：刚好 80% → excellent"""
        tu = TokenUsage(input_tokens=200, cache_read_input_tokens=800)
        result = compute_cache_stats(tu, {})
        assert result.grade == "excellent"

    def test_boundary_just_below_80(self):
        """边界：略低于 80% → good"""
        tu = TokenUsage(input_tokens=201, cache_read_input_tokens=799)
        result = compute_cache_stats(tu, {})
        assert result.grade == "good"

    def test_boundary_60_percent(self):
        """边界：刚好 60% → good"""
        tu = TokenUsage(input_tokens=400, cache_read_input_tokens=600)
        result = compute_cache_stats(tu, {})
        assert result.grade == "good"

    def test_boundary_40_percent(self):
        """边界：刚好 40% → fair"""
        tu = TokenUsage(input_tokens=600, cache_read_input_tokens=400)
        result = compute_cache_stats(tu, {})
        assert result.grade == "fair"


# ── format_cache_stats 测试 ───────────────────────────────


class TestFormatCacheStats:
    """format_cache_stats() 输出格式测试"""

    @pytest.fixture(autouse=True)
    def disable_color(self, monkeypatch):
        monkeypatch.setenv("NO_COLOR", "1")
        # 重新加载模块以更新 _COLOR
        import cc_stats.formatter as fmt
        fmt._COLOR = False

    def test_na_output(self):
        """N/A 等级输出"""
        cache = CacheStats()
        output = format_cache_stats(cache)
        assert "N/A" in output
        assert "No cache data available" in output

    def test_excellent_output(self):
        """Excellent 等级输出"""
        cache = CacheStats(
            hit_rate=0.85,
            grade="excellent",
            grade_label="Excellent",
            cache_read_tokens=850_000,
            total_input_tokens=1_000_000,
            savings_usd=2.30,
        )
        output = format_cache_stats(cache)
        assert "Excellent" in output
        assert "85.0%" in output
        assert "well-cached" in output
        assert "$2.30" in output

    def test_poor_output(self):
        """Poor 等级输出"""
        cache = CacheStats(
            hit_rate=0.2,
            grade="poor",
            grade_label="Poor",
            cache_read_tokens=200_000,
            total_input_tokens=1_000_000,
            savings_usd=0.54,
        )
        output = format_cache_stats(cache)
        assert "Poor" in output
        assert "20.0%" in output
        assert "Low cache hit rate" in output

    def test_multi_model_output(self):
        """多模型时显示按模型拆分"""
        cache = CacheStats(
            hit_rate=0.7,
            grade="good",
            grade_label="Good",
            cache_read_tokens=700_000,
            total_input_tokens=1_000_000,
            savings_usd=1.89,
            by_model={"claude-sonnet": 0.85, "claude-haiku": 0.55},
        )
        output = format_cache_stats(cache)
        assert "按模型" in output
        assert "claude-sonnet" in output
        assert "85.0%" in output
        assert "claude-haiku" in output
        assert "55.0%" in output

    def test_single_model_no_breakdown(self):
        """单模型不显示按模型拆分"""
        cache = CacheStats(
            hit_rate=0.9,
            grade="excellent",
            grade_label="Excellent",
            cache_read_tokens=900_000,
            total_input_tokens=1_000_000,
            savings_usd=2.43,
            by_model={"claude-sonnet": 0.9},
        )
        output = format_cache_stats(cache)
        assert "按模型" not in output

    def test_zero_savings_not_shown(self):
        """savings = 0 时不显示节省费用"""
        cache = CacheStats(
            hit_rate=0.8,
            grade="excellent",
            grade_label="Excellent",
            cache_read_tokens=800,
            total_input_tokens=1000,
            savings_usd=0.0,
        )
        output = format_cache_stats(cache)
        assert "节省费用" not in output
