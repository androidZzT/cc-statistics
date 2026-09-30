#!/usr/bin/env python3
"""Safe GitHub PR/Issue triage for cc-statistics.

This script is intentionally conservative:
- It reads PR/Issue metadata through the GitHub API.
- It does not checkout or execute fork PR code.
- It comments a deterministic review/triage summary.
- `/cc fix` is a safe command stub by default; code changes remain maintainer-driven.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

API_ROOT = "https://api.github.com"
PR_MARKER = "<!-- cc-stats-ai-triage:pr-review -->"
ISSUE_MARKER = "<!-- cc-stats-ai-triage:issue-triage -->"
COMMAND_MARKER = "<!-- cc-stats-ai-triage:command -->"
SUPPORTED_COMMANDS = {"review", "triage", "plan", "fix"}
MAINTAINER_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}


@dataclass(frozen=True)
class GitHubContext:
    repo: str
    event_name: str
    token: str


class GitHubClient:
    def __init__(self, context: GitHubContext) -> None:
        self.context = context

    def request(self, method: str, path_or_url: str, data: dict[str, Any] | None = None) -> Any:
        url = path_or_url if path_or_url.startswith("https://") else f"{API_ROOT}{path_or_url}"
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "api.github.com":
            raise ValueError("Only the GitHub API is allowed")
        body = None if data is None else json.dumps(data).encode("utf-8")
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        request.add_header("User-Agent", "cc-statistics-ai-triage")
        if self.context.token:
            request.add_header("Authorization", f"Bearer {self.context.token}")
        if body is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitHub API {method} {url} failed: {exc.code} {detail}") from exc
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    def get(self, path_or_url: str) -> Any:
        return self.request("GET", path_or_url)

    def post(self, path_or_url: str, data: dict[str, Any]) -> Any:
        return self.request("POST", path_or_url, data)

    def patch(self, path_or_url: str, data: dict[str, Any]) -> Any:
        return self.request("PATCH", path_or_url, data)

    def list_pr_files(self, pr_number: int) -> list[dict[str, Any]]:
        files: list[dict[str, Any]] = []
        page = 1
        while True:
            path = f"/repos/{self.context.repo}/pulls/{pr_number}/files?per_page=100&page={page}"
            chunk = self.get(path)
            if not chunk:
                break
            files.extend(chunk)
            if len(chunk) < 100:
                break
            page += 1
        return files

    def issue_comments(self, issue_number: int) -> list[dict[str, Any]]:
        comments: list[dict[str, Any]] = []
        page = 1
        while True:
            path = f"/repos/{self.context.repo}/issues/{issue_number}/comments?per_page=100&page={page}"
            chunk = self.get(path)
            if not chunk:
                break
            comments.extend(chunk)
            if len(chunk) < 100:
                break
            page += 1
        return comments

    def upsert_issue_comment(self, issue_number: int, marker: str, body: str) -> None:
        full_body = body if marker in body else f"{marker}\n{body}"
        for comment in self.issue_comments(issue_number):
            if ((comment.get("user") or {}).get("login") == "github-actions[bot]"
                    and marker in (comment.get("body") or "")):
                self.patch(comment["url"], {"body": full_body})
                return
        self.post(f"/repos/{self.context.repo}/issues/{issue_number}/comments", {"body": full_body})


def parse_cc_command(body: str | None) -> str | None:
    if not body:
        return None
    match = re.search(r"(?im)^\s*/cc\s+([a-z-]+)\b", body)
    if not match:
        return None
    command = match.group(1).lower()
    return command if command in SUPPORTED_COMMANDS else None


def is_maintainer_association(association: str | None) -> bool:
    return (association or "").upper() in MAINTAINER_ASSOCIATIONS


def _login(user: dict[str, Any] | None) -> str:
    return (user or {}).get("login") or "unknown"


def _file_summary(files: list[dict[str, Any]]) -> tuple[int, int, int]:
    additions = sum(int(f.get("additions") or 0) for f in files)
    deletions = sum(int(f.get("deletions") or 0) for f in files)
    changes = sum(int(f.get("changes") or 0) for f in files)
    return additions, deletions, changes


def _changed_paths(files: list[dict[str, Any]]) -> list[str]:
    return [str(f.get("filename") or "") for f in files]


def _path_has(paths: list[str], *needles: str) -> bool:
    return any(any(needle in path for needle in needles) for path in paths)


def _path_ext(paths: list[str], *suffixes: str) -> bool:
    return any(path.endswith(suffixes) for path in paths)


def _suggested_tests(paths: list[str]) -> list[str]:
    tests = []
    if _path_ext(paths, ".py"):
        tests.append("`pytest -q`")
    if _path_ext(paths, ".swift"):
        tests.append("`swiftc $(find cc_stats_app/swift -name '*.swift' -print) -o /tmp/CCStats-check -target $(uname -m)-apple-macosx12.0 -framework Cocoa -framework SwiftUI -framework Carbon -framework UserNotifications -framework WebKit -lsqlite3 -O`")
    if _path_has(paths, "package.json", "desktop/", "tauri"):
        tests.append("`npm test` / `npm run build:web` where applicable")
    if _path_has(paths, "Cargo.toml", "Cargo.lock", "src-tauri"):
        tests.append("`cargo test` and `cargo check`")
    if _path_has(paths, ".github/workflows/"):
        tests.append("Review workflow permissions and fork-PR safety manually")
    return tests or ["Run the narrow tests for the touched area, then a smoke test of the app"]


def _risk_notes(pr: dict[str, Any], files: list[dict[str, Any]]) -> list[str]:
    paths = _changed_paths(files)
    additions, deletions, changes = _file_summary(files)
    notes: list[str] = []

    head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name")
    base_repo = ((pr.get("base") or {}).get("repo") or {}).get("full_name")
    if head_repo and base_repo and head_repo != base_repo:
        notes.append("cross-repository PR: do not execute fork code with repository secrets")
    if pr.get("mergeable") is False:
        notes.append("merge conflicts reported by GitHub; maintainer intervention is needed before merge")
    if len(files) > 25 or changes > 1500:
        notes.append(f"large change set: {len(files)} files, +{additions}/-{deletions}")
    if _path_has(paths, ".github/workflows/"):
        notes.append("Workflow changes detected: review token permissions, `pull_request_target`, and secret exposure")
    if _path_has(paths, "scripts/"):
        notes.append("Script changes detected: check shell/command injection and path handling")
    if _path_has(paths, "parser", "CodexParser", "SessionParser", "GeminiParser"):
        notes.append("Parser changes detected: verify malformed/partial session files do not crash loading")
    if _path_has(paths, "pricing"):
        notes.append("Pricing changes detected: verify official source and cached-token semantics")
    if _path_has(paths, "cc_stats_app/swift/"):
        notes.append("macOS app changes detected: compile Swift and smoke-test menu bar startup")
    return notes or ["No high-risk file patterns detected by the rule-based pass"]


def build_pr_review(pr: dict[str, Any], files: list[dict[str, Any]]) -> str:
    paths = _changed_paths(files)
    additions, deletions, changes = _file_summary(files)
    risks = _risk_notes(pr, files)
    tests = _suggested_tests(paths)
    title = pr.get("title") or "Untitled PR"
    number = pr.get("number") or "?"
    author = _login(pr.get("user"))
    url = pr.get("html_url") or ""

    changed_preview = "\n".join(f"- `{path}`" for path in paths[:12])
    if len(paths) > 12:
        changed_preview += f"\n- ... and {len(paths) - 12} more files"

    return f"""{PR_MARKER}
