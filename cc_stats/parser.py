"""解析 Claude Code / Codex / Gemini 会话文件"""

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
    source: str = "claude"  # "claude" | "codex" | "gemini"
    messages: list[Message] = field(default_factory=list)
    # Codex 专用：从 event_msg/token_count 里直接拿到的 OpenAI 后端原值快照
    # 形如 {"primary": {"used_percent": 12.5, "window_minutes": 300, "resets_at": ...},
    #       "secondary": {...}, "plan_type": "...", ...}
    codex_rate_limits: dict[str, Any] | None = None
    # 该 snapshot 对应的事件时间戳（ISO 字符串），用于跨 session 合并时挑最新
    codex_rate_limits_ts: str = ""


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
            # 防御性过滤：跳过 subagents/ 子目录下的文件，避免双重计数
            # 父 session JSONL 已包含 subagents 的所有消息和 token
            if "subagents" in jsonl.parts:
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
        # 防御性过滤：排除 subagents/ 子目录下的文件，避免双重计数
        # 父 session JSONL 已包含 subagents 的所有消息和 token
        jsonl_files = [
            f for f in sorted(proj.glob("*.jsonl"))
            if "subagents" not in f.parts
        ]
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


# ── Codex 解析 ───────────────────────────────────────────────

_CODEX_TOOL_MAP: dict[str, str] = {
    "exec_command": "Bash",
    "write_stdin": "Bash",
    "read_mcp_resource": "Read",
    "list_mcp_resources": "ToolSearch",
    "list_mcp_resource_templates": "ToolSearch",
    "search_query": "WebSearch",
    "image_query": "WebSearch",
    "web.run": "WebSearch",
    "apply_patch": "Edit",
}


