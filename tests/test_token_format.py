from __future__ import annotations

from unittest.mock import patch

from cc_stats.formatter import _fmt_tokens as format_cli_tokens
from cc_stats.notifier import notify_session_complete
from cc_stats.webhook import _fmt_tokens as format_webhook_tokens


def test_formatter_supports_billions() -> None:
    assert format_cli_tokens(999) == "999"
    assert format_cli_tokens(1_200) == "1.2K"
    assert format_cli_tokens(12_300_000) == "12.3M"
    assert format_cli_tokens(1_234_000_000) == "1.2B"


def test_webhook_supports_billions() -> None:
    assert format_webhook_tokens(1_234_000_000) == "1.2B"


@patch("cc_stats.notifier.send_notification", return_value=True)
def test_session_complete_notification_supports_billions(mock_send) -> None:
    result = notify_session_complete(
        duration_seconds=120,
        tokens=1_234_000_000,
        cost=12.34,
        project="cc-statistics",
    )

    assert result is True
    mock_send.assert_called_once()
    _, body = mock_send.call_args[0][:2]
    assert "1.2B tokens" in body
