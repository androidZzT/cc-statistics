# Windows Tray MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows Tauri tray MVP that launches the Python `cc_stats_web` API, opens the dashboard, and keeps all statistics logic in Python.

**Architecture:** Add a Tauri app under `desktop/cc-stats-tauri/` as a platform shell. Add a structured Python web startup mode so the Tauri process manager can start the API without scraping localized human output. Keep macOS Swift code unchanged.

**Tech Stack:** Python 3.10+, pytest, Tauri 2.11, Rust, Vite, TypeScript, Node test runner.

---

## File Structure

- Modify `cc_stats_web/__main__.py`
  - Add `--no-browser` and `--json` flags.
  - Print one structured startup JSON line for desktop shells.

- Create `tests/test_web_entrypoint.py`
  - Covers startup payload formatting and CLI argument parsing without starting a blocking server.

- Create `desktop/cc-stats-tauri/`
  - Tauri app shell with tray/window/process modules.
  - Frontend dashboard wrapper that embeds the Python dashboard URL.
  - Node tests for frontend URL/status helpers.
  - Rust unit tests for command construction and startup URL parsing.

- Modify `README.md` and `README_CN.md`
  - Add a short Windows tray development note.

## Task 1: Python Structured Web Startup

- [ ] Write tests for `_build_startup_payload()` and `_parse_args()`.
- [ ] Run the new tests and confirm they fail because helpers do not exist.
- [ ] Add `main(argv=None)`, `--no-browser`, `--json`, `_build_startup_payload()`, `_parse_args()`.
- [ ] Run `python -m pytest tests/test_web_entrypoint.py tests/test_web_server.py -q`.

## Task 2: Tauri Frontend Shell

- [ ] Create `desktop/cc-stats-tauri/package.json`, Vite config, TypeScript config, and frontend files.
- [ ] Write Node tests for dashboard URL normalization and status label helpers.
- [ ] Run `npm test` and confirm helper tests pass.

## Task 3: Tauri Rust Shell

- [ ] Create `src-tauri/Cargo.toml`, `tauri.conf.json`, `build.rs`, and Rust modules.
- [ ] Implement:
  - API command construction: `python -m cc_stats_web --no-browser --json`.
  - Startup JSON parsing.
  - Health state enum.
  - Dashboard window open/focus command.
  - Tray menu commands: `Open Dashboard`, `Restart API`, `Quit`.
- [ ] Run `cargo test` if Rust is available.
- [ ] Run `cargo check` if Rust is available.

## Task 4: Docs and Verification

- [ ] Add Windows tray development notes to English and Chinese README files.
- [ ] Run full Python test suite.
- [ ] Run frontend Node tests.
- [ ] Run Rust tests/checks if toolchain is available.
- [ ] Run `git status` and confirm only intended source/docs files changed.

## Self-Review

**Spec coverage:** This plan covers the MVP design: Tauri shell, Python API process contract, tray/window basics, no macOS Swift edits, and no duplicated statistics logic.

**Placeholder scan:** No implementation placeholders remain; each task names concrete files and commands.

**Type consistency:** Python startup payload, frontend helpers, and Rust process parser all use the same `url`, `host`, and `port` fields.
