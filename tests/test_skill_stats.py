"""Skill 使用统计功能的单元测试"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from cc_stats.analyzer import (
    SessionStats,
    SkillUsage,
    analyze_session,
    merge_stats,
)
from cc_stats.formatter import format_skill_stats
from cc_stats.parser import Message, Session, ToolCall


def _make_session(messages: list[Message]) -> Session:
    return Session(
        session_id="test-session",
        project_path="/tmp/test-project",
        file_path=Path("/tmp/test.jsonl"),
        messages=messages,
    )


def _ts(hour: int = 10, minute: int = 0, day: int = 15) -> str:
    """生成 ISO 格式时间戳"""
    return f"2026-03-{day:02d}T{hour:02d}:{minute:02d}:00+00:00"


class TestSkillStatsExtraction:
    """测试 analyzer 从 Session 中正确提取 Skill 统计"""

    def test_no_skill_calls(self):
        """无 Skill 调用时 skill_stats 为空"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="hello"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="hi",
                tool_calls=[
                    ToolCall(name="Read", input={"file_path": "/tmp/x"}, timestamp=_ts(10, 1)),
                ],
            ),
        ])
        stats = analyze_session(session)
        assert stats.skill_stats == {}

    def test_single_skill_call_success(self):
        """单个 Skill 调用，成功"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="run commit"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content=[{"type": "tool_use", "name": "Skill", "id": "tu_1", "input": {"skill": "commit"}}],
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(10, 1), tool_use_id="tu_1"),
                ],
            ),
            Message(
                role="user",
                timestamp=_ts(10, 2),
                content=[{"type": "tool_result", "tool_use_id": "tu_1", "content": "done", "is_error": False}],
                is_tool_result=True,
                tool_results={"tu_1": False},
            ),
        ])
        stats = analyze_session(session)
        assert "commit" in stats.skill_stats
        su = stats.skill_stats["commit"]
        assert su.call_count == 1
        assert su.success_count == 1
        assert su.error_count == 0
        assert su.unknown_count == 0

    def test_single_skill_call_error(self):
        """单个 Skill 调用，失败"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="run commit"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="calling skill",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(10, 1), tool_use_id="tu_1"),
                ],
            ),
            Message(
                role="user",
                timestamp=_ts(10, 2),
                content=[{"type": "tool_result", "tool_use_id": "tu_1", "content": "error", "is_error": True}],
                is_tool_result=True,
                tool_results={"tu_1": True},
            ),
        ])
        stats = analyze_session(session)
        su = stats.skill_stats["commit"]
        assert su.call_count == 1
        assert su.success_count == 0
        assert su.error_count == 1

    def test_skill_call_no_result(self):
        """Skill 调用无对应的 tool_result → unknown"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="hi"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="calling",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "review-pr"}, timestamp=_ts(10, 1), tool_use_id="tu_orphan"),
                ],
            ),
        ])
        stats = analyze_session(session)
        su = stats.skill_stats["review-pr"]
        assert su.call_count == 1
        assert su.unknown_count == 1
        assert su.success_count == 0

    def test_skill_call_no_tool_use_id(self):
        """Skill 调用无 tool_use_id → unknown"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="hi"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="calling",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(10, 1), tool_use_id=""),
                ],
            ),
        ])
        stats = analyze_session(session)
        su = stats.skill_stats["commit"]
        assert su.unknown_count == 1

    def test_multiple_skills(self):
        """多个不同 Skill 调用"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="go"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="calling",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(10, 1), tool_use_id="tu_1"),
                    ToolCall(name="Skill", input={"skill": "review-pr"}, timestamp=_ts(10, 1), tool_use_id="tu_2"),
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(11, 0), tool_use_id="tu_3"),
                ],
            ),
            Message(
                role="user",
                timestamp=_ts(10, 2),
                content=[
                    {"type": "tool_result", "tool_use_id": "tu_1", "is_error": False},
                    {"type": "tool_result", "tool_use_id": "tu_2", "is_error": True},
                    {"type": "tool_result", "tool_use_id": "tu_3", "is_error": False},
                ],
                is_tool_result=True,
                tool_results={"tu_1": False, "tu_2": True, "tu_3": False},
            ),
        ])
        stats = analyze_session(session)
        assert stats.skill_stats["commit"].call_count == 2
        assert stats.skill_stats["commit"].success_count == 2
        assert stats.skill_stats["review-pr"].call_count == 1
        assert stats.skill_stats["review-pr"].error_count == 1

    def test_empty_skill_name(self):
        """Skill 调用 skill 参数为空 → 使用 'unknown'"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="go"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="calling",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": ""}, timestamp=_ts(10, 1)),
                ],
            ),
        ])
        stats = analyze_session(session)
        assert "unknown" in stats.skill_stats


