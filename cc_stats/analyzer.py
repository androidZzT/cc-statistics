"""分析会话数据，计算各项工程指标"""

from __future__ import annotations

import os
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .parser import Message, Session

# 文件扩展名 → 语言映射
EXT_TO_LANG: dict[str, str] = {
    ".py": "Python",
    ".js": "JavaScript",
    ".ts": "TypeScript",
    ".tsx": "TypeScript (JSX)",
    ".jsx": "JavaScript (JSX)",
    ".java": "Java",
    ".kt": "Kotlin",
    ".kts": "Kotlin Script",
    ".swift": "Swift",
    ".go": "Go",
    ".rs": "Rust",
    ".c": "C",
    ".cpp": "C++",
    ".h": "C/C++ Header",
    ".cs": "C#",
    ".rb": "Ruby",
    ".php": "PHP",
    ".scala": "Scala",
    ".sh": "Shell",
    ".bash": "Shell",
    ".zsh": "Shell",
    ".html": "HTML",
    ".css": "CSS",
    ".scss": "SCSS",
    ".less": "Less",
    ".json": "JSON",
    ".yaml": "YAML",
    ".yml": "YAML",
    ".toml": "TOML",
    ".xml": "XML",
    ".sql": "SQL",
    ".md": "Markdown",
    ".r": "R",
    ".lua": "Lua",
    ".dart": "Dart",
    ".vue": "Vue",
    ".svelte": "Svelte",
    ".gradle": "Gradle",
}

# 工具说明
TOOL_DESCRIPTIONS: dict[str, str] = {
    "Bash": "执行 Shell 命令",
    "Read": "读取文件内容",
    "Write": "创建/覆写文件",
    "Edit": "编辑文件（精确替换）",
    "Glob": "按模式搜索文件",
    "Grep": "按内容搜索文件",
    "Agent": "启动子代理执行子任务",
    "Skill": "调用技能/Slash命令",
    "WebFetch": "抓取网页内容",
    "WebSearch": "搜索互联网",
    "NotebookEdit": "编辑 Jupyter Notebook",
    "LSP": "调用语言服务器",
    "TodoWrite": "写入待办事项",
    "AskUserQuestion": "向用户提问",
    "TaskCreate": "创建任务",
    "TaskUpdate": "更新任务状态",
    "TaskGet": "获取任务信息",
    "TaskList": "列出任务",
    "TaskOutput": "获取任务输出",
    "TaskStop": "停止任务",
    "ToolSearch": "搜索可用工具",
    "SendMessage": "向子代理发送消息",
}

# 活跃时间判定：两条消息间隔超过此值视为"不活跃"
IDLE_THRESHOLD = timedelta(minutes=5)


def _parse_ts(ts: str) -> datetime | None:
    """解析 ISO 格式或毫秒时间戳"""
    if not ts:
        return None
    try:
        if isinstance(ts, (int, float)) or ts.isdigit():
            return datetime.fromtimestamp(int(ts) / 1000, tz=timezone.utc)
        # ISO format
        ts = ts.replace("Z", "+00:00")
        return datetime.fromisoformat(ts)
    except (ValueError, OSError):
        return None


def _detect_lang(file_path: str) -> str:
    """根据文件扩展名检测编程语言"""
    _, ext = os.path.splitext(file_path)
    return EXT_TO_LANG.get(ext.lower(), f"Other ({ext})" if ext else "Unknown")


def _count_lines(text: str) -> int:
    """统计文本行数（不含末尾空行）"""
    if not text:
        return 0
    return len(text.rstrip("\n").split("\n"))


@dataclass
class CodeChange:
    file_path: str
    language: str
    added: int = 0
    removed: int = 0


@dataclass
class TokenUsage:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_input_tokens: int = 0
    cache_creation_input_tokens: int = 0

    @property
    def total(self) -> int:
        return (
            self.input_tokens
            + self.output_tokens
            + self.cache_read_input_tokens
            + self.cache_creation_input_tokens
        )


