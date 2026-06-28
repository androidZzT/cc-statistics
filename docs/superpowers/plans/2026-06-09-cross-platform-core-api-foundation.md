# Cross-Platform Core API Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the cross-platform Python core and local API foundation that a Windows tray app can consume without duplicating parser/analyzer logic.

**Architecture:** Introduce one source/provider registry for Claude, Codex, and Gemini session discovery, then refactor CLI and Web API to use it. This keeps platform path rules, source filtering, and parser selection in one place so macOS Swift, future Windows tray, and Web UI can converge on the same local API.

**Tech Stack:** Python 3.10+ standard library, existing `cc_stats.parser` and `cc_stats.analyzer`, pytest, current static HTML/JS dashboard.

---

## Scope

This plan delivers the core/API foundation for Windows tray support:

- One Python source registry for Claude, Codex, and Gemini.
- Environment-variable path overrides for cross-platform testing and future Windows paths.
- CLI list/default/all flows using the registry.
- Web dashboard API using the registry, including Codex support and real source filtering.
- Tests that prove Codex appears in Web/API output and filtering works.

The Windows tray shell itself should be implemented in a follow-up plan after this foundation lands. That follow-up should choose Tauri or Electron and consume the local API created here.

## File Structure

- Create `cc_stats/sources.py`
  - Defines `SourceKind`, `SourceProject`, source discovery helpers, and registry helpers.
  - Owns environment overrides and session file discovery for all file-backed sources.

- Modify `cc_stats/parser.py`
  - Adds optional home/path parameters for source discovery helpers while preserving existing public behavior.
  - Keeps parsing logic unchanged.

- Modify `cc_stats/cli.py`
  - Replaces scattered source discovery for list/default/all/report-adjacent flows with `cc_stats.sources`.
  - Keeps user-visible commands stable.

- Modify `cc_stats_web/server.py`
  - Replaces local Claude/Gemini-only discovery with the source registry.
  - Adds `source` query support for `/api/projects`, `/api/stats`, `/api/daily_stats`, and `/api/skills`.
  - Uses `cc_stats.pricing` instead of private duplicate pricing logic when possible.

- Modify `cc_stats_web/web/index.html`
  - Sends selected source to API calls, not only to client-side project filtering.
  - Shows Codex project tags consistently.

- Create `tests/test_sources.py`
  - Covers provider discovery, project grouping, source filtering, and env path overrides.

- Modify `tests/test_web_server.py`
  - Adds Codex-backed API tests and source-filter tests.

---

### Task 1: Add Source Registry Contract

**Files:**
- Create: `cc_stats/sources.py`
- Create: `tests/test_sources.py`

- [ ] **Step 1: Write failing source registry tests**

Create tests proving:

- `collect_session_files(source=SourceKind.ALL)` includes Codex sessions.
- `list_projects(source=SourceKind.CODEX)` groups Codex sessions by `cwd`.
- `collect_session_files(source=SourceKind.CODEX)` excludes Gemini and Claude sessions.
- Env path overrides do not require real home-directory data.

Use synthetic `tmp_path` fixtures and monkeypatch:

- `CC_STATS_CLAUDE_PROJECTS_DIR`
- `CC_STATS_CODEX_HOME`
- `CC_STATS_GEMINI_HOME`

- [ ] **Step 2: Run tests to verify they fail**

```bash
python -m pytest tests/test_sources.py -q
```

Expected: FAIL with `ModuleNotFoundError: No module named 'cc_stats.sources'`.

- [ ] **Step 3: Implement `cc_stats/sources.py`**

Create a unified source registry with:

```python
class SourceKind(str, Enum):
    ALL = "all"
    CLAUDE = "claude"
    CODEX = "codex"
    GEMINI = "gemini"


@dataclass(frozen=True)
class SourceProject:
    source: SourceKind
    key: str
    display_name: str
    session_count: int
    last_modified: float
```

Implement:

- `normalize_source(source)`
- `active_sources(source)`
- `collect_session_files(source=None, project_dir=None)`
- `list_projects(source=None)`
- `parse_file(path)`

Provider behavior:

