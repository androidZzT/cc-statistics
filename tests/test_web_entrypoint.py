from __future__ import annotations

import json

from cc_stats_web.__main__ import _build_startup_payload, _parse_args


def test_build_startup_payload_returns_desktop_contract() -> None:
    payload = _build_startup_payload(host="127.0.0.1", port=61234)

    assert payload == {
        "event": "cc_stats_web_started",
        "host": "127.0.0.1",
        "port": 61234,
        "url": "http://127.0.0.1:61234/",
    }
    json.dumps(payload)


def test_parse_args_supports_desktop_shell_flags() -> None:
    args = _parse_args(["--no-browser", "--json"])

    assert args.no_browser is True
    assert args.json is True
