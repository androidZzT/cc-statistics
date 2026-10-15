"""Activity state must remain readable across corrupt input and concurrent hooks."""

import concurrent.futures
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
from unittest.mock import patch

import pytest

import cc_stats.hooks as hooks


@pytest.fixture
def state_file(tmp_path, monkeypatch):
    monkeypatch.setattr(hooks.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(hooks, "_bridge_base_url", lambda: "")
    monkeypatch.setattr(hooks, "_publish_bridge_event", lambda **kwargs: None)
    state = tmp_path / ".cc-stats/activity-state.json"
    state.parent.mkdir()
    return state


def write_state(text="中文：状态"):
    hooks._write_activity_state(
        {"session_id": "test", "tool_input": {"command": text}}, "PreToolUse"
    )


@pytest.mark.parametrize("raw", [b'\x8c', b'{', b'[]', b'null'])
def test_corrupt_state_is_optional_context(state_file, raw):
    state_file.write_bytes(raw)
    assert hooks._read_existing_activity_state(state_file) == {}
    write_state()
    assert json.loads(state_file.read_text(encoding="utf-8"))["action"] == "中文：状态"


@pytest.mark.parametrize("failure", ["replace", "encoding", "create", "fsync"])
def test_failed_write_preserves_previous_state_and_cleans_temp(state_file, failure):
    write_state("original")
    original = state_file.read_bytes()
    if failure == "encoding":
        write_state("invalid surrogate \ud800")
    else:
        target = {"replace": "os.replace", "create": "tempfile.NamedTemporaryFile",
                  "fsync": "os.fsync"}[failure]
        with patch(f"cc_stats.hooks.{target}", side_effect=OSError("simulated failure")):
            write_state("replacement")
    assert state_file.read_bytes() == original
    assert not list(state_file.parent.glob(".activity-state.*.tmp"))


def test_replace_publishes_complete_file_in_same_directory(state_file):
    write_state("original")
    original = state_file.read_bytes()
    replace = os.replace

    def inspect_replace(source, destination):
        source = Path(source)
        assert source.parent == state_file.parent
        assert source != state_file
        assert state_file.read_bytes() == original
        assert json.loads(source.read_text(encoding="utf-8"))["action"] == "replacement"
        replace(source, destination)

    with patch("cc_stats.hooks.os.replace", side_effect=inspect_replace) as mocked:
        write_state("replacement")
    mocked.assert_called_once()
    assert json.loads(state_file.read_text())["action"] == "replacement"


def test_concurrent_writers_never_publish_partial_utf8_or_json(state_file):
    write_state()
    ready = threading.Event()
    finished = threading.Event()
    errors = []
    reads = []

    def reader():
        try:
            while not finished.is_set():
                json.loads(state_file.read_text(encoding="utf-8"))
                reads.append(1)
                ready.set()
        except Exception as error:
            errors.append(error)
            ready.set()

    thread = threading.Thread(target=reader)
    thread.start()
    try:
        assert ready.wait(5)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda n: write_state(f"并发中文：{n}" * 100), range(200)))
    finally:
        finished.set()
        thread.join(timeout=5)
    assert not thread.is_alive()
    assert reads
    assert not errors
    assert not list(state_file.parent.glob(".activity-state.*.tmp"))


@pytest.mark.parametrize("field", ["hook_event_name", "event"])
@pytest.mark.parametrize("event", ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"])
def test_hook_entrypoint_recovers_corruption_for_both_event_schemas(state_file, field, event):
    state_file.write_bytes(b'\x8c')
    payload = {field: event, "session_id": "test", "tool_name": "Bash",
               "tool_input": {"command": "true"}, "prompt": "test"}
    with patch("sys.stdin", io.StringIO(json.dumps(payload))), \
         patch("sys.stdout", new_callable=io.StringIO) as output, \
         patch("cc_stats.notifier.notify_session_complete"):
        hooks.main()
    if output.getvalue().strip():
        json.loads(output.getvalue())
    assert json.loads(state_file.read_text(encoding="utf-8"))["event"] == event


@pytest.mark.parametrize("fail_replace", [False, True])
def test_node_hook_uses_atomic_publish_and_cleans_temp(tmp_path, fail_replace):
    node = shutil.which("node")
    if not node:
        pytest.skip("node unavailable")
    script = Path(__file__).resolve().parents[1] / "hooks/ccstats-hook.js"
    state = tmp_path / ".cc-stats/activity-state.json"
    state.parent.mkdir()
    state.write_text('{"event":"original"}')
    # Execute the actual script with an instrumented rename, without external services.
    harness = r'''
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const target = process.env.TEST_STATE;
const rename = fs.renameSync;
let calls = 0;
fs.renameSync = (source, destination) => {
  calls++;
  assert.strictEqual(path.dirname(source), path.dirname(target));
  assert.notStrictEqual(source, target);
  assert.strictEqual(destination, target);
  assert.strictEqual(JSON.parse(fs.readFileSync(source, 'utf8')).event, 'PreToolUse');
  assert.strictEqual(JSON.parse(fs.readFileSync(target, 'utf8')).event, 'original');
  if (process.env.TEST_FAIL_REPLACE === '1') throw new Error('simulated failure');
  return rename(source, destination);
};
process.on('exit', () => assert.strictEqual(calls, 1));
process.argv = [process.execPath, process.env.TEST_SCRIPT, 'PreToolUse'];
require(process.env.TEST_SCRIPT);
'''
    result = subprocess.run(
        [node, "-e", harness], input='{"session_id":"中文测试"}', text=True,
        capture_output=True, timeout=10,
        env={**os.environ, "HOME": str(tmp_path), "TEST_STATE": str(state),
             "TEST_SCRIPT": str(script), "TEST_FAIL_REPLACE": "1" if fail_replace else "0"},
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    expected = "original" if fail_replace else "PreToolUse"
    assert json.loads(state.read_text(encoding="utf-8"))["event"] == expected
    assert not list(state.parent.glob(".activity-state.*.tmp"))