- Claude uses `find_sessions(project_dir, projects_dir=claude_projects_dir())`.
- Codex uses `find_codex_sessions(project_dir, codex_home_dir=codex_home())`.
- Gemini uses `find_gemini_sessions(gemini_home_dir=gemini_home())`.
- Project listing groups Codex/Gemini by parsed `session.project_path`.
- Claude project listing preserves existing project directory behavior but resolves display name from session data where available.

- [ ] **Step 4: Run tests and observe the next failure**

```bash
python -m pytest tests/test_sources.py -q
```

Expected: FAIL because parser discovery helpers do not yet accept the new keyword arguments.

---

### Task 2: Add Path Overrides to Existing Parsers

**Files:**
- Modify: `cc_stats/parser.py`
- Test: `tests/test_sources.py`

- [ ] **Step 1: Update parser discovery signatures**

Add keyword-only override parameters while preserving default behavior:

```python
def find_sessions(
    project_dir: Path | None = None,
    *,
    projects_dir: Path | None = None,
) -> list[Path]:
```

```python
def find_sessions_by_keyword(
    keyword: str,
    *,
    projects_dir: Path | None = None,
) -> list[Path]:
```

```python
def find_codex_sessions(
    project_dir: Path | None = None,
    *,
    codex_home_dir: Path | None = None,
) -> list[Path]:
```

```python
def find_codex_sessions_by_keyword(
    keyword: str,
    *,
    codex_home_dir: Path | None = None,
) -> list[Path]:
```

```python
def find_gemini_sessions(
    *,
    gemini_home_dir: Path | None = None,
) -> list[Path]:
```

```python
def find_gemini_sessions_by_keyword(
    keyword: str,
    *,
    gemini_home_dir: Path | None = None,
) -> list[Path]:
```

- [ ] **Step 2: Run source tests**

```bash
python -m pytest tests/test_sources.py -q
```

Expected: PASS.

- [ ] **Step 3: Run parser regression tests**

```bash
python -m pytest tests/test_codex_parser.py tests/test_subagent_sessions.py -q
```

Expected: PASS.

---

### Task 3: Refactor CLI to Use Source Registry

**Files:**
- Modify: `cc_stats/cli.py`
- Test: `tests/test_sources.py`

- [ ] **Step 1: Add CLI source-list regression test**

Add a test documenting the CLI-facing project shape:

```python
assert [(p.source.value, Path(p.display_name).name, p.session_count) for p in projects] == [
    ("codex", "demo", 1)
]
```

- [ ] **Step 2: Replace CLI imports**

Import from the registry:

```python
from .sources import SourceKind, collect_session_files, list_projects, parse_file
```

Keep keyword-search parser imports until they are folded into the registry.

- [ ] **Step 3: Replace `_parse_session`**

```python
def _parse_session(path: Path):
    return parse_file(path)
```

- [ ] **Step 4: Replace `_list_projects`**

Use `list_projects()` and group display by:

- Claude Code
- Codex
- Gemini CLI

- [ ] **Step 5: Replace main session collection paths**

Use:

```python
session_files = collect_session_files()
session_files = collect_session_files(project_dir=Path.cwd())
session_files = collect_session_files(project_dir=p)
```

depending on the existing branch.

- [ ] **Step 6: Replace rate-limit and git collection**

Use:

```python
session_files: list[Path] = collect_session_files()
```

- [ ] **Step 7: Run CLI-related tests**

```bash
python -m pytest tests/test_sources.py tests/test_cli_version.py tests/test_codex_parser.py -q
```

Expected: PASS.

- [ ] **Step 8: Manual smoke test**

```bash
python -m cc_stats.cli --list
python -m cc_stats.cli --all --since 1d
```

Expected: `--list` still groups sources; `--all` still returns a stats report.

---

### Task 4: Refactor Web API to Use Source Registry and Add Codex

**Files:**
- Modify: `cc_stats_web/server.py`
- Test: `tests/test_web_server.py`

- [ ] **Step 1: Add failing Web API tests**

Add tests proving:

- `_get_projects(source="codex")` returns Codex projects.
- `_collect_session_files(source="codex")` returns Codex files.
- `_get_stats(source="codex")` parses Codex token usage.
- Non-Codex source filters exclude Codex sessions.

