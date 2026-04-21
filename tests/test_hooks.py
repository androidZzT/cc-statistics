"""hooks 模块的单元测试 — 覆盖 hook 命令查找、安装/卸载、匹配逻辑"""

from __future__ import annotations

import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch

from cc_stats.hooks import (
    _bridge_base_url,
    get_hook_command,
    install_hooks,
    process_hook_event,
    uninstall_hooks,
    _hook_matches,
    _hook_exists,
)


class TestGetHookCommand(unittest.TestCase):
    """get_hook_command() — 优先使用 entry-point binary"""

    @patch("cc_stats.hooks.shutil.which", return_value="/usr/local/bin/cc-stats-hooks")
    def test_returns_entry_point_when_found(self, mock_which):
        result = get_hook_command()
        assert result == "/usr/local/bin/cc-stats-hooks"
        mock_which.assert_called_once_with("cc-stats-hooks")

    @patch("cc_stats.hooks.shutil.which", return_value=None)
    def test_fallback_to_python_m_when_not_found(self, mock_which):
        result = get_hook_command()
        assert "python" in result
        assert "-m cc_stats.hooks" in result

    @patch("cc_stats.hooks.shutil.which", return_value="/home/user/.local/bin/cc-stats-hooks")
    def test_returns_absolute_path(self, mock_which):
        result = get_hook_command()
        assert result.startswith("/")


class TestHookMatches(unittest.TestCase):
    """_hook_matches() — 兼容新旧两种 hook 命令格式"""

    def test_matches_old_format(self):
        hook = {"type": "command", "command": "/usr/bin/python3 -m cc_stats.hooks"}
        assert _hook_matches(hook, "anything") is True

    def test_matches_new_format(self):
        hook = {"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}
        assert _hook_matches(hook, "anything") is True

    def test_no_match_unrelated(self):
        hook = {"type": "command", "command": "echo hello"}
        assert _hook_matches(hook, "anything") is False

    def test_non_dict_returns_false(self):
        assert _hook_matches("not a dict", "anything") is False

    def test_missing_command_key(self):
        hook = {"type": "command"}
        assert _hook_matches(hook, "anything") is False

    def test_matches_nested_format(self):
        hook = {
            "matcher": "*",
            "hooks": [{"type": "command", "command": "/usr/bin/python3 -m cc_stats.hooks"}],
        }
        assert _hook_matches(hook, "anything") is True


class TestHookExists(unittest.TestCase):
    """_hook_exists() — 检测 hook 是否已安装"""

    def test_exists_old_format(self):
        hooks = [{"type": "command", "command": "python3 -m cc_stats.hooks"}]
        assert _hook_exists(hooks, "anything") is True

    def test_exists_new_format(self):
        hooks = [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}]
        assert _hook_exists(hooks, "anything") is True

    def test_not_exists(self):
        hooks = [{"type": "command", "command": "echo hello"}]
        assert _hook_exists(hooks, "anything") is False

    def test_empty_list(self):
        assert _hook_exists([], "anything") is False

    def test_exists_nested_format(self):
        hooks = [{"hooks": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}]}]
        assert _hook_exists(hooks, "anything") is True


class TestInstallHooks(unittest.TestCase):
    """install_hooks() — 注册完整活动链路所需的 hook event"""

    INSTALLED_EVENTS = (
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "SubagentStart",
        "SubagentStop",
        "Notification",
        "Elicitation",
        "WorktreeCreate",
        "PreCompact",
        "PostCompact",
        "PermissionRequest",
        "Stop",
        "StopFailure",
    )

    @patch("cc_stats.hooks.get_hook_command", return_value="/usr/local/bin/cc-stats-hooks")
    def test_installs_all_events(self, mock_cmd, tmp_path=None):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            settings_path = Path(tmpdir) / ".claude" / "settings.json"
            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                install_hooks(scope="user")

            assert settings_path.exists()
            with open(settings_path, encoding="utf-8") as f:
                settings = json.load(f)

            hooks = settings["hooks"]
            for event_type in self.INSTALLED_EVENTS:
                assert event_type in hooks
                entries = hooks[event_type]
                assert len(entries) == 1
                assert entries[0]["command"] == "/usr/local/bin/cc-stats-hooks"
                assert entries[0]["type"] == "command"
            assert hooks["PermissionRequest"][0]["timeout"] == 86400

    @patch("cc_stats.hooks.get_hook_command", return_value="/usr/local/bin/cc-stats-hooks")
    def test_does_not_duplicate_on_reinstall(self, mock_cmd):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                install_hooks(scope="user")
                install_hooks(scope="user")

            settings_path = Path(tmpdir) / ".claude" / "settings.json"
            with open(settings_path, encoding="utf-8") as f:
                settings = json.load(f)

            for event_type in self.INSTALLED_EVENTS:
                assert len(settings["hooks"][event_type]) == 1

    @patch("cc_stats.hooks.get_hook_command", return_value="/usr/local/bin/cc-stats-hooks")
    def test_preserves_existing_hooks(self, mock_cmd):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            settings_path = Path(tmpdir) / ".claude" / "settings.json"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            existing = {
                "hooks": {
                    "Stop": [{"type": "command", "command": "echo done"}],
                },
                "other_key": "preserved",
            }
            with open(settings_path, "w", encoding="utf-8") as f:
                json.dump(existing, f)

            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                install_hooks(scope="user")

            with open(settings_path, encoding="utf-8") as f:
                settings = json.load(f)

            assert settings["other_key"] == "preserved"
            # existing Stop hook preserved + new one added
            assert len(settings["hooks"]["Stop"]) == 2