@dataclass
class SessionStats:
    """单个会话的统计结果"""
    session_id: str
    project_path: str

    # 1. 用户指令数
    user_message_count: int = 0

    # 2. 工具调用
    tool_call_total: int = 0
    tool_call_counts: dict[str, int] = field(default_factory=dict)

    # 3. 开发时长
    start_time: datetime | None = None
    end_time: datetime | None = None
    total_duration: timedelta = field(default_factory=timedelta)
    ai_duration: timedelta = field(default_factory=timedelta)       # AI 处理时长
    user_duration: timedelta = field(default_factory=timedelta)     # 用户活跃时长（审查/编码）
    active_duration: timedelta = field(default_factory=timedelta)   # ai + user
    turn_count: int = 0                                             # 对话轮次数

    # 4. 代码行数 (AI — 来自 Edit/Write 工具调用)
    code_changes: list[CodeChange] = field(default_factory=list)
    lines_by_lang: dict[str, dict[str, int]] = field(default_factory=dict)
    total_added: int = 0
    total_removed: int = 0

    # 4b. 代码行数 (Git — 会话期间的所有 commit)
    git_total_added: int = 0
    git_total_removed: int = 0
    git_lines_by_lang: dict[str, dict[str, int]] = field(default_factory=dict)
    git_commit_count: int = 0
    git_available: bool = False

    # 5. Token 消耗
    token_usage: TokenUsage = field(default_factory=TokenUsage)
    token_by_model: dict[str, TokenUsage] = field(default_factory=dict)


def _collect_git_stats(
    project_path: str,
    start_time: datetime,
    end_time: datetime,
) -> tuple[int, int, int, dict[str, dict[str, int]]]:
    """通过 git log 收集会话时间段内的 commit 变更统计

    Returns: (added, removed, commit_count, lines_by_lang)
    """
    repo_dir = Path(project_path)
    if not (repo_dir / ".git").exists() and not (repo_dir / ".git").is_file():
        return 0, 0, 0, {}

    # 转为本地时间，前后各扩展 1 分钟避免边界问题
    local_start = (start_time - timedelta(minutes=1)).astimezone()
    local_end = (end_time + timedelta(minutes=1)).astimezone()
    since = local_start.strftime("%Y-%m-%dT%H:%M:%S")
    until = local_end.strftime("%Y-%m-%dT%H:%M:%S")

    try:
        result = subprocess.run(
            [
                "git", "log",
                "--numstat",
                "--format=%H",
                f"--since={since}",
                f"--until={until}",
            ],
            cwd=project_path,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return 0, 0, 0, {}
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return 0, 0, 0, {}

    total_added = 0
    total_removed = 0
    commit_count = 0
    lang_stats: dict[str, dict[str, int]] = defaultdict(
        lambda: {"added": 0, "removed": 0}
    )

    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) == 1 and len(parts[0]) == 40:
            # commit hash
            commit_count += 1
        elif len(parts) == 3:
            added_str, removed_str, file_path = parts
            # binary files show as "-"
            if added_str == "-" or removed_str == "-":
                continue
            added = int(added_str)
            removed = int(removed_str)
            total_added += added
            total_removed += removed
            lang = _detect_lang(file_path)
            lang_stats[lang]["added"] += added
            lang_stats[lang]["removed"] += removed

    return total_added, total_removed, commit_count, dict(lang_stats)


