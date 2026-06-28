from __future__ import annotations

from pathlib import Path


DASHBOARD_HTML = Path(__file__).resolve().parents[1] / "cc_stats_web" / "web" / "index.html"


def test_dashboard_markup_exposes_compact_tray_layout_sections() -> None:
    html = DASHBOARD_HTML.read_text(encoding="utf-8")

    required_fragments = [
        'class="dashboard-shell"',
        'class="top-toolbar"',
        'class="period-tabs"',
        'data-period="today">今天',
        'data-period="week">本周',
        'data-period="month">本月',
        'data-period="all">全部',
        'id="token-card"',
        'id="cache-section"',
        'id="trend-card"',
        'data-trend="cost"',
        'data-trend="tokens"',
        'data-trend="sessions"',
        'data-trend="time"',
        'id="forecast-card"',
        'id="dashboard-footer"',
        'id="refresh-button"',
    ]

    for fragment in required_fragments:
        assert fragment in html