## CCStats automated PR review

**PR:** #{number} {title}

**Author:** @{author}

**URL:** {url}

### Change size
- Files: {len(files)}
- Additions/deletions: +{additions}/-{deletions}
- Total changed lines: {changes}

### Risk notes
{chr(10).join(f'- {note}' for note in risks)}

### Suggested verification
{chr(10).join(f'- {test}' for test in tests)}

### Changed files preview
{changed_preview or '- No files reported by GitHub'}

### Safe automation status
- This workflow only inspects metadata and patches from the base repository context.
- It does **not** checkout or execute fork PR code.
- Use `/cc review` to refresh this review.
- Use `/cc fix` to request a maintainer-driven fix plan; code is not pushed automatically.
""".strip()


def _issue_kind(title: str, body: str) -> tuple[str, list[str]]:
    text = f"{title}\n{body}".lower()
    labels: list[str] = []
    if any(word in text for word in ["bug", "crash", "error", "wrong", "不准", "崩", "报错", "失败"]):
        labels.append("bug")
    if any(word in text for word in ["feature", "support", "add", "希望", "支持", "新增"]):
        labels.append("feature")
    if any(word in text for word in ["pricing", "price", "cost", "token", "费用", "价格", "用量"]):
        labels.append("pricing/token")
    if any(word in text for word in ["island", "灵动岛", "notch"]):
        labels.append("macOS island")
    if any(word in text for word in ["parser", "session", "jsonl", "codex", "claude", "gemini", "会话"]):
        labels.append("parser/session")
    if any(word in text for word in ["windows", "tauri"]):
        labels.append("windows")
    if not labels:
        labels.append("needs-triage")
    return labels[0], labels


def build_issue_triage(issue: dict[str, Any]) -> str:
    title = issue.get("title") or "Untitled issue"
    body = issue.get("body") or ""
    number = issue.get("number") or "?"
    author = _login(issue.get("user"))
    kind, labels = _issue_kind(title, body)

    requested = [
        "reproduction steps or a minimal sample session file",
        "expected vs actual behavior",
        "logs/screenshots if this is UI or startup related",
        "OS, install method, and `cc-stats --version` / `cc-stats-app --version`",
    ]
    if "pricing/token" in labels:
        requested.append("model name and the raw token fields shown in the session log")
    if "windows" in labels:
        requested.append("Windows version plus Tauri/runtime logs if available")

    return f"""{ISSUE_MARKER}
## CCStats automated issue triage

