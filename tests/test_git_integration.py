"""Tests for git_integration module"""

from __future__ import annotations

import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from cc_stats.git_integration import (
    CommitInfo,
    CommitCost,
    GitIntegrationResult,
    _estimate_cost,
    attribute_sessions_to_commits,
    analyze_git_integration,
    parse_git_log,
)


def _dt(offset_hours: int = 0) -> datetime:
    """Helper: UTC datetime offset from epoch"""
    return datetime(2026, 4, 1, 12, 0, 0, tzinfo=timezone.utc) + timedelta(hours=offset_hours)


def _commit(h: str, offset_hours: int, message: str = "test commit") -> CommitInfo:
    return CommitInfo(
        hash=h,
        timestamp=_dt(offset_hours),
        author="Dev",
        message=message,
    )


def _session(start_offset: int, end_offset: int, inp=1000, out=500, cache=200) -> dict:
    return {
        "start_time": _dt(start_offset),
        "end_time": _dt(end_offset),
        "input_tokens": inp,
        "output_tokens": out,
        "cache_read_tokens": cache,
    }


# ── _estimate_cost ────────────────────────────────────────────

class TestEstimateCost:
    def test_zero_tokens(self):
        assert _estimate_cost(0, 0, 0) == 0.0

    def test_input_only(self):
        cost = _estimate_cost(1_000_000, 0, 0)
        assert abs(cost - 3.0) < 0.001

    def test_output_only(self):
        cost = _estimate_cost(0, 1_000_000, 0)
        assert abs(cost - 15.0) < 0.001

    def test_cache_read_cheaper(self):
        cache_cost = _estimate_cost(0, 0, 1_000_000)
        input_cost = _estimate_cost(1_000_000, 0, 0)
        assert cache_cost < input_cost

    def test_combined(self):
        cost = _estimate_cost(100_000, 50_000, 200_000)
        expected = 100_000 * 3.0 / 1_000_000 + 50_000 * 15.0 / 1_000_000 + 200_000 * 0.30 / 1_000_000
        assert abs(cost - expected) < 0.0001


# ── attribute_sessions_to_commits ────────────────────────────

class TestAttributeSessionsToCommits:
    def test_empty_commits(self):
        result = attribute_sessions_to_commits([], [_session(0, 1)])
        assert result == []

    def test_empty_sessions(self):
        commits = [_commit("abc1234", 1)]
        result = attribute_sessions_to_commits(commits, [])
        assert len(result) == 1
        assert result[0].total_tokens == 0
        assert result[0].session_count == 0

    def test_session_fully_within_window(self):
        """Session entirely before a commit → attributed to that commit"""
        commits = [_commit("abc1234", 5)]
        sessions = [_session(0, 4)]  # session ends before commit
        result = attribute_sessions_to_commits(commits, sessions)
        assert len(result) == 1
        cc = result[0]
        assert cc.session_count == 1
        assert cc.total_tokens > 0

    def test_session_after_commit_not_attributed(self):
        """Session after commit → not attributed"""
        commits = [_commit("abc1234", 1)]
        sessions = [_session(2, 4)]  # session starts after commit
        result = attribute_sessions_to_commits(commits, sessions)
        assert result[0].session_count == 0
        assert result[0].total_tokens == 0

    def test_session_split_across_two_commits(self):
        """Session spanning two commit windows → tokens split proportionally"""
        commits = [_commit("aaa", 0), _commit("bbb", 2)]
        # Session covers hours -1 to 3, but first commit window = -24h to 0h
        # Second commit window = 0h to 2h
        sessions = [_session(-1, 3, inp=4000, out=0, cache=0)]
        result = attribute_sessions_to_commits(commits, sessions)

        # Both commits should get some tokens
        total = sum(cc.input_tokens for cc in result)
        assert total <= 4000  # may not be exact due to int truncation
        assert total > 0

    def test_multiple_commits_attribution_order(self):
        """Sessions are attributed to the correct commit by time window"""
        commits = [_commit("c1", 2), _commit("c2", 5), _commit("c3", 8)]
        s1 = _session(0, 1, inp=1000, out=0, cache=0)   # → c1
        s2 = _session(3, 4, inp=2000, out=0, cache=0)   # → c2
        s3 = _session(6, 7, inp=3000, out=0, cache=0)   # → c3
        result = attribute_sessions_to_commits(commits, [s1, s2, s3])
        assert result[0].input_tokens == 1000
        assert result[1].input_tokens == 2000
        assert result[2].input_tokens == 3000

    def test_zero_duration_session(self):
        """Zero-duration session is attributed fully"""
        commits = [_commit("abc", 5)]
        sessions = [{
            "start_time": _dt(2),
            "end_time": _dt(2),  # same start/end
            "input_tokens": 500,
            "output_tokens": 0,
            "cache_read_tokens": 0,
        }]
        result = attribute_sessions_to_commits(commits, sessions)
        assert result[0].input_tokens == 500

    def test_cost_computed(self):
        """estimated_cost_usd is positive when tokens > 0"""
        commits = [_commit("abc", 5)]
        sessions = [_session(0, 4, inp=10000, out=5000, cache=1000)]
        result = attribute_sessions_to_commits(commits, sessions)
        assert result[0].estimated_cost_usd > 0


