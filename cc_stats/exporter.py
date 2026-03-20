"""导出会话为 Markdown 格式，方便分享"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from .parser import Message, Session, find_sessions, parse_jsonl


def _extract_text(content) -> str:
    """从 content 中提取纯文本"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    parts.append(block.get("text", ""))
                elif block.get("type") == "tool_use":
                    name = block.get("name", "")
                    parts.append(f"[Tool: {name}]")
                elif block.get("type") == "tool_result":
                    # 跳过工具返回
                    continue
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    return str(content)


def _fmt_ts(ts_str: str) -> str:
    """格式化时间戳"""
    if not ts_str:
        return ""
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%H:%M:%S")
    except (ValueError, TypeError):
        return ""


def export_session(session: Session, include_tools: bool = False) -> str:
    """将会话导出为 Markdown"""
    lines: list[str] = []

    # 标题
    start_ts = ""
    for msg in session.messages:
        if msg.timestamp:
            try:
                dt = datetime.fromisoformat(msg.timestamp.replace("Z", "+00:00"))
                start_ts = dt.astimezone().strftime("%Y-%m-%d %H:%M")
            except (ValueError, TypeError):
                pass
            break

    lines.append(f"# Claude Code 对话记录")
    lines.append(f"")
    if start_ts:
        lines.append(f"**时间:** {start_ts}")
    if session.project_path:
        project_name = Path(session.project_path).name
        lines.append(f"**项目:** {project_name}")
    lines.append(f"**会话 ID:** `{session.session_id[:12]}...`")
    lines.append(f"")
    lines.append(f"---")
    lines.append(f"")

    for msg in session.messages:
        # 跳过工具返回和 meta 消息
        if msg.is_tool_result or msg.is_meta:
            continue

        text = _extract_text(msg.content).strip()
        if not text:
            continue

        # 跳过纯工具调用（没有文本输出的 assistant 消息）
        if msg.role == "assistant" and text.startswith("[Tool:") and "\n" not in text:
            if not include_tools:
                continue

        time_str = _fmt_ts(msg.timestamp)
        time_suffix = f" `{time_str}`" if time_str else ""

        if msg.role == "user":
            lines.append(f"### You{time_suffix}")
            lines.append(f"")
            lines.append(text)
            lines.append(f"")
        elif msg.role == "assistant":
            model = msg.model or ""
            model_suffix = f" ({model})" if model else ""
            lines.append(f"### Claude{model_suffix}{time_suffix}")
            lines.append(f"")
            lines.append(text)
            lines.append(f"")

    lines.append(f"---")
    lines.append(f"*Exported by [cc-statistics](https://github.com/androidZzT/cc-statistics)*")

    return "\n".join(lines)


def find_and_export(keyword: str, output: str | None = None,
                    include_tools: bool = False) -> str | None:
    """查找会话并导出

    Args:
        keyword: 会话 ID 前缀 或 搜索关键词
        output: 输出文件路径（None 则输出到 stdout）
        include_tools: 是否包含工具调用
    """
    # 搜索所有会话
    all_files = find_sessions()

    # 先按 session ID 前缀匹配
    matched = None
    for f in all_files:
        if f.stem.startswith(keyword):
            matched = f
            break

    # 再按内容搜索
    if not matched:
        for f in sorted(all_files, key=lambda p: p.stat().st_mtime, reverse=True):
            try:
                session = parse_jsonl(f)
                for msg in session.messages:
                    text = _extract_text(msg.content)
                    if keyword.lower() in text.lower():
                        matched = f
                        break
                if matched:
                    break
            except Exception:
                continue

    if not matched:
        return None

    session = parse_jsonl(matched)
    md = export_session(session, include_tools=include_tools)

    if output:
        Path(output).write_text(md, encoding="utf-8")
        return output
    return md
