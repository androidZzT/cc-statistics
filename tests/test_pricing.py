from cc_stats.pricing import is_claude_model, match_model_pricing


def test_match_gpt_55():
    p = match_model_pricing("gpt-5.5")
    assert p["input"] == 5.0
    assert p["output"] == 30.0
    assert p["cache_read"] == 0.5


def test_match_gpt_55_pro():
    p = match_model_pricing("gpt-5.5-pro")
    assert p["input"] == 30.0
    assert p["output"] == 180.0


def test_match_gpt_53_codex_exact():
    p = match_model_pricing("gpt-5.3-codex")
    assert p["input"] == 1.75
    assert p["output"] == 14.0
    assert p["cache_read"] == 0.175


def test_match_chat_latest():
    p = match_model_pricing("gpt-5.3-chat-latest")
    assert p["input"] == 5.0
    assert p["output"] == 30.0
    assert p["cache_read"] == 0.5


def test_match_gpt5_codex_fallback():
    p = match_model_pricing("gpt-5.2-codex")
    assert p["input"] == 1.75
    assert p["output"] == 14.0


def test_match_claude_fable_5():
    p = match_model_pricing("claude-fable-5-20260601")
    assert p["input"] == 10.0
    assert p["output"] == 50.0
    assert p["cache_read"] == 1.0


def test_match_claude_opus_48():
    p = match_model_pricing("claude-opus-4-8-20260528")
    assert p["input"] == 5.0
    assert p["output"] == 25.0


def test_match_claude_opus_46():
    p = match_model_pricing("claude-opus-4-6-20260101")
    assert p["input"] == 5.0
    assert p["output"] == 25.0


def test_match_claude_sonnet_4():
    p = match_model_pricing("claude-sonnet-4-20250514")
    assert p["input"] == 3.0
    assert p["output"] == 15.0


def test_match_gemini_25_flash():
    p = match_model_pricing("gemini-2.5-flash")
    assert p["input"] == 0.3
    assert p["output"] == 2.5
    assert p["cache_read"] == 0.03


def test_match_gemini_35_flash():
    p = match_model_pricing("gemini-3.5-flash")
    assert p["input"] == 1.5
    assert p["output"] == 9.0
    assert p["cache_read"] == 0.15


def test_match_gemini_31_pro_preview():
    p = match_model_pricing("gemini-3.1-pro-preview")
    assert p["input"] == 2.0
    assert p["output"] == 12.0
    assert p["cache_read"] == 0.2


def test_is_claude_model():
    assert is_claude_model("claude-sonnet-4-6")
    assert is_claude_model("sonnet")
    assert is_claude_model("fable")
    assert not is_claude_model("gpt-5.3-codex")