# ── parse_git_log ─────────────────────────────────────────────

class TestParseGitLog:
    def test_non_git_directory(self, tmp_path):
        """Returns empty list for non-git directory"""
        result = parse_git_log(tmp_path)
        assert result == []

    def test_git_command_failure(self, tmp_path):
        """Returns empty list when git command fails"""
        (tmp_path / ".git").mkdir()
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stdout="")
            result = parse_git_log(tmp_path)
        assert result == []

    def test_git_not_found(self, tmp_path):
        """Returns empty list when git is not installed"""
        (tmp_path / ".git").mkdir()
        with patch("subprocess.run", side_effect=FileNotFoundError):
            result = parse_git_log(tmp_path)
        assert result == []

    def test_parses_single_commit(self, tmp_path):
        """Parses a single commit correctly"""
        (tmp_path / ".git").mkdir()
        fake_output = "\x00abc1234|2026-04-01T12:00:00+00:00|Alice|Initial commit\n5\t3\tfile.py\n"
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=fake_output)
            result = parse_git_log(tmp_path)
        assert len(result) == 1
        assert result[0].hash == "abc1234"
        assert result[0].author == "Alice"
        assert result[0].message == "Initial commit"
        assert result[0].added == 5
        assert result[0].removed == 3

    def test_commits_sorted_ascending(self, tmp_path):
        """Commits are returned in ascending time order"""
        (tmp_path / ".git").mkdir()
        # git log returns newest first; parse_git_log should sort ascending
        fake_output = (
            "\x00bbb2222|2026-04-01T14:00:00+00:00|Bob|Second commit\n"
            "\x00aaa1111|2026-04-01T10:00:00+00:00|Alice|First commit\n"
        )
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=fake_output)
            result = parse_git_log(tmp_path)
        assert result[0].hash == "aaa1111"
        assert result[1].hash == "bbb2222"

    def test_binary_files_skipped(self, tmp_path):
        """Binary files (- in numstat) are skipped"""
        (tmp_path / ".git").mkdir()
        fake_output = "\x00abc1234|2026-04-01T12:00:00+00:00|Alice|msg\n-\t-\timage.png\n10\t2\tfile.py\n"
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=fake_output)
            result = parse_git_log(tmp_path)
        assert result[0].added == 10
        assert result[0].removed == 2


# ── analyze_git_integration ───────────────────────────────────

class TestAnalyzeGitIntegration:
    def _make_stats(self, start_h: int, end_h: int, inp=1000, out=500, cache=100):
        """Create a mock SessionStats-like object"""
        stats = MagicMock()
        stats.start_time = _dt(start_h)
        stats.end_time = _dt(end_h)
        tu = MagicMock()
        tu.input_tokens = inp
        tu.output_tokens = out
        tu.cache_read_input_tokens = cache
        stats.token_usage = tu
        return stats

    def test_no_git_repo(self, tmp_path):
        """Returns empty result for non-git dir"""
        result = analyze_git_integration(tmp_path, [])
        assert result.total_commits == 0
        assert result.total_tokens == 0

    def test_full_pipeline(self, tmp_path):
        """Full pipeline: parse commits + attribute sessions"""
        (tmp_path / ".git").mkdir()
        fake_output = "\x00abc1234|2026-04-01T14:00:00+00:00|Alice|feat: add feature\n10\t2\tfile.py\n"
        stats = [self._make_stats(0, 2)]

        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=fake_output)
            result = analyze_git_integration(str(tmp_path), stats)

        assert result.total_commits == 1
        assert result.total_tokens > 0
        assert result.total_cost_usd > 0
        assert isinstance(result.commit_costs[0], CommitCost)


# ── format_git_integration ────────────────────────────────────

class TestFormatGitIntegration:
    def test_empty_result(self):
        from cc_stats.formatter import format_git_integration
        result = GitIntegrationResult(repo_path="/test/repo")
        output = format_git_integration(result)
        assert "Git Integration" in output
        assert "No commits found" in output

    def test_with_commits(self):
        from cc_stats.formatter import format_git_integration
        commit = CommitInfo(
            hash="abc1234567890",
            timestamp=_dt(0),
            author="Alice",
            message="feat: awesome feature",
        )
        cc = CommitCost(
            commit=commit,
            session_count=2,
            total_tokens=50000,
            input_tokens=30000,
            output_tokens=15000,
            cache_read_tokens=5000,
            estimated_cost_usd=0.32,
        )
        result = GitIntegrationResult(
            repo_path="/test/repo",
            commit_costs=[cc],
            total_commits=1,
            total_tokens=50000,
            total_cost_usd=0.32,
            sessions_matched=2,
        )
        output = format_git_integration(result)
        assert "abc1234" in output
        assert "feat: awesome feature" in output
        assert "0.320" in output