**Issue:** #{number} {title}

**Author:** @{author}

**Detected type:** `{kind}`

**Suggested labels:** {', '.join(f'`{label}`' for label in labels)}

### Information that will help resolve this
{chr(10).join(f'- {item}' for item in requested)}

### Next actions
- Maintainers can use `/cc plan` to ask for an implementation plan.
- Maintainers can use `/cc fix` to request a safe fix workflow.
- This bot does not push code automatically without maintainer action.
""".strip()


def build_fix_command_response(number: int, is_pr: bool) -> str:
    target = "PR" if is_pr else "issue"
    return f"""{COMMAND_MARKER}
## `/cc fix` received for {target} #{number}

For safety, this workflow does **not push code automatically** from GitHub Actions.

Recommended maintainer flow:
1. Reproduce or confirm the issue locally.
2. Ask Codex to implement the fix from a clean branch.
3. Run the relevant tests.
4. Push a maintainer-owned PR or comment with the patch plan.

This keeps fork PRs and issue reports from gaining code-execution access to repository secrets.
""".strip()


def build_plan_command_response(number: int, is_pr: bool) -> str:
    target = "PR" if is_pr else "issue"
    return f"""{COMMAND_MARKER}
## `/cc plan` received for {target} #{number}

Suggested safe workflow:
- inspect the reported behavior or diff
- identify affected parser/app/web/release areas
- write or update a focused regression test
- implement the smallest fix
- run local verification before publishing changes

Use `/cc review` on PRs or `/cc triage` on issues to refresh automated context.
""".strip()


def build_maintainer_required_response(command: str) -> str:
    return f"""{COMMAND_MARKER}
`/cc {command}` requires a maintainer comment (`OWNER`, `MEMBER`, or `COLLABORATOR`).

This keeps repository automation from being driven by arbitrary external comments.
""".strip()


def _load_event() -> dict[str, Any]:
    path = os.environ.get("GITHUB_EVENT_PATH")
    if not path:
        raise RuntimeError("GITHUB_EVENT_PATH is not set")
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _context() -> GitHubContext:
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not repo:
        raise RuntimeError("GITHUB_REPOSITORY is not set")
    return GitHubContext(
        repo=repo,
        event_name=os.environ.get("GITHUB_EVENT_NAME", ""),
        token=os.environ.get("GITHUB_TOKEN", ""),
    )


def _handle_pull_request(client: GitHubClient, payload: dict[str, Any]) -> None:
    pr = payload["pull_request"]
    files = client.list_pr_files(int(pr["number"]))
    body = build_pr_review(pr, files)
    client.upsert_issue_comment(int(pr["number"]), PR_MARKER, body)


def _handle_issue(client: GitHubClient, payload: dict[str, Any]) -> None:
    issue = payload["issue"]
    if issue.get("pull_request"):
        return
    body = build_issue_triage(issue)
    client.upsert_issue_comment(int(issue["number"]), ISSUE_MARKER, body)


def _handle_issue_comment(client: GitHubClient, payload: dict[str, Any]) -> None:
    command = parse_cc_command((payload.get("comment") or {}).get("body"))
    if command is None:
        print("No supported /cc command found; skipping.")
        return

    issue = payload["issue"]
    number = int(issue["number"])
    is_pr = bool(issue.get("pull_request"))
    association = ((payload.get("comment") or {}).get("author_association") or "").upper()

    if command == "review" and is_pr:
        pr = client.get(f"/repos/{client.context.repo}/pulls/{number}")
        files = client.list_pr_files(number)
        client.upsert_issue_comment(number, PR_MARKER, build_pr_review(pr, files))
        return
    if command == "triage" and not is_pr:
        client.upsert_issue_comment(number, ISSUE_MARKER, build_issue_triage(issue))
        return
    if command in {"plan", "fix"} and not is_maintainer_association(association):
        client.upsert_issue_comment(number, COMMAND_MARKER, build_maintainer_required_response(command))
        return
    if command == "plan":
        client.upsert_issue_comment(number, COMMAND_MARKER, build_plan_command_response(number, is_pr))
        return
    if command == "fix":
        client.upsert_issue_comment(number, COMMAND_MARKER, build_fix_command_response(number, is_pr))
        return

    client.upsert_issue_comment(
        number,
        COMMAND_MARKER,
        f"{COMMAND_MARKER}\n`/cc {command}` is not valid for this target.",
    )


def main() -> int:
    payload = _load_event()
    context = _context()
    client = GitHubClient(context)

    if context.event_name == "pull_request_target":
        _handle_pull_request(client, payload)
    elif context.event_name == "issues":
        _handle_issue(client, payload)
    elif context.event_name == "issue_comment":
        _handle_issue_comment(client, payload)
    elif context.event_name == "workflow_dispatch":
        # Manual reruns are intentionally no-op until a target URL mode is added.
        print("workflow_dispatch received; no target-specific action configured.")
    else:
        print(f"Unsupported event {context.event_name}; skipping.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 - keep workflow error visible
        print(f"error: {exc}", file=sys.stderr)
        raise