def analyze_session(session: Session) -> SessionStats:
    """分析单个会话，返回统计结果"""
    stats = SessionStats(
        session_id=session.session_id,
        project_path=session.project_path,
    )

    # 构建带时间戳的消息序列，用于时长分析
    # timed_msgs: list of (datetime, role)
    # role: "user_real" = 真实用户消息, "user_tool" = 工具返回, "assistant"
    timed_msgs: list[tuple[datetime, str]] = []

    for msg in session.messages:
        ts = _parse_ts(msg.timestamp)
        if not ts:
            continue

        if msg.role == "user":
            if msg.is_tool_result or msg.is_meta:
                timed_msgs.append((ts, "user_tool"))
            else:
                timed_msgs.append((ts, "user_real"))
        elif msg.role == "assistant":
            timed_msgs.append((ts, "assistant"))

        # -------- 1. 用户指令数 --------
        if msg.role == "user" and not msg.is_tool_result and not msg.is_meta:
            stats.user_message_count += 1

        # -------- 2. 工具调用 --------
        if msg.role == "assistant":
            for tc in msg.tool_calls:
                stats.tool_call_total += 1

                # 展开 Skill 和 MCP 工具为具体名称
                display_name = tc.name
                if tc.name == "Skill":
                    skill_name = tc.input.get("skill", "")
                    if skill_name:
                        display_name = f"Skill:{skill_name}"
                elif tc.name.startswith("mcp__"):
                    # mcp__server__method → MCP:server/method
                    parts = tc.name.split("__")
                    if len(parts) >= 3:
                        display_name = f"MCP:{parts[1]}/{parts[2]}"

                stats.tool_call_counts[display_name] = (
                    stats.tool_call_counts.get(display_name, 0) + 1
                )

                # -------- 4. 代码行数（从 Edit/Write 工具提取） --------
                if tc.name == "Write":
                    fp = tc.input.get("file_path", "")
                    content = tc.input.get("content", "")
                    lang = _detect_lang(fp)
                    added = _count_lines(content)
                    change = CodeChange(
                        file_path=fp, language=lang, added=added, removed=0
                    )
                    stats.code_changes.append(change)

                elif tc.name == "Edit":
                    fp = tc.input.get("file_path", "")
                    old = tc.input.get("old_string", "")
                    new = tc.input.get("new_string", "")
                    lang = _detect_lang(fp)
                    old_lines = _count_lines(old)
                    new_lines = _count_lines(new)
                    change = CodeChange(
                        file_path=fp,
                        language=lang,
                        added=new_lines,
                        removed=old_lines,
                    )
                    stats.code_changes.append(change)

            # -------- 5. Token 消耗 --------
            usage = msg.usage
            if usage:
                inp = usage.get("input_tokens", 0)
                out = usage.get("output_tokens", 0)
                cache_read = usage.get("cache_read_input_tokens", 0)
                cache_create = usage.get("cache_creation_input_tokens", 0)

                stats.token_usage.input_tokens += inp
                stats.token_usage.output_tokens += out
                stats.token_usage.cache_read_input_tokens += cache_read
                stats.token_usage.cache_creation_input_tokens += cache_create

                model = msg.model or ""
                if not model or model.startswith("<"):
                    model = "unknown"
                if model not in stats.token_by_model:
                    stats.token_by_model[model] = TokenUsage()
                m = stats.token_by_model[model]
                m.input_tokens += inp
                m.output_tokens += out
                m.cache_read_input_tokens += cache_read
                m.cache_creation_input_tokens += cache_create

    # -------- 3. 时长计算（基于对话轮次） --------
    # 一轮 = 用户发消息 → AI 处理（可能多次工具调用）→ AI 最终回复
    # AI 时长 = 每轮中从用户消息到 AI 最后一条响应
    # 用户时长 = 上一轮 AI 最后响应到本轮用户消息（超过阈值视为离开）
    if timed_msgs:
        stats.start_time = timed_msgs[0][0]
        stats.end_time = timed_msgs[-1][0]
        stats.total_duration = stats.end_time - stats.start_time

        ai_total = timedelta()
        user_total = timedelta()
        turn_count = 0

        # 将消息流切分为轮次：每遇到一条 user_real 开启新轮
        # turn_start: 本轮用户消息的时间
        # last_ai_end: 上一轮 AI 最后响应的时间
        turn_start: datetime | None = None
        turn_last_ai: datetime | None = None
        last_ai_end: datetime | None = None  # 上一轮结束

        for ts, role in timed_msgs:
            if role == "user_real":
                # 结算上一轮的 AI 时长
                if turn_start is not None and turn_last_ai is not None:
                    ai_total += turn_last_ai - turn_start
                    turn_count += 1

                # 计算用户时长（上一轮 AI 结束 → 本轮用户消息）
                if last_ai_end is not None:
                    gap = ts - last_ai_end
                    if gap <= IDLE_THRESHOLD:
                        user_total += gap

                # 上一轮终点
                if turn_last_ai is not None:
                    last_ai_end = turn_last_ai

                turn_start = ts
                turn_last_ai = None
            elif role in ("assistant", "user_tool"):
                # AI 响应或工具返回，都算 AI 工作中
                turn_last_ai = ts

        # 结算最后一轮
        if turn_start is not None and turn_last_ai is not None:
            ai_total += turn_last_ai - turn_start
            turn_count += 1

        stats.ai_duration = ai_total
        stats.user_duration = user_total
        stats.active_duration = ai_total + user_total
        stats.turn_count = turn_count

    # -------- 4. 按语言汇总 --------
    lang_stats: dict[str, dict[str, int]] = defaultdict(
        lambda: {"added": 0, "removed": 0}
    )
    for change in stats.code_changes:
        lang_stats[change.language]["added"] += change.added
        lang_stats[change.language]["removed"] += change.removed
        stats.total_added += change.added
        stats.total_removed += change.removed
    stats.lines_by_lang = dict(lang_stats)

    # -------- 4b. Git 变更统计 --------
    if stats.start_time and stats.end_time and session.project_path:
        git_added, git_removed, git_commits, git_by_lang = _collect_git_stats(
            session.project_path, stats.start_time, stats.end_time
        )
        if git_commits > 0:
            stats.git_available = True
            stats.git_total_added = git_added
            stats.git_total_removed = git_removed
            stats.git_commit_count = git_commits
            stats.git_lines_by_lang = git_by_lang

    return stats