def _to_int(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        try:
            return int(float(value))
        except ValueError:
            return 0
    return 0


def _merge_usage(dst: dict[str, Any], src: dict[str, Any]) -> None:
    for key in (
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    ):
        dst[key] = _to_int(dst.get(key, 0)) + _to_int(src.get(key, 0))


def _extract_codex_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""

    parts: list[str] = []
    for block in content:
        if isinstance(block, str):
            parts.append(block)
            continue
        if not isinstance(block, dict):
            continue
        block_type = block.get("type")
        if block_type in ("text", "input_text", "output_text"):
            text = block.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(parts)


def _is_codex_meta_user_text(text: str) -> bool:
    s = text.lstrip()
    return (
        s.startswith("<environment_context>")
        or s.startswith("<permissions instructions>")
        or s.startswith("<app-context>")
    )


def _parse_apply_patch_stats(raw_args: Any) -> dict[str, Any]:
    patch_text = raw_args if isinstance(raw_args, str) else ""
    if isinstance(raw_args, dict):
        patch_text = str(raw_args.get("patch") or raw_args.get("input") or "")

    file_path = ""
    added = 0
    removed = 0
    for line in patch_text.splitlines():
        if not file_path:
            if line.startswith("*** Update File: "):
                file_path = line.split(": ", 1)[1].strip()
            elif line.startswith("*** Add File: "):
                file_path = line.split(": ", 1)[1].strip()
            elif line.startswith("*** Delete File: "):
                file_path = line.split(": ", 1)[1].strip()
        if line.startswith("+") and not line.startswith("+++"):
            added += 1
        elif line.startswith("-") and not line.startswith("---"):
            removed += 1

    def _dummy_lines(n: int) -> str:
        return "\n".join(["x"] * n) if n > 0 else ""

    return {
        "target_file": file_path,
        "old_string": _dummy_lines(removed),
        "new_string": _dummy_lines(added),
    }


def _parse_codex_tool_input(tool_name: str, raw_args: Any) -> dict[str, Any]:
    if tool_name == "apply_patch":
        return _parse_apply_patch_stats(raw_args)

    if isinstance(raw_args, dict):
        return raw_args
    if isinstance(raw_args, str):
        try:
            data = json.loads(raw_args)
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            return {}
    return {}


def _extract_codex_token_usage(payload: dict[str, Any]) -> dict[str, Any]:
    info = payload.get("info")
    if not isinstance(info, dict):
        return {}

    usage = info.get("last_token_usage")
    if not isinstance(usage, dict):
        return {}

    raw_input = _to_int(usage.get("input_tokens", 0))
    cached = _to_int(usage.get("cached_input_tokens", 0))
    output = _to_int(usage.get("output_tokens", 0))

    if raw_input <= 0 and cached <= 0 and output <= 0:
        return {}

    # Codex 的 input_tokens 包含 cached_input_tokens，转换为 cc-stats 统一口径：
    # total = input + output + cache_read + cache_creation
    input_tokens = max(raw_input - cached, 0)
    return {
        "input_tokens": input_tokens,
        "output_tokens": output,
        "cache_read_input_tokens": cached,
        "cache_creation_input_tokens": 0,
    }


def _extract_codex_model(payload: dict[str, Any]) -> str:
    model = payload.get("model")
    if isinstance(model, str) and model:
        return model

    collab = payload.get("collaboration_mode")
    if isinstance(collab, dict):
        settings = collab.get("settings")
        if isinstance(settings, dict):
            setting_model = settings.get("model")
            if isinstance(setting_model, str) and setting_model:
                return setting_model

    return ""


def parse_codex_jsonl(path: Path) -> Session:
    """解析 Codex rollout JSONL 会话文件"""
    session_id = path.stem
    project_path = ""
    messages: list[Message] = []
    assistant_indices: list[int] = []
    seen_user: set[tuple[str, str]] = set()
    seen_assistant: set[tuple[str, str]] = set()
    last_total_tokens: int | None = None
    latest_model = ""
    # 跟踪整个文件里最新一次 rate_limits snapshot（OpenAI 后端原值，不是本地估算）
    latest_rate_limits: dict[str, Any] | None = None
    latest_rate_limits_ts = ""

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            timestamp = obj.get("timestamp", "")
            obj_type = obj.get("type", "")
            payload = obj.get("payload", {})
            if not isinstance(payload, dict):
                payload = {}

            if obj_type == "session_meta":
                meta_sid = payload.get("id")
                if isinstance(meta_sid, str) and meta_sid:
                    session_id = meta_sid
                cwd = payload.get("cwd")
                if isinstance(cwd, str) and cwd:
                    project_path = cwd
                model = _extract_codex_model(payload)
                if model:
                    latest_model = model
                continue

            if obj_type == "turn_context":
                model = _extract_codex_model(payload)
                if model:
                    latest_model = model
                continue

            if obj_type == "event_msg":
                ev_type = payload.get("type", "")

                if ev_type == "user_message":
                    text = payload.get("message", "")
                    if not isinstance(text, str):
                        continue
                    key = (timestamp, text)
                    if key in seen_user:
                        continue
                    seen_user.add(key)
                    messages.append(Message(
                        role="user",
                        timestamp=timestamp,
                        content=text,
                        session_id=session_id,
                    ))
                    continue

                if ev_type == "agent_message":
                    text = payload.get("message", "")
                    if not isinstance(text, str):
                        continue
                    key = (timestamp, text)
                    if key in seen_assistant:
                        continue
                    seen_assistant.add(key)
                    messages.append(Message(
                        role="assistant",
                        timestamp=timestamp,
                        content=text,
                        model=latest_model or None,
                        session_id=session_id,
                    ))
                    assistant_indices.append(len(messages) - 1)
                    continue

                if ev_type == "token_count":
                    # 优先记录最新 rate_limits snapshot（即便 token_usage 重复也要更新）
                    rl = payload.get("rate_limits")
                    if isinstance(rl, dict) and rl:
                        latest_rate_limits = rl
                        latest_rate_limits_ts = timestamp

                    info = payload.get("info", {})
                    if isinstance(info, dict):
                        totals = info.get("total_token_usage", {})
                        if isinstance(totals, dict):
                            total_tokens = _to_int(totals.get("total_tokens", 0))
                            if (
                                total_tokens > 0
                                and last_total_tokens is not None
                                and total_tokens == last_total_tokens
                            ):
                                continue
                            if total_tokens > 0:
                                last_total_tokens = total_tokens

                    usage = _extract_codex_token_usage(payload)
                    if not usage:
                        continue
                    if assistant_indices:
                        last_msg = messages[assistant_indices[-1]]
                        _merge_usage(last_msg.usage, usage)
                        if not last_msg.model and latest_model:
                            last_msg.model = latest_model
                    else:
                        messages.append(Message(
                            role="assistant",
                            timestamp=timestamp,
                            content="",
                            usage=usage,
                            model=latest_model or None,
                            session_id=session_id,
                            is_meta=True,
                        ))
                        assistant_indices.append(len(messages) - 1)
                    continue

            if obj_type == "response_item":
                item_type = payload.get("type", "")

                if item_type == "function_call":
                    raw_name = payload.get("name", "")
                    if not isinstance(raw_name, str) or not raw_name:
                        continue
                    mapped_name = _CODEX_TOOL_MAP.get(raw_name, raw_name)
                    args = payload.get("arguments")
                    tc = ToolCall(
                        name=mapped_name,
                        input=_parse_codex_tool_input(raw_name, args),
                        timestamp=timestamp,
                        tool_use_id=str(payload.get("call_id", "")),
                    )
                    messages.append(Message(
                        role="assistant",
                        timestamp=timestamp,
                        content="",
                        model=latest_model or None,
                        tool_calls=[tc],
                        session_id=session_id,
                    ))
                    assistant_indices.append(len(messages) - 1)
                    continue

                if item_type == "web_search_call":
                    action = payload.get("action", {})
                    tc = ToolCall(
                        name="WebSearch",
                        input=action if isinstance(action, dict) else {},
                        timestamp=timestamp,
                    )
                    messages.append(Message(
                        role="assistant",
                        timestamp=timestamp,
                        content="",
                        tool_calls=[tc],
                        session_id=session_id,
                    ))
                    assistant_indices.append(len(messages) - 1)
                    continue

                if item_type == "message":
                    role = payload.get("role", "")
                    content = _extract_codex_text(payload.get("content"))
                    if not content:
                        continue
                    if role == "user":
                        if _is_codex_meta_user_text(content):
                            continue
                        key = (timestamp, content)
                        if key in seen_user:
                            continue
                        seen_user.add(key)
                        messages.append(Message(
                            role="user",
                            timestamp=timestamp,
                            content=content,
                            session_id=session_id,
                        ))
                    elif role == "assistant":
                        key = (timestamp, content)
                        if key in seen_assistant:
                            continue
                        seen_assistant.add(key)
                        messages.append(Message(
                            role="assistant",
                            timestamp=timestamp,
                            content=content,
                            model=latest_model or None,
                            session_id=session_id,
                        ))
                        assistant_indices.append(len(messages) - 1)

    return Session(
        session_id=session_id,
        project_path=project_path,
        file_path=path,
        source="codex",
        messages=messages,
        codex_rate_limits=latest_rate_limits,
        codex_rate_limits_ts=latest_rate_limits_ts,
    )


def _looks_like_codex_jsonl(path: Path) -> bool:
    if path.suffix != ".jsonl":
        return False

    if (
        path.name.startswith("rollout-")
        and "sessions" in path.parts
        and ".codex" in path.parts
    ):
        return True

    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg_type = obj.get("type", "")
                if msg_type in ("session_meta", "event_msg", "response_item", "turn_context"):
                    return True
                if msg_type in ("user", "assistant"):
                    return False
                break
    except OSError:
        return False

    return False


def _read_codex_session_meta(path: Path) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") == "session_meta":
                    payload = obj.get("payload", {})
                    return payload if isinstance(payload, dict) else {}
    except OSError:
        return {}
    return {}


def find_codex_sessions(project_dir: Path | None = None) -> list[Path]:
    """查找 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl 会话文件"""
    base = Path.home() / ".codex" / "sessions"
    if not base.exists():
        return []

    all_files = sorted(base.glob("*/*/*/rollout-*.jsonl"))
    if project_dir is None:
        return all_files

    try:
        target = str(project_dir.expanduser().resolve())
    except OSError:
        target = str(project_dir)

    results: list[Path] = []
    for path in all_files:
        meta = _read_codex_session_meta(path)
        cwd = meta.get("cwd", "")
        if not isinstance(cwd, str) or not cwd:
            continue
        try:
            normalized = str(Path(cwd).expanduser().resolve())
        except OSError:
            normalized = cwd
        if normalized == target:
            results.append(path)
    return results


def find_codex_sessions_by_keyword(keyword: str) -> list[Path]:
    """按关键词搜索 Codex 会话（路径/cwd/用户消息内容）"""
    keyword_lower = keyword.lower()
    results: list[Path] = []

    for path in find_codex_sessions():
        if keyword_lower in str(path).lower():
            results.append(path)
            continue

        meta = _read_codex_session_meta(path)
        cwd = meta.get("cwd", "")
        if isinstance(cwd, str) and cwd and keyword_lower in cwd.lower():
            results.append(path)
            continue

        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if obj.get("type") != "event_msg":
                        continue
                    payload = obj.get("payload", {})
                    if not isinstance(payload, dict):
                        continue
                    if payload.get("type") == "user_message":
                        msg = payload.get("message", "")
                        if isinstance(msg, str) and keyword_lower in msg.lower():
                            results.append(path)
                            break
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


def parse_session_file(path: Path) -> Session:
    """自动识别并解析会话文件（Claude / Codex / Gemini）"""
    if path.suffix == ".json":
        return parse_gemini_json(path)
    if _looks_like_codex_jsonl(path):
        return parse_codex_jsonl(path)
    return parse_jsonl(path)
