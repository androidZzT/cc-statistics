"""Git 集成：将 Claude Code 会话按时间归属到 git commit，计算每 commit 的 AI 成本"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path


# Claude 模型定价 (USD per 1M tokens) — 与 analyzer.py 保持一致
_INPUT_PRICE = 3.0        # $3/1M input tokens (Sonnet baseline)
_OUTPUT_PRICE = 15.0      # $15/1M output tokens
_CACHE_READ_PRICE = 0.30  # $0.30/1M cache read tokens


@dataclass(frozen=True)
class CommitInfo:
    """单个 git commit 的基本信息"""
    hash: str
    timestamp: datetime
    author: str
    message: str          # 首行
    added: int = 0
    removed: int = 0


@dataclass
class CommitCost:
    """单个 commit 归属的 AI 会话成本"""
    commit: CommitInfo
    session_count: int = 0
    total_tokens: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    estimated_cost_usd: float = 0.0


@dataclass
class GitIntegrationResult:
    """Git 集成分析的完整结果"""
    repo_path: str
    commit_costs: list[CommitCost] = field(default_factory=list)
    total_commits: int = 0
    total_tokens: int = 0
    total_cost_usd: float = 0.0
    sessions_matched: int = 0


def parse_git_log(
    repo_path: str | Path,
    since: datetime | None = None,
    until: datetime | None = None,
) -> list[CommitInfo]:
    """通过 git log 解析 commit 列表（含 numstat）

    Args:
        repo_path: git 仓库路径
        since: 起始时间（可选）
        until: 截止时间（可选）

    Returns:
        按时间升序排列的 CommitInfo 列表
    """
    repo = Path(repo_path)
    if not (repo / ".git").exists() and not (repo / ".git").is_file():
        return []

    cmd = [
        "git", "log",
        "--numstat",
        "--format=%x00%H|%aI|%an|%s",
    ]
    if since:
        cmd.append(f"--since={since.strftime('%Y-%m-%dT%H:%M:%S%z')}")
    if until:
        cmd.append(f"--until={until.strftime('%Y-%m-%dT%H:%M:%S%z')}")

    try:
        result = subprocess.run(
            cmd,
            cwd=str(repo),
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            return []
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    commits: list[CommitInfo] = []
    current_hash = ""
    current_ts: datetime | None = None
    current_author = ""
    current_message = ""
    current_added = 0
    current_removed = 0

    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        # commit 头行：\x00HASH|ISO_DATE|AUTHOR|MESSAGE
        if stripped.startswith("\x00"):
            # 先保存上一个 commit
            if current_hash and current_ts:
                commits.append(CommitInfo(
                    hash=current_hash,
                    timestamp=current_ts,
                    author=current_author,
                    message=current_message,
                    added=current_added,
                    removed=current_removed,
                ))
            # 解析新 commit
            parts = stripped[1:].split("|", 3)
            if len(parts) < 4:
                current_hash = ""
                continue
            current_hash = parts[0]
            try:
                current_ts = datetime.fromisoformat(parts[1])
            except ValueError:
                current_hash = ""
                continue
            current_author = parts[2]
            current_message = parts[3]
            current_added = 0
            current_removed = 0
            continue

        # numstat 行：added\tremoved\tfile_path
        tab_parts = stripped.split("\t")
        if len(tab_parts) == 3:
            a_str, r_str, _ = tab_parts
            if a_str == "-" or r_str == "-":
                continue  # 二进制文件
            try:
                current_added += int(a_str)
                current_removed += int(r_str)
            except ValueError:
                continue

    # 保存最后一个 commit
    if current_hash and current_ts:
        commits.append(CommitInfo(
            hash=current_hash,
            timestamp=current_ts,
            author=current_author,
            message=current_message,
            added=current_added,
            removed=current_removed,
        ))

    # 按时间升序
    commits.sort(key=lambda c: c.timestamp)
    return commits


def _estimate_cost(
    input_tokens: int,
    output_tokens: int,
    cache_read_tokens: int,
) -> float:
    """估算 token 费用（USD）"""
    return (
        input_tokens * _INPUT_PRICE / 1_000_000
        + output_tokens * _OUTPUT_PRICE / 1_000_000
        + cache_read_tokens * _CACHE_READ_PRICE / 1_000_000
    )


def attribute_sessions_to_commits(
    commits: list[CommitInfo],
    sessions: list[dict],
) -> list[CommitCost]:
    """将 session 按时间归属到 commit，计算每 commit 的 token/cost

    归属规则：
    - commit 的时间窗口 = (上一个 commit 时间, 当前 commit 时间]
    - 第一个 commit 的窗口 = (commit_time - 24h, commit_time]
    - 如果 session 时间范围与窗口有交集，按交集占 session 总时长的比例分配 token

    Args:
        commits: 按时间升序的 CommitInfo 列表
        sessions: session 信息列表，每个 dict 包含:
            - start_time: datetime
            - end_time: datetime
            - input_tokens: int
            - output_tokens: int
            - cache_read_tokens: int

    Returns:
        CommitCost 列表（与 commits 顺序对应）
    """
    if not commits:
        return []

    results: list[CommitCost] = []

    for i, commit in enumerate(commits):
        # 确定 commit 窗口
        if i == 0:
            window_start = commit.timestamp - timedelta(hours=24)
        else:
            window_start = commits[i - 1].timestamp
        window_end = commit.timestamp

        cost = CommitCost(commit=commit)
        matched_sessions: set[int] = set()

        for j, sess in enumerate(sessions):
            s_start = sess["start_time"]
            s_end = sess["end_time"]

            # 跳过无效 session
            if s_start is None or s_end is None:
                continue

            # 确保 timezone-aware 比较
            if s_start.tzinfo is None:
                s_start = s_start.replace(tzinfo=timezone.utc)
            if s_end.tzinfo is None:
                s_end = s_end.replace(tzinfo=timezone.utc)

            w_start = window_start
            w_end = window_end
            if w_start.tzinfo is None:
                w_start = w_start.replace(tzinfo=timezone.utc)
            if w_end.tzinfo is None:
                w_end = w_end.replace(tzinfo=timezone.utc)

            # 计算交集
            # 零时长 session：只检查点是否在窗口内
            session_duration = (s_end - s_start).total_seconds()
            if session_duration <= 0:
                if w_start <= s_start <= w_end:
                    ratio = 1.0
                else:
                    continue
            else:
                overlap_start = max(s_start, w_start)
                overlap_end = min(s_end, w_end)
                if overlap_start >= overlap_end:
                    continue
                overlap_duration = (overlap_end - overlap_start).total_seconds()
                ratio = overlap_duration / session_duration

            inp = int(sess["input_tokens"] * ratio)
            out = int(sess["output_tokens"] * ratio)
            cache = int(sess["cache_read_tokens"] * ratio)

            cost.input_tokens += inp
            cost.output_tokens += out
            cost.cache_read_tokens += cache
            matched_sessions.add(j)

        cost.session_count = len(matched_sessions)
        cost.total_tokens = cost.input_tokens + cost.output_tokens + cost.cache_read_tokens
        cost.estimated_cost_usd = _estimate_cost(
            cost.input_tokens, cost.output_tokens, cost.cache_read_tokens
        )
        results.append(cost)

    return results


def analyze_git_integration(
    repo_path: str | Path,
    all_stats: list,
    since: datetime | None = None,
    until: datetime | None = None,
) -> GitIntegrationResult:
    """执行完整的 Git 集成分析

    Args:
        repo_path: git 仓库路径
        all_stats: SessionStats 列表（来自 analyzer.analyze_session）
        since: 起始时间过滤
        until: 截止时间过滤

    Returns:
        GitIntegrationResult 完整结果
    """
    repo_path = str(repo_path)

    # 1. 解析 git log
    commits = parse_git_log(repo_path, since=since, until=until)
    if not commits:
        return GitIntegrationResult(repo_path=repo_path)

    # 2. 从 SessionStats 提取 session 摘要
    sessions: list[dict] = []
    for s in all_stats:
        tu = s.token_usage
        sessions.append({
            "start_time": s.start_time,
            "end_time": s.end_time,
            "input_tokens": tu.input_tokens,
            "output_tokens": tu.output_tokens,
            "cache_read_tokens": tu.cache_read_input_tokens,
        })

    # 3. 归属 session 到 commit
    commit_costs = attribute_sessions_to_commits(commits, sessions)

    # 4. 汇总
    total_tokens = sum(c.total_tokens for c in commit_costs)
    total_cost = sum(c.estimated_cost_usd for c in commit_costs)
    matched = len({j for c in commit_costs for j in range(len(sessions))
                    if c.session_count > 0})
    # 更精确：统计被匹配的唯一 session 数
    matched_set: set[int] = set()
    for i, cc in enumerate(commit_costs):
        if cc.session_count > 0:
            # 回溯查看哪些 session 匹配了此 commit
            for j, sess in enumerate(sessions):
                s_start = sess["start_time"]
                s_end = sess["end_time"]
                if s_start is None or s_end is None:
                    continue
                if s_start.tzinfo is None:
                    s_start = s_start.replace(tzinfo=timezone.utc)
                if s_end.tzinfo is None:
                    s_end = s_end.replace(tzinfo=timezone.utc)
                w_start = (commits[i - 1].timestamp if i > 0
                           else commits[i].timestamp - timedelta(hours=24))
                w_end = commits[i].timestamp
                if w_start.tzinfo is None:
                    w_start = w_start.replace(tzinfo=timezone.utc)
                if w_end.tzinfo is None:
                    w_end = w_end.replace(tzinfo=timezone.utc)
                overlap_start = max(s_start, w_start)
                overlap_end = min(s_end, w_end)
                if overlap_start < overlap_end:
                    matched_set.add(j)

    return GitIntegrationResult(
        repo_path=repo_path,
        commit_costs=commit_costs,
        total_commits=len(commits),
        total_tokens=total_tokens,
        total_cost_usd=total_cost,
        sessions_matched=len(matched_set),
    )