def merge_stats(all_stats: list[SessionStats]) -> SessionStats:
    """合并多个会话的统计结果"""
    merged = SessionStats(session_id="merged", project_path="all")

    all_starts = []
    all_ends = []

    for s in all_stats:
        merged.user_message_count += s.user_message_count
        merged.tool_call_total += s.tool_call_total

        for name, count in s.tool_call_counts.items():
            merged.tool_call_counts[name] = merged.tool_call_counts.get(name, 0) + count

        merged.ai_duration += s.ai_duration
        merged.user_duration += s.user_duration
        merged.active_duration += s.active_duration
        merged.turn_count += s.turn_count

        if s.start_time:
            all_starts.append(s.start_time)
        if s.end_time:
            all_ends.append(s.end_time)

        merged.code_changes.extend(s.code_changes)
        merged.total_added += s.total_added
        merged.total_removed += s.total_removed

        for lang, counts in s.lines_by_lang.items():
            if lang not in merged.lines_by_lang:
                merged.lines_by_lang[lang] = {"added": 0, "removed": 0}
            merged.lines_by_lang[lang]["added"] += counts["added"]
            merged.lines_by_lang[lang]["removed"] += counts["removed"]

        # Git 变更
        if s.git_available:
            merged.git_available = True
            merged.git_total_added += s.git_total_added
            merged.git_total_removed += s.git_total_removed
            merged.git_commit_count += s.git_commit_count
            for lang, counts in s.git_lines_by_lang.items():
                if lang not in merged.git_lines_by_lang:
                    merged.git_lines_by_lang[lang] = {"added": 0, "removed": 0}
                merged.git_lines_by_lang[lang]["added"] += counts["added"]
                merged.git_lines_by_lang[lang]["removed"] += counts["removed"]

        merged.token_usage.input_tokens += s.token_usage.input_tokens
        merged.token_usage.output_tokens += s.token_usage.output_tokens
        merged.token_usage.cache_read_input_tokens += s.token_usage.cache_read_input_tokens
        merged.token_usage.cache_creation_input_tokens += s.token_usage.cache_creation_input_tokens

        for model, usage in s.token_by_model.items():
            if model not in merged.token_by_model:
                merged.token_by_model[model] = TokenUsage()
            m = merged.token_by_model[model]
            m.input_tokens += usage.input_tokens
            m.output_tokens += usage.output_tokens
            m.cache_read_input_tokens += usage.cache_read_input_tokens
            m.cache_creation_input_tokens += usage.cache_creation_input_tokens

    if all_starts:
        merged.start_time = min(all_starts)
    if all_ends:
        merged.end_time = max(all_ends)
    if merged.start_time and merged.end_time:
        merged.total_duration = merged.end_time - merged.start_time

    return merged