- [ ] **Step 2: Run tests to verify they fail**

```bash
python -m pytest tests/test_web_server.py::test_web_projects_include_codex tests/test_web_server.py::test_web_stats_source_filter_uses_codex -q
```

Expected: FAIL because Web server does not accept `source` and does not include Codex.

- [ ] **Step 3: Replace Web parser imports and pricing**

Use:

```python
from cc_stats.parser import parse_session_file
from cc_stats.sources import collect_session_files, list_projects
```

If pricing can be cleanly shared, route cost calculation through `cc_stats.pricing`; otherwise leave pricing unchanged and avoid scope creep.

- [ ] **Step 4: Replace `_get_projects`**

```python
def _get_projects(source: str | None = None):
    return [
        {
            "dir_name": project.key,
            "display_name": project.display_name,
            "session_count": project.session_count,
            "source": project.source.value,
        }
        for project in list_projects(source=source)
    ]
```

- [ ] **Step 5: Replace `_collect_session_files`**

```python
def _collect_session_files(project_dir_name=None, source: str | None = None):
    files = collect_session_files(source=source)
    if not project_dir_name:
        return files

    filtered = []
    for path in files:
        try:
            session = parse_session_file(path)
        except Exception:
            continue
        if session.project_path == project_dir_name:
            filtered.append(path)
    return filtered
```

- [ ] **Step 6: Replace `_parse_session_file`**

```python
def _parse_session_file(f):
    return parse_session_file(f)
```

- [ ] **Step 7: Add `source` parameter to stats helpers**

Add `source: str | None = None` to:

- `_get_stats`
- `_get_daily_stats`
- `_get_skill_stats`

Pass it into `_collect_session_files`.

- [ ] **Step 8: Wire `source` through HTTP endpoints**

Read:

```python
source = params.get("source", [None])[0]
```

Pass it through `/api/projects`, `/api/stats`, `/api/daily_stats`, and `/api/skills`.

- [ ] **Step 9: Run Web tests**

```bash
python -m pytest tests/test_web_server.py -q
```

Expected: PASS.

---

### Task 5: Send Source Filter from Web UI

**Files:**
- Modify: `cc_stats_web/web/index.html`

- [ ] **Step 1: Modify `loadProjects` to request source**

```javascript
allProjects = await api('/api/projects', { source: currentSource || null });
```

- [ ] **Step 2: Modify `loadStats` API calls**

Include `source: currentSource || null` in calls to:

- `/api/stats`
- `/api/daily_stats`
- `/api/skills`

- [ ] **Step 3: Simplify project select rendering**

Because the backend now filters sources, remove duplicate client-side filtering.

- [ ] **Step 4: Render project source tags**

Use:

```javascript
const tag = p.source === 'gemini'
  ? ' [G]'
  : p.source === 'codex'
    ? ' [C]'
    : p.source === 'claude'
      ? ' [Claude]'
      : '';
```

- [ ] **Step 5: Reload projects when source changes**

Make the source-select listener async:

```javascript
document.getElementById('source-select').addEventListener('change', async e => {
  currentSource = e.target.value;
  currentProject = '';
  await loadProjects();
  loadStats();
});
```

- [ ] **Step 6: Manual Web smoke test**

```bash
python -m cc_stats_web
```

Expected:

- Selecting `Codex` shows Codex projects.
- `All Sources` includes Codex sessions in aggregate metrics.
- Selecting `Gemini CLI` excludes Codex sessions.

---

### Task 6: Add Platform Path Documentation and Guardrails

**Files:**
- Modify: `README_CN.md`
- Modify: `README.md`
- Test: `tests/test_sources.py`

- [ ] **Step 1: Add env override test**

```python
def test_env_overrides_do_not_require_real_home(tmp_path, monkeypatch):
    monkeypatch.setenv("CC_STATS_CLAUDE_PROJECTS_DIR", str(tmp_path / "claude-projects"))
    monkeypatch.setenv("CC_STATS_CODEX_HOME", str(tmp_path / "codex-home"))
    monkeypatch.setenv("CC_STATS_GEMINI_HOME", str(tmp_path / "gemini-home"))

    assert collect_session_files() == []
    assert list_projects() == []
```

