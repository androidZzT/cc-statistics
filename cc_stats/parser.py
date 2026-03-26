"""解析 Claude Code JSONL / Gemini CLI JSON 会话文件"""

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
    tool_use_id: str = ""


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
    message_id: str = ""  # API message ID，用于流式去重
    tool_results: dict[str, bool] = field(default_factory=dict)
    # tool_use_id -> is_error, 从 tool_result 块中提取


@dataclass
class Session:
    session_id: str
    project_path: str
    file_path: Path
    source: str = "claude"  # "claude" | "gemini"
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
                            tool_use_id=block.get("id", ""),
                        ))

            # 提取 tool_result 的 is_error 信息
            tool_results: dict[str, bool] = {}
            if is_tool_result and isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        tid = block.get("tool_use_id", "")
                        if tid:
                            tool_results[tid] = bool(block.get("is_error", False))

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
                tool_results=tool_results,
            ))

    # 流式去重：Claude Code 对同一条 API 消息会写多条 JSONL 记录
    # （prefill 记录 output_tokens=1 + 最终记录 output_tokens=实际值）
    # 按 message_id 去重，保留 output_tokens 最大的记录
    messages = _deduplicate_messages(messages)

    return Session(
        session_id=session_id,
        project_path=project_path,
        file_path=path,
        messages=messages,
    )


def _deduplicate_messages(messages: list[Message]) -> list[Message]:
    """按 message_id 去重 assistant 消息，保留 output_tokens 最大的记录"""
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


# ── Gemini CLI 解析 ──────────────────────────────────────────

# Gemini 工具名映射为 cc-stats 内部统一名称
_GEMINI_TOOL_MAP: dict[str, str] = {
    "read_file": "Read",
    "read_many_files": "Read",
    "edit_file": "Edit",
    "write_file": "Write",
    "shell": "Bash",
    "glob": "Glob",
    "grep": "Grep",
    "list_directory": "Glob",
    "web_search": "WebSearch",
    "web_fetch": "WebFetch",
}


def parse_gemini_json(path: Path) -> Session:
    """解析 Gemini CLI 的 JSON 会话文件为 Session 对象

    Gemini 会话格式：单个 JSON 文件，包含 sessionId、messages[] 等字段。
    消息类型：user / gemini / info / error / warning
    """
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    session_id = data.get("sessionId", path.stem)
    # 尝试从 directories 字段获取项目路径
    dirs = data.get("directories", [])
    project_path = dirs[0] if dirs else ""

    messages: list[Message] = []

    for msg_record in data.get("messages", []):
        msg_type = msg_record.get("type", "")
        timestamp = msg_record.get("timestamp", "")

        if msg_type == "user":
            content = _extract_gemini_content(msg_record.get("content"))
            messages.append(Message(
                role="user",
                timestamp=timestamp,
                content=content,
                session_id=session_id,
            ))

        elif msg_type == "gemini":
            content = _extract_gemini_content(msg_record.get("content"))
            model = msg_record.get("model", "")

            # 提取工具调用
            tool_calls: list[ToolCall] = []
            for tc in msg_record.get("toolCalls", []):
                raw_name = tc.get("name", "")
                mapped_name = _GEMINI_TOOL_MAP.get(raw_name, raw_name)
                tool_calls.append(ToolCall(
                    name=mapped_name,
                    input=tc.get("args", {}),
                    timestamp=tc.get("timestamp", timestamp),
                ))

            # 转换 token 用量为 cc-stats 统一格式
            usage: dict[str, Any] = {}
            tokens = msg_record.get("tokens")
            if tokens and isinstance(tokens, dict):
                usage = {
                    "input_tokens": tokens.get("input", 0),
                    "output_tokens": tokens.get("output", 0),
                    "cache_read_input_tokens": tokens.get("cached", 0),
                    "cache_creation_input_tokens": 0,
                }

            messages.append(Message(
                role="assistant",
                timestamp=timestamp,
                content=content,
                model=model,
                usage=usage,
                tool_calls=tool_calls,
                session_id=session_id,
            ))

        # info / error / warning 类型跳过（非对话消息）

    return Session(
        session_id=session_id,
        project_path=project_path,
        file_path=path,
        source="gemini",
        messages=messages,
    )


def _extract_gemini_content(raw: Any) -> Any:
    """提取 Gemini 消息内容（可能是字符串或 Part 列表）"""
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        texts = []
        for part in raw:
            if isinstance(part, dict) and "text" in part:
                texts.append(part["text"])
        return "\n".join(texts) if texts else raw
    return raw or ""


def find_gemini_sessions() -> list[Path]:
    """查找 ~/.gemini/tmp/*/chats/*.json 会话文件"""
    gemini_dir = Path.home() / ".gemini" / "tmp"
    if not gemini_dir.exists():
        return []

    results: list[Path] = []
    for chats_dir in gemini_dir.glob("*/chats"):
        if not chats_dir.is_dir():
            continue
        for json_file in sorted(chats_dir.glob("*.json")):
            results.append(json_file)

    return results


def find_gemini_sessions_by_keyword(keyword: str) -> list[Path]:
    """按关键词搜索 Gemini 会话（在 directories 和内容中搜索）"""
    all_sessions = find_gemini_sessions()
    if not all_sessions:
        return []

    keyword_lower = keyword.lower()
    results: list[Path] = []

    for path in all_sessions:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            dirs = data.get("directories", [])
            if any(keyword_lower in d.lower() for d in dirs):
                results.append(path)
                continue
            summary = data.get("summary", "")
            if summary and keyword_lower in summary.lower():
                results.append(path)
        except (json.JSONDecodeError, OSError):
            continue

    return results
