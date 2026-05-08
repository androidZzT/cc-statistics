from cc_stats.analyzer import SessionStats, TokenUsage
from cc_stats_web.server import _stats_to_dict


def test_stats_to_dict_includes_cache_grade_and_claude_only_savings():
    stats = SessionStats(session_id="s1", project_path="/tmp/demo")
    stats.token_usage = TokenUsage(
        input_tokens=300_000,
        output_tokens=50_000,
        cache_read_input_tokens=700_000,
        cache_creation_input_tokens=100_000,
    )
    stats.token_by_model = {
        "claude-sonnet-4.5": TokenUsage(
            input_tokens=100_000,
            cache_read_input_tokens=600_000,
        ),
        "gpt-5.4": TokenUsage(
            input_tokens=200_000,
            cache_read_input_tokens=100_000,
        ),
    }

    result = _stats_to_dict(stats)
    cache = result["cache_stats"]

    assert cache["grade"] == "good"
    assert cache["grade_label"] == "Good"
    assert cache["cache_read_tokens"] == 700_000
    assert cache["total_input_tokens"] == 1_000_000
    assert cache["hit_rate"] == 0.7
    assert cache["savings_usd"] == 1.62
    assert cache["by_model"]["claude-sonnet-4.5"] == 0.8571428571428571
    assert cache["by_model"]["gpt-5.4"] == 0.3333333333333333


def test_stats_to_dict_returns_na_when_no_cache_reads():
    stats = SessionStats(session_id="s2", project_path="/tmp/demo")
    stats.token_usage = TokenUsage(input_tokens=120_000, output_tokens=30_000)
    stats.token_by_model = {
        "claude-sonnet-4.5": TokenUsage(input_tokens=120_000, output_tokens=30_000)
    }

    result = _stats_to_dict(stats)
    cache = result["cache_stats"]

    assert cache["grade"] == "na"
    assert cache["grade_label"] == "N/A"
    assert cache["cache_read_tokens"] == 0
    assert cache["total_input_tokens"] == 0
    assert cache["hit_rate"] == 0.0
    assert cache["savings_usd"] == 0.0
    assert cache["by_model"] == {}
