"""AI PR Review — 调用 Claude API 审查 PR diff，输出 Markdown 报告"""

import argparse
import json
import os
import sys
import urllib.request

_API_URL = "https://api.anthropic.com/v1/messages"
_MODEL = "claude-sonnet-4-20250514"
_MAX_DIFF_CHARS = 80000  # 超长 diff 截断


def _call_claude(prompt: str) -> str:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    body = json.dumps({
        "model": _MODEL,
        "max_tokens": 4096,
        "messages": [{"role": "user", "content": prompt}],
    }).encode("utf-8")

    req = urllib.request.Request(
        _API_URL,
        data=body,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
            return data["content"][0]["text"]
    except Exception as e:
        print(f"Claude API error: {e}", file=sys.stderr)
        sys.exit(1)


def _build_prompt(diff: str, title: str, body: str) -> str:
    return f"""你是一个专业的代码审查员。请审查以下 Pull Request 的代码变更，输出中文 Markdown 格式的审查报告。

## PR 信息
- **标题**: {title}
- **描述**: {body or '无描述'}

## 代码变更 (diff)
```diff
{diff}
```

## 审查要求

请按以下格式输出审查报告：

### 📋 概要
简要描述 PR 的改动内容和目的（2-3 句话）。

### ✅ 优点
列出代码中做得好的地方（1-3 点）。

### ⚠️ 问题与建议
按严重程度分类：
- **🔴 必须修复**：Bug、安全漏洞、数据丢失风险
- **🟡 建议修改**：代码质量、性能、可维护性问题
- **🟢 可选优化**：风格、命名、文档等非阻塞建议

每个问题包含：文件名、行号（如果能确定）、问题描述、修复建议。

### 🏁 结论
给出明确建议：**建议合入** ✅ 或 **建议修改后合入** 🔄 或 **建议关闭** ❌

附上简短理由。

---
注意：
- 只关注 diff 中实际变更的代码，不要评论未改动的部分
- 关注实际影响，不要吹毛求疵
- 如果 diff 很小且改动合理，不要强行找问题"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--diff", required=True, help="Path to diff file")
    parser.add_argument("--title", default="", help="PR title")
    parser.add_argument("--body", default="", help="PR body")
    parser.add_argument("--output", required=True, help="Output markdown file")
    args = parser.parse_args()

    with open(args.diff, encoding="utf-8", errors="replace") as f:
        diff = f.read()

    if not diff.strip():
        with open(args.output, "w", encoding="utf-8") as f:
            f.write("No code changes to review.")
        return

    # 截断超长 diff
    if len(diff) > _MAX_DIFF_CHARS:
        diff = diff[:_MAX_DIFF_CHARS] + "\n\n... (diff truncated due to size)"

    prompt = _build_prompt(diff, args.title, args.body or "")
    review = _call_claude(prompt)

    # 包装输出
    output = f"## 🤖 AI Code Review\n\n{review}\n\n---\n*Powered by Claude Sonnet · cc-statistics*\n"

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(output)

    print(f"Review written to {args.output}")


if __name__ == "__main__":
    main()