class TestUninstallHooks(unittest.TestCase):
    """uninstall_hooks() — 清理 cc-stats 安装的全部 hook event"""

    @patch("cc_stats.hooks.get_hook_command", return_value="/usr/local/bin/cc-stats-hooks")
    def test_removes_all_events(self, mock_cmd):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            settings_path = Path(tmpdir) / ".claude" / "settings.json"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            settings = {
                "hooks": {
                    "SessionStart": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "SessionEnd": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "UserPromptSubmit": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "Stop": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "PreToolUse": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "PostToolUse": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "PostToolUseFailure": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "SubagentStart": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "SubagentStop": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "PermissionRequest": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks", "timeout": 86400}],
                    "Notification": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "Elicitation": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "WorktreeCreate": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "PreCompact": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "PostCompact": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                    "StopFailure": [{"type": "command", "command": "/usr/local/bin/cc-stats-hooks"}],
                }
            }
            with open(settings_path, "w", encoding="utf-8") as f:
                json.dump(settings, f)

            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                uninstall_hooks(scope="user")

            with open(settings_path, encoding="utf-8") as f:
                result = json.load(f)

            # hooks key should be removed entirely when empty
            assert "hooks" not in result

    @patch("cc_stats.hooks.get_hook_command", return_value="/usr/local/bin/cc-stats-hooks")
    def test_removes_old_format_hooks(self, mock_cmd):
        """向后兼容：卸载旧格式 (python -m cc_stats.hooks) 的 hook"""
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            settings_path = Path(tmpdir) / ".claude" / "settings.json"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            settings = {
                "hooks": {
                    "Stop": [{"type": "command", "command": "/usr/bin/python3 -m cc_stats.hooks"}],
                    "PreToolUse": [{"type": "command", "command": "/usr/bin/python3 -m cc_stats.hooks"}],
                }
            }
            with open(settings_path, "w", encoding="utf-8") as f:
                json.dump(settings, f)

            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                uninstall_hooks(scope="user")

            with open(settings_path, encoding="utf-8") as f:
                result = json.load(f)

            assert "hooks" not in result

    @patch("cc_stats.hooks.get_hook_command", return_value="/usr/local/bin/cc-stats-hooks")
    def test_preserves_other_hooks(self, mock_cmd):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            settings_path = Path(tmpdir) / ".claude" / "settings.json"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            settings = {
                "hooks": {
                    "Stop": [
                        {"type": "command", "command": "/usr/local/bin/cc-stats-hooks"},
                        {"type": "command", "command": "echo other"},
                    ],
                }
            }
            with open(settings_path, "w", encoding="utf-8") as f:
                json.dump(settings, f)

            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                uninstall_hooks(scope="user")

            with open(settings_path, encoding="utf-8") as f:
                result = json.load(f)

            assert len(result["hooks"]["Stop"]) == 1
            assert result["hooks"]["Stop"][0]["command"] == "echo other"

    @patch("cc_stats.hooks.get_hook_command", return_value="/usr/local/bin/cc-stats-hooks")
    def test_no_settings_file_returns_true(self, mock_cmd):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                result = uninstall_hooks(scope="user")
            assert result is True


