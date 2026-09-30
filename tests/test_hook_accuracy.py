"""Regression coverage for hook notification false positives across consumers."""
import json
import os
from pathlib import Path
import shutil
import subprocess
from unittest.mock import patch

import pytest

from cc_stats.hooks import process_hook_event
from cc_stats.bridge.collector import _extract_approval

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('metadata', [
    {'permission_mode': 'bypassPermissions'},
    {'permissionMode': ' bypass-permissions '},
    {'meta': {'permissionMode': 'bypass_permissions'}},
    {'permissions': {'mode': 'bypassPermissions'}},
])
def test_bypass_metadata_is_consistent(tmp_path, metadata):
    event = {'event': 'PermissionRequest', 'tool_name': 'Read', **metadata}
    with patch('cc_stats.hooks.Path.home', return_value=tmp_path), \
         patch('cc_stats.hooks._publish_bridge_event'), \
         patch('cc_stats.hooks._wait_bridge_approval_decision') as wait:
        process_hook_event(event)
    wait.assert_not_called()
    assert _extract_approval(event) is None
    state = json.loads((tmp_path / '.cc-stats/activity-state.json').read_text())
    assert state['approval_required'] is False


@pytest.mark.parametrize('event, metadata, expected', [
    ('PermissionRequest', {}, True),
    ('PermissionRequest', {'permissions': {'mode': 'bypassPermissions'}}, False),
    ('PreToolUse', {}, False),
    ('PostToolUse', {}, False),
    ('PermissionDenied', {}, False),
    ('Notification', {'notification_type': 'idle_prompt'}, False),
])
def test_node_hook(tmp_path, event, metadata, expected):
    node = shutil.which('node')
    if not node:
        pytest.skip('node unavailable')
    subprocess.run([node, str(ROOT / 'hooks/ccstats-hook.js'), event],
                   input=json.dumps(metadata), text=True, check=True,
                   env={**os.environ, 'HOME': str(tmp_path)})
    state = json.loads((tmp_path / '.cc-stats/activity-state.json').read_text())
    assert state['approval_required'] is expected
    if metadata.get('notification_type') == 'idle_prompt':
        assert state['state'] == 'idle'


def test_explicit_non_pending_event_does_not_create_bridge_approval():
    assert _extract_approval({'event': 'PermissionRequest', 'approval_required': False}) is None
    assert _extract_approval({'event': 'PermissionRequest', 'permission_mode': 'default'})


def test_resolved_hook_does_not_overwrite_newer_activity(tmp_path):
    state_file = tmp_path / '.cc-stats/activity-state.json'
    def newer_activity(_):
        state_file.write_text(json.dumps({'event': 'PreToolUse', 'timestamp': 42}))
        return True, ''
    with patch('cc_stats.hooks.Path.home', return_value=tmp_path), \
         patch('cc_stats.hooks._publish_bridge_event'), \
         patch('cc_stats.hooks._wait_bridge_approval_decision', side_effect=newer_activity):
        process_hook_event({'event': 'PermissionRequest', 'tool_use_id': 'old'})
    assert json.loads(state_file.read_text()) == {'event': 'PreToolUse', 'timestamp': 42}


def test_swift_approval_state(tmp_path):
    swiftc = shutil.which('swiftc')
    if not swiftc:
        pytest.skip('swiftc unavailable')
    main = tmp_path / 'main.swift'
    main.write_text('''
import Foundation
let thresholds = SessionActivityMonitor.Thresholds()
func state(_ event: String, _ required: Bool?, _ timestamp: Double = 1000000) -> SessionActivityState {
    SessionActivityMonitor.evaluateState(hookState: "active", hookEvent: event,
        hookTimestamp: timestamp, now: 1000, thresholds: thresholds, approvalRequired: required)
}
precondition(state("PermissionRequest", true) == .waitingApproval)
precondition(state("PermissionRequest", false) == .active)
precondition(state("PreToolUse", nil) == .active)
precondition(state("PermissionDenied", nil) == .active)
precondition(state("PermissionRequest", true, 600000) == .idle)
precondition(state("PermissionRequest", true, 1100000) != .waitingApproval)
''')
    binary = tmp_path / 'monitor-tests'
    subprocess.run([swiftc, str(ROOT / 'cc_stats_app/swift/SessionActivityMonitor.swift'),
                    str(main), '-o', str(binary)], check=True, capture_output=True)
    subprocess.run([str(binary)], check=True)