- [ ] **Step 2: Update README path override sections**

In `README_CN.md`, add:

```markdown
### 路径覆盖（跨平台 / 测试）

默认路径来自当前用户 home 目录。需要在 Windows、WSL、便携安装或测试环境中指定数据目录时，可以设置：

| 环境变量 | 作用 |
|----------|------|
| `CC_STATS_CLAUDE_PROJECTS_DIR` | 覆盖 Claude Code 项目日志目录 |
| `CC_STATS_CODEX_HOME` | 覆盖 Codex home，工具会读取其中的 `sessions/` |
| `CC_STATS_GEMINI_HOME` | 覆盖 Gemini home，工具会读取其中的 `tmp/*/chats/` |
```

In `README.md`, add:

```markdown
### Path Overrides (Cross-Platform / Testing)

Default paths are resolved from the current user's home directory. For Windows, WSL, portable installs, or tests, set:

| Environment Variable | Purpose |
|----------------------|---------|
| `CC_STATS_CLAUDE_PROJECTS_DIR` | Override the Claude Code project log directory |
| `CC_STATS_CODEX_HOME` | Override Codex home; `sessions/` is read below it |
| `CC_STATS_GEMINI_HOME` | Override Gemini home; `tmp/*/chats/` is read below it |
```

- [ ] **Step 3: Run source and web tests**

```bash
python -m pytest tests/test_sources.py tests/test_web_server.py -q
```

Expected: PASS.

---

### Task 7: Final Verification for Foundation

**Files:**
- No source edits unless verification finds a failure.

- [ ] **Step 1: Run focused Python tests**

```bash
python -m pytest tests/test_sources.py tests/test_web_server.py tests/test_codex_parser.py tests/test_cli_version.py -q
```

Expected: PASS.

- [ ] **Step 2: Run CLI smoke tests**

```bash
python -m cc_stats.cli --list
python -m cc_stats.cli --all --since 1d
```

Expected:

- `--list` shows Claude/Codex/Gemini groups when data exists.
- `--all --since 1d` generates a report and includes current Codex sessions.

- [ ] **Step 3: Run Web API smoke check**

```bash
python -m cc_stats_web
```

Open the printed local URL and verify:

- `All Sources` totals include Codex.
- `Codex` source filter shows Codex-only metrics.
- `Gemini CLI` source filter does not show Codex metrics.

- [ ] **Step 4: Inspect for duplicate source discovery**

```bash
rg -n "find_sessions\\(|find_codex_sessions\\(|find_gemini_sessions\\(" cc_stats cc_stats_web
```

Expected:

- `cc_stats/parser.py` still defines discovery helpers.
- `cc_stats/sources.py` calls those helpers.
- CLI/Web should not manually combine all three sources outside `cc_stats/sources.py`.

---

## Follow-Up Plan: Windows Tray Shell

After this foundation passes, create a second plan for `cc-stats-desktop`:

- Choose Tauri or Electron.
- Launch/monitor the Python local API.
- Implement Windows tray menu and icon states.
- Implement toast notifications through Windows APIs.
- Implement global hotkey.
- Implement launch-at-login.
- Consume `/api/projects`, `/api/stats`, `/api/daily_stats`, `/api/skills`, and bridge `/v1/*` endpoints.
- Package Windows artifacts in CI.

The second plan should not duplicate parser/analyzer logic. It should treat Python core/API as the product kernel and the desktop shell as a thin platform adapter.

---

## Self-Review

**Spec coverage:** This plan covers the cross-platform abstraction foundation needed for Windows tray development: source discovery, platform path overrides, CLI consistency, Web API parity, and Codex support. The actual Windows tray shell is explicitly separated into a follow-up plan because it is an independent subsystem.

**Placeholder scan:** No `TBD`, `TODO`, or vague implementation steps remain. Each code-changing step includes concrete behavior, exact files, or replacement snippets.

**Type consistency:** The plan uses `SourceKind`, `SourceProject`, `collect_session_files`, `list_projects`, and `parse_file` consistently across CLI and Web tasks.