class TestPermissionRequestHook(unittest.TestCase):
    @patch("cc_stats.hooks._publish_bridge_event")
    @patch("cc_stats.hooks._wait_bridge_approval_decision", return_value=(True, ""))
    def test_permission_request_allow_output(self, _wait_mock, _publish_mock):
        event = {
            "event": "PermissionRequest",
            "session_id": "session_1",
            "tool_name": "Bash",
            "tool_input": {"command": "git push origin main"},
            "tool_use_id": "tool_1",
        }
        out = process_hook_event(event)
        assert out is not None
        assert out["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert out["hookSpecificOutput"]["decision"]["behavior"] == "allow"

    @patch("cc_stats.hooks._publish_bridge_event")
    @patch("cc_stats.hooks._wait_bridge_approval_decision", return_value=(False, "Blocked by mobile"))
    def test_permission_request_deny_output(self, _wait_mock, _publish_mock):
        event = {
            "hook_event_name": "PermissionRequest",
            "session_id": "session_2",
            "tool_name": "Edit",
            "tool_input": {"file_path": "/tmp/a.txt"},
            "tool_use_id": "tool_2",
        }
        out = process_hook_event(event)
        assert out is not None
        decision = out["hookSpecificOutput"]["decision"]
        assert decision["behavior"] == "deny"
        assert "Blocked by mobile" in decision["message"]

    @patch("cc_stats.hooks._publish_bridge_event")
    @patch("cc_stats.hooks._wait_bridge_approval_decision", return_value=(True, ""))
    def test_permission_request_writes_activity_file_with_approval_id(self, _wait_mock, _publish_mock):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                event = {
                    "event": "PermissionRequest",
                    "session_id": "session_3",
                    "tool_name": "Bash",
                    "tool_use_id": "tool_abc",
                    "tool_input": {"command": "git push origin main"},
                }
                out = process_hook_event(event)
                assert out is not None
                state_file = Path(tmpdir) / ".cc-stats" / "activity-state.json"
                assert state_file.exists()
                state = json.loads(state_file.read_text(encoding="utf-8"))
                assert state["event"] == "PermissionRequest"
                assert state["approval_id"] == "tool_abc"


class TestPreToolUseHook(unittest.TestCase):
    @patch("cc_stats.hooks._publish_bridge_event")
    @patch("cc_stats.notifier.notify_permission_request")
    def test_pre_tool_use_default_no_permission_notification(self, notify_mock, _publish_mock):
        event = {
            "event": "PreToolUse",
            "session_id": "session_pre_1",
            "tool_name": "Read",
            "tool_input": {"file_path": "/tmp/a.txt"},
        }
        out = process_hook_event(event)
        assert out is None
        notify_mock.assert_not_called()

    @patch("cc_stats.hooks._publish_bridge_event")
    @patch("cc_stats.notifier.notify_permission_request")
    def test_pre_tool_use_legacy_opt_in_notification(self, notify_mock, _publish_mock):
        event = {
            "event": "PreToolUse",
            "session_id": "session_pre_2",
            "tool_name": "Read",
            "tool_input": {"file_path": "/tmp/a.txt"},
        }
        with patch.dict(os.environ, {"CC_STATS_NOTIFY_PRE_TOOL_USE": "1"}):
            out = process_hook_event(event)
        assert out is None
        notify_mock.assert_called_once()


class TestActivityStateWriting(unittest.TestCase):
    @patch("cc_stats.hooks._publish_bridge_event")
    def test_notification_idle_prompt_writes_idle_state(self, _publish_mock):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                event = {
                    "event": "Notification",
                    "notification_type": "idle_prompt",
                    "message": "Waiting for input",
                }
                out = process_hook_event(event)
                assert out is None
                state_file = Path(tmpdir) / ".cc-stats" / "activity-state.json"
                assert state_file.exists()
                state = json.loads(state_file.read_text(encoding="utf-8"))
                assert state["event"] == "Notification"
                assert state["state"] == "idle"
                assert state["notification_type"] == "idle_prompt"

    @patch("cc_stats.hooks._publish_bridge_event")
    @patch("cc_stats.hooks._wait_bridge_approval_decision", return_value=None)
    def test_idle_prompt_does_not_clear_pending_permission_request(self, _wait_mock, _publish_mock):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("cc_stats.hooks.Path.home", return_value=Path(tmpdir)):
                process_hook_event(
                    {
                        "event": "PermissionRequest",
                        "tool_name": "Bash",
                        "tool_use_id": "tool_pending_1",
                        "tool_input": {"command": "git push"},
                    }
                )
                process_hook_event(
                    {
                        "event": "Notification",
                        "notification_type": "idle_prompt",
                        "message": "Waiting for input",
                    }
                )

                state_file = Path(tmpdir) / ".cc-stats" / "activity-state.json"
                state = json.loads(state_file.read_text(encoding="utf-8"))
                assert state["event"] == "PermissionRequest"
                assert state["approval_id"] == "tool_pending_1"


class TestBridgeBaseURL(unittest.TestCase):
    @patch.dict(os.environ, {}, clear=True)
    @patch("cc_stats.hooks.request.urlopen")
    def test_uses_local_bridge_when_healthcheck_succeeds(self, urlopen_mock):
        class _Resp:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

        urlopen_mock.return_value = _Resp()
        assert _bridge_base_url() == "http://127.0.0.1:8765"

    @patch.dict(os.environ, {}, clear=True)
    @patch("cc_stats.hooks.request.urlopen", side_effect=OSError("offline"))
    def test_returns_empty_when_local_bridge_unavailable(self, _urlopen_mock):
        assert _bridge_base_url() == ""


if __name__ == "__main__":
    unittest.main()