class TestSkillStatsTimeDistribution:
    """测试时间分布统计"""

    def test_hourly_distribution(self):
        """按小时分布（UTC 时间转为本地时间后统计）"""
        session = _make_session([
            Message(role="user", timestamp=_ts(9, 0), content="go"),
            Message(
                role="assistant",
                timestamp=_ts(9, 1),
                content="calling",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(9, 30)),
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(14, 0)),
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(14, 30)),
                ],
            ),
        ])
        stats = analyze_session(session)
        su = stats.skill_stats["commit"]
        # 验证分布数据存在且合计正确（具体小时取决于本地时区）
        assert sum(su.hourly_dist.values()) == 3
        # 应该有 2 个不同的小时桶（9:30 和 14:00/14:30）
        assert len(su.hourly_dist) == 2

    def test_daily_distribution(self):
        """按天分布"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0, day=15), content="go"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1, day=15),
                content="calling",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(10, 0, day=15)),
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(10, 0, day=16)),
                ],
            ),
        ])
        stats = analyze_session(session)
        su = stats.skill_stats["commit"]
        assert su.daily_dist.get("2026-03-15", 0) == 1
        assert su.daily_dist.get("2026-03-16", 0) == 1


class TestSkillStatsMerge:
    """测试 merge_stats 对 skill_stats 的合并"""

    def test_merge_skill_stats(self):
        """合并两个会话的 skill 统计"""
        s1 = SessionStats(session_id="s1", project_path="/tmp")
        s1.skill_stats["commit"] = SkillUsage(
            name="commit", call_count=3, success_count=2, error_count=1,
            hourly_dist={10: 2, 14: 1}, daily_dist={"2026-03-15": 3},
        )

        s2 = SessionStats(session_id="s2", project_path="/tmp")
        s2.skill_stats["commit"] = SkillUsage(
            name="commit", call_count=2, success_count=2, error_count=0,
            hourly_dist={10: 1, 16: 1}, daily_dist={"2026-03-15": 1, "2026-03-16": 1},
        )
        s2.skill_stats["review-pr"] = SkillUsage(
            name="review-pr", call_count=1, success_count=1,
        )

        merged = merge_stats([s1, s2])

        assert merged.skill_stats["commit"].call_count == 5
        assert merged.skill_stats["commit"].success_count == 4
        assert merged.skill_stats["commit"].error_count == 1
        assert merged.skill_stats["commit"].hourly_dist[10] == 3
        assert merged.skill_stats["commit"].hourly_dist[14] == 1
        assert merged.skill_stats["commit"].hourly_dist[16] == 1
        assert merged.skill_stats["commit"].daily_dist["2026-03-15"] == 4
        assert merged.skill_stats["commit"].daily_dist["2026-03-16"] == 1
        assert merged.skill_stats["review-pr"].call_count == 1

    def test_merge_empty_skill_stats(self):
        """合并空 skill 统计"""
        s1 = SessionStats(session_id="s1", project_path="/tmp")
        s2 = SessionStats(session_id="s2", project_path="/tmp")
        merged = merge_stats([s1, s2])
        assert merged.skill_stats == {}


class TestFormatSkillStats:
    """测试 format_skill_stats 的输出"""

    def test_no_skills(self):
        """无 skill 数据时输出提示"""
        stats = SessionStats(session_id="test", project_path="/tmp")
        output = format_skill_stats(stats)
        assert "未发现 Skill 调用记录" in output

    def test_with_skills(self):
        """有 skill 数据时输出包含关键信息"""
        stats = SessionStats(session_id="test", project_path="/tmp/project")
        stats.start_time = datetime(2026, 3, 15, 10, 0, tzinfo=timezone.utc)
        stats.end_time = datetime(2026, 3, 15, 12, 0, tzinfo=timezone.utc)
        stats.skill_stats["commit"] = SkillUsage(
            name="commit",
            call_count=5,
            success_count=4,
            error_count=1,
            hourly_dist={10: 3, 11: 2},
            daily_dist={"2026-03-15": 5},
        )
        stats.skill_stats["review-pr"] = SkillUsage(
            name="review-pr",
            call_count=2,
            success_count=2,
            hourly_dist={10: 1, 11: 1},
            daily_dist={"2026-03-15": 2},
        )

        output = format_skill_stats(stats, session_count=3)
        assert "Skill 使用统计报告" in output
        assert "commit" in output
        assert "review-pr" in output
        assert "会话数" in output
        assert "3" in output
        # 成功率
        assert "80%" in output  # commit: 4/5 = 80%
        assert "100%" in output  # review-pr: 2/2 = 100%

    def test_format_skill_stats_unknown_only(self):
        """所有调用都是 unknown 时，成功率显示 N/A"""
        stats = SessionStats(session_id="test", project_path="/tmp")
        stats.skill_stats["commit"] = SkillUsage(
            name="commit", call_count=3, unknown_count=3,
        )
        output = format_skill_stats(stats)
        assert "N/A" in output


class TestToolCallCountsBackwardCompat:
    """验证 --skills 不影响现有 tool_call_counts 行为"""

    def test_skill_still_in_tool_call_counts(self):
        """Skill 调用仍然计入 tool_call_counts（向后兼容）"""
        session = _make_session([
            Message(role="user", timestamp=_ts(10, 0), content="go"),
            Message(
                role="assistant",
                timestamp=_ts(10, 1),
                content="calling",
                tool_calls=[
                    ToolCall(name="Skill", input={"skill": "commit"}, timestamp=_ts(10, 1)),
                    ToolCall(name="Read", input={"file_path": "/tmp/x"}, timestamp=_ts(10, 1)),
                ],
            ),
        ])
        stats = analyze_session(session)
        assert stats.tool_call_counts.get("Skill:commit") == 1
        assert stats.tool_call_counts.get("Read") == 1
        assert stats.tool_call_total == 2


class TestParserToolUseId:
    """测试 parser 正确提取 tool_use_id 和 tool_results"""

    def test_tool_call_has_tool_use_id(self):
        """ToolCall 包含 tool_use_id"""
        tc = ToolCall(name="Skill", input={"skill": "commit"}, timestamp="t1", tool_use_id="tu_123")
        assert tc.tool_use_id == "tu_123"

    def test_tool_call_default_empty_id(self):
        """ToolCall 默认 tool_use_id 为空"""
        tc = ToolCall(name="Skill", input={"skill": "commit"}, timestamp="t1")
        assert tc.tool_use_id == ""

    def test_message_tool_results(self):
        """Message.tool_results 存储 tool_use_id -> is_error 映射"""
        msg = Message(
            role="user",
            timestamp="t1",
            content=[],
            is_tool_result=True,
            tool_results={"tu_1": False, "tu_2": True},
        )
        assert msg.tool_results["tu_1"] is False
        assert msg.tool_results["tu_2"] is True
