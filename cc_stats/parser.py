"""解析 Claude Code JSONL 会话文件"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class ToolCall:
    name: str
    input: dict[str, Any]
    timestamp: str


@dataclass
class Message:
    role: str  # "user" | "assistant"
    timestamp: str
    content: Any
    model: str | None = None
    usage: dict[str, Any] = field(default_factory=dict)
    tool_calls: list[ToolCall] = field(default_factory=list)
    is_tool_result: bool = False
    is_meta: bool = False
    session_id: str = ""
    # API message ID (e.g. "msg_17738...") for deduplication.
    # Claude Code writes multiple JSONL entries per streaming API call:
    # prefill records (output_tokens=1) then a final record with real output.
    # All entries share the same message_id.
    message_id: str = ""


@dataclass
class Session:
    session_id: str
    project_path: str
    file_path: Path
    messages: list[Message] = field(default_factory=list)


def parse_jsonl(path: Path) -> Session:
    """解析单个 JSONL 文件为 Session 对象"""
    messages: list[Message] = []
    session_id = path.stem
    project_path = ""

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get("type")
            if msg_type not in ("user", "assistant"):
                continue

            if not project_path:
                project_path = obj.get("cwd", "")

            raw_msg = obj.get("message", {})
            timestamp = obj.get("timestamp", "")
            content = raw_msg.get("content", "")

            # 判断是否为 tool_result（工具返回）
            is_tool_result = False
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        is_tool_result = True
                        break

            # 提取 tool_use 调用
            tool_calls: list[ToolCall] = []
            if msg_type == "assistant" and isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_calls.append(ToolCall(
                            name=block.get("name", ""),
                            input=block.get("input", {}),
                            timestamp=timestamp,
                        ))

            messages.append(Message(
                role=msg_type,
                timestamp=timestamp,
                content=content,
                model=raw_msg.get("model"),
                usage=raw_msg.get("usage", {}),
                tool_calls=tool_calls,
                is_tool_result=is_tool_result,
                is_meta=obj.get("isMeta", False),
                session_id=obj.get("sessionId", session_id),
                message_id=raw_msg.get("id", ""),
            ))

    # Deduplicate streaming records: same message_id may appear multiple times
    # (prefill with output_tokens=1, then final with real output_tokens).
    # Keep only the record with the largest output_tokens for each message_id.
    messages = _deduplicate_messages(messages)

    return Session(
        session_id=session_id,
        project_path=project_path,
        file_path=path,
        messages=messages,
    )


def _deduplicate_messages(messages: list[Message]) -> list[Message]:
    """Deduplicate assistant messages that share the same API message ID.

    Claude Code's JSONL logs multiple entries per streaming API call:
    prefill records (output_tokens ≤ 1) followed by a final record with real output.
    For each message_id, keep only the record with the largest output_tokens.
    Messages without a message_id (e.g. user messages) are kept as-is.
    """
    best: dict[str, tuple[int, int]] = {}  # message_id -> (index, output_tokens)
    to_remove: set[int] = set()

    for i, msg in enumerate(messages):
        if msg.role != "assistant" or not msg.message_id:
            continue
        out = msg.usage.get("output_tokens", 0) or 0
        if msg.message_id in best:
            old_idx, old_out = best[msg.message_id]
            if out > old_out:
                to_remove.add(old_idx)
                best[msg.message_id] = (i, out)
            else:
                to_remove.add(i)
        else:
            best[msg.message_id] = (i, out)

    if not to_remove:
        return messages
    return [m for i, m in enumerate(messages) if i not in to_remove]


def _path_to_dirname(path: Path) -> str:
    """将绝对路径转为 Claude Code 的项目目录名格式

    例如 /Users/foo/bar → -Users-foo-bar
    """
    return str(path.resolve()).replace("/", "-")


def find_sessions(project_dir: Path | None = None) -> list[Path]:
    """查找 ~/.claude/projects/ 下所有 JSONL 会话文件

    如果指定 project_dir，只返回匹配的项目。
    """
    claude_projects = Path.home() / ".claude" / "projects"
    if not claude_projects.exists():
        return []

    results: list[Path] = []
    target_dirname = _path_to_dirname(project_dir) if project_dir else None

    for proj in sorted(claude_projects.iterdir()):
        if not proj.is_dir():
            continue
        if target_dirname:
            if proj.name != target_dirname:
                continue
        for jsonl in sorted(proj.glob("*.jsonl")):
            # 跳过子代理会话
            if jsonl.name.startswith("agent-"):
                continue
            results.append(jsonl)

    return results


def find_sessions_by_keyword(keyword: str) -> list[Path]:
    """按关键词模糊匹配项目，在目录名和 JSONL 中的 cwd 中搜索"""
    import json

    claude_projects = Path.home() / ".claude" / "projects"
    if not claude_projects.exists():
        return []

    results: list[Path] = []
    keyword_lower = keyword.lower()

    for proj in sorted(claude_projects.iterdir()):
        if not proj.is_dir():
            continue
        jsonl_files = sorted(proj.glob("*.jsonl"))
        if not jsonl_files:
            continue

        # 先在目录名中搜索
        if keyword_lower in proj.name.lower():
            results.extend(jsonl_files)
            continue

        # 再在 JSONL 的 cwd 中搜索
        for jf in jsonl_files[:1]:
            try:
                with open(jf, encoding="utf-8") as fh:
                    for ln in fh:
                        try:
                            obj = json.loads(ln)
                            cwd = obj.get("cwd", "")
                            if cwd and keyword_lower in cwd.lower():
                                results.extend(jsonl_files)
                                break
                        except (json.JSONDecodeError, UnicodeDecodeError):
                            continue
                    else:
                        continue
                    break  # matched, stop checking more files
            except OSError:
                continue

    return results
