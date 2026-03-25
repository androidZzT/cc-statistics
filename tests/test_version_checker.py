"""version_checker 模块的单元测试"""

from __future__ import annotations

import json
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, mock_open

from cc_stats.version_checker import (
    CheckResult,
    VersionCache,
    check_for_update,
    fetch_latest_version,
    format_update_message,
    get_cached_update,
    get_check_interval,
    is_auto_check_enabled,
    is_newer,
    parse_version,
    _read_cache,
    _write_cache,
    DEFAULT_CHECK_INTERVAL,
)


class TestParseVersion(unittest.TestCase):
    """版本号解析测试"""

    def test_simple_version(self) -> None:
        self.assertEqual(parse_version("1.2.3"), (1, 2, 3))

    def test_two_part_version(self) -> None:
        self.assertEqual(parse_version("1.0"), (1, 0))

    def test_single_part_version(self) -> None:
        self.assertEqual(parse_version("5"), (5,))

    def test_leading_trailing_spaces(self) -> None:
        self.assertEqual(parse_version("  1.2.3  "), (1, 2, 3))

    def test_non_numeric_part(self) -> None:
        # "1.2.beta" → beta 解析为 0
        self.assertEqual(parse_version("1.2.beta"), (1, 2, 0))

    def test_empty_string(self) -> None:
        self.assertEqual(parse_version(""), (0,))


class TestIsNewer(unittest.TestCase):
    """版本比较测试"""

    def test_newer_patch(self) -> None:
        self.assertTrue(is_newer("1.0.1", "1.0.0"))

    def test_newer_minor(self) -> None:
        self.assertTrue(is_newer("1.1.0", "1.0.9"))

    def test_newer_major(self) -> None:
        self.assertTrue(is_newer("2.0.0", "1.9.9"))

    def test_same_version(self) -> None:
        self.assertFalse(is_newer("1.0.0", "1.0.0"))

    def test_older_version(self) -> None:
        self.assertFalse(is_newer("1.0.0", "1.0.1"))

    def test_different_length(self) -> None:
        self.assertTrue(is_newer("1.0.1", "1.0"))
        self.assertFalse(is_newer("1.0", "1.0.1"))

    def test_real_versions(self) -> None:
        self.assertTrue(is_newer("0.10.3", "0.2.0"))
        self.assertTrue(is_newer("0.3.0", "0.2.0"))
        self.assertFalse(is_newer("0.2.0", "0.10.3"))


class TestVersionCache(unittest.TestCase):
    """缓存数据结构测试"""

    def test_frozen_dataclass(self) -> None:
        cache = VersionCache(latest_version="1.0.0", checked_at=1000.0)
        with self.assertRaises(AttributeError):
            cache.latest_version = "2.0.0"  # type: ignore

    def test_to_dict(self) -> None:
        cache = VersionCache(latest_version="1.0.0", checked_at=1000.0)
        d = cache.to_dict()
        self.assertEqual(d["latest_version"], "1.0.0")
        self.assertEqual(d["checked_at"], 1000.0)

    def test_from_dict(self) -> None:
        data = {"latest_version": "2.0.0", "checked_at": 2000.0}
        cache = VersionCache.from_dict(data)
        self.assertEqual(cache.latest_version, "2.0.0")
        self.assertEqual(cache.checked_at, 2000.0)

    def test_from_dict_missing_fields(self) -> None:
        cache = VersionCache.from_dict({})
        self.assertEqual(cache.latest_version, "")
        self.assertEqual(cache.checked_at, 0)

    def test_roundtrip(self) -> None:
        original = VersionCache(latest_version="1.2.3", checked_at=12345.6)
        restored = VersionCache.from_dict(original.to_dict())
        self.assertEqual(original, restored)


class TestCheckResult(unittest.TestCase):
    """检查结果数据结构测试"""

    def test_frozen_dataclass(self) -> None:
        result = CheckResult(
            has_update=True,
            current_version="1.0.0",
            latest_version="2.0.0",
        )
        self.assertTrue(result.has_update)
        self.assertEqual(result.upgrade_command, "pip install --upgrade cc-statistics")

    def test_default_upgrade_command(self) -> None:
        result = CheckResult(
            has_update=True,
            current_version="1.0.0",
            latest_version="2.0.0",
        )
        self.assertIn("pip install", result.upgrade_command)


class TestReadCache(unittest.TestCase):
    """缓存读取测试"""

    @patch("cc_stats.version_checker.CACHE_FILE")
    def test_read_valid_cache(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.return_value = json.dumps({
            "latest_version": "1.5.0",
            "checked_at": 1000.0,
        })
        cache = _read_cache()
        self.assertIsNotNone(cache)
        self.assertEqual(cache.latest_version, "1.5.0")  # type: ignore
        self.assertEqual(cache.checked_at, 1000.0)  # type: ignore

    @patch("cc_stats.version_checker.CACHE_FILE")
    def test_read_missing_file(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = False
        self.assertIsNone(_read_cache())

    @patch("cc_stats.version_checker.CACHE_FILE")
    def test_read_invalid_json(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.return_value = "not valid json{"
        self.assertIsNone(_read_cache())

    @patch("cc_stats.version_checker.CACHE_FILE")
    def test_read_os_error(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.side_effect = OSError("permission denied")
        self.assertIsNone(_read_cache())


class TestWriteCache(unittest.TestCase):
    """缓存写入测试"""

    @patch("cc_stats.version_checker.CACHE_FILE")
    @patch("cc_stats.version_checker.CACHE_DIR")
    def test_write_success(self, mock_dir: MagicMock, mock_file: MagicMock) -> None:
        cache = VersionCache(latest_version="1.0.0", checked_at=1000.0)
        _write_cache(cache)
        mock_dir.mkdir.assert_called_once_with(parents=True, exist_ok=True)
        mock_file.write_text.assert_called_once()
        written = mock_file.write_text.call_args[0][0]
        data = json.loads(written)
        self.assertEqual(data["latest_version"], "1.0.0")

    @patch("cc_stats.version_checker.CACHE_FILE")
    @patch("cc_stats.version_checker.CACHE_DIR")
    def test_write_os_error_silent(self, mock_dir: MagicMock, mock_file: MagicMock) -> None:
        mock_dir.mkdir.side_effect = OSError("read-only filesystem")
        cache = VersionCache(latest_version="1.0.0", checked_at=1000.0)
        # 应该不抛异常
        _write_cache(cache)


class TestConfig(unittest.TestCase):
    """配置读取测试"""

    @patch("cc_stats.version_checker.CONFIG_FILE")
    def test_auto_check_enabled_default(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = False
        self.assertTrue(is_auto_check_enabled())

    @patch("cc_stats.version_checker.CONFIG_FILE")
    def test_auto_check_disabled(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.return_value = json.dumps({"auto_check_update": False})
        self.assertFalse(is_auto_check_enabled())

    @patch("cc_stats.version_checker.CONFIG_FILE")
    def test_auto_check_enabled_explicit(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.return_value = json.dumps({"auto_check_update": True})
        self.assertTrue(is_auto_check_enabled())

    @patch("cc_stats.version_checker.CONFIG_FILE")
    def test_check_interval_default(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = False
        self.assertEqual(get_check_interval(), DEFAULT_CHECK_INTERVAL)

    @patch("cc_stats.version_checker.CONFIG_FILE")
    def test_check_interval_custom(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.return_value = json.dumps({"check_interval": 7200})
        self.assertEqual(get_check_interval(), 7200)

    @patch("cc_stats.version_checker.CONFIG_FILE")
    def test_check_interval_minimum(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.return_value = json.dumps({"check_interval": 10})
        # 最少 300 秒
        self.assertEqual(get_check_interval(), 300)

    @patch("cc_stats.version_checker.CONFIG_FILE")
    def test_config_corrupt_json(self, mock_file: MagicMock) -> None:
        mock_file.exists.return_value = True
        mock_file.read_text.return_value = "corrupt"
        # fallback 到默认值
        self.assertTrue(is_auto_check_enabled())
        self.assertEqual(get_check_interval(), DEFAULT_CHECK_INTERVAL)


class TestFetchLatestVersion(unittest.TestCase):
    """PyPI 请求测试"""

    @patch("cc_stats.version_checker.urllib.request.urlopen")
    def test_fetch_success(self, mock_urlopen: MagicMock) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({
            "info": {"version": "1.5.0"}
        }).encode("utf-8")
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = fetch_latest_version()
        self.assertEqual(result, "1.5.0")

    @patch("cc_stats.version_checker.urllib.request.urlopen")
    def test_fetch_network_error(self, mock_urlopen: MagicMock) -> None:
        from urllib.error import URLError
        mock_urlopen.side_effect = URLError("timeout")
        self.assertIsNone(fetch_latest_version())

    @patch("cc_stats.version_checker.urllib.request.urlopen")
    def test_fetch_invalid_json(self, mock_urlopen: MagicMock) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"not json"
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        self.assertIsNone(fetch_latest_version())

    @patch("cc_stats.version_checker.urllib.request.urlopen")
    def test_fetch_missing_version_field(self, mock_urlopen: MagicMock) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"info": {}}).encode("utf-8")
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        self.assertIsNone(fetch_latest_version())


class TestCheckForUpdate(unittest.TestCase):
    """主逻辑测试"""

    @patch("cc_stats.version_checker._write_cache")
    @patch("cc_stats.version_checker.fetch_latest_version")
    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.is_auto_check_enabled")
    @patch("cc_stats.version_checker.__version__", "0.2.0")
    def test_update_available(
        self,
        mock_enabled: MagicMock,
        mock_cache: MagicMock,
        mock_fetch: MagicMock,
        mock_write: MagicMock,
    ) -> None:
        mock_enabled.return_value = True
        mock_cache.return_value = None  # 无缓存
        mock_fetch.return_value = "0.3.0"

        result = check_for_update()
        self.assertIsNotNone(result)
        self.assertTrue(result.has_update)  # type: ignore
        self.assertEqual(result.latest_version, "0.3.0")  # type: ignore
        mock_write.assert_called_once()

    @patch("cc_stats.version_checker._write_cache")
    @patch("cc_stats.version_checker.fetch_latest_version")
    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.is_auto_check_enabled")
    @patch("cc_stats.version_checker.__version__", "0.3.0")
    def test_no_update(
        self,
        mock_enabled: MagicMock,
        mock_cache: MagicMock,
        mock_fetch: MagicMock,
        mock_write: MagicMock,
    ) -> None:
        mock_enabled.return_value = True
        mock_cache.return_value = None
        mock_fetch.return_value = "0.3.0"

        result = check_for_update()
        self.assertIsNone(result)

    @patch("cc_stats.version_checker.is_auto_check_enabled")
    def test_disabled_returns_none(self, mock_enabled: MagicMock) -> None:
        mock_enabled.return_value = False
        result = check_for_update()
        self.assertIsNone(result)

    @patch("cc_stats.version_checker.is_auto_check_enabled")
    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.fetch_latest_version")
    @patch("cc_stats.version_checker._write_cache")
    @patch("cc_stats.version_checker.__version__", "0.2.0")
    def test_force_bypasses_disabled(
        self,
        mock_write: MagicMock,
        mock_fetch: MagicMock,
        mock_cache: MagicMock,
        mock_enabled: MagicMock,
    ) -> None:
        mock_enabled.return_value = False
        mock_cache.return_value = None
        mock_fetch.return_value = "0.5.0"

        result = check_for_update(force=True)
        self.assertIsNotNone(result)
        self.assertTrue(result.has_update)  # type: ignore

    @patch("cc_stats.version_checker.get_check_interval")
    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.is_auto_check_enabled")
    @patch("cc_stats.version_checker.__version__", "0.2.0")
    def test_uses_cache_when_fresh(
        self,
        mock_enabled: MagicMock,
        mock_cache: MagicMock,
        mock_interval: MagicMock,
    ) -> None:
        mock_enabled.return_value = True
        mock_interval.return_value = 14400
        # 缓存 1 分钟前写入（未过期）
        mock_cache.return_value = VersionCache(
            latest_version="0.5.0",
            checked_at=time.time() - 60,
        )

        result = check_for_update()
        self.assertIsNotNone(result)
        self.assertTrue(result.has_update)  # type: ignore
        self.assertEqual(result.latest_version, "0.5.0")  # type: ignore

    @patch("cc_stats.version_checker.fetch_latest_version")
    @patch("cc_stats.version_checker.get_check_interval")
    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.is_auto_check_enabled")
    @patch("cc_stats.version_checker._write_cache")
    @patch("cc_stats.version_checker.__version__", "0.2.0")
    def test_fetches_when_cache_expired(
        self,
        mock_write: MagicMock,
        mock_enabled: MagicMock,
        mock_cache: MagicMock,
        mock_interval: MagicMock,
        mock_fetch: MagicMock,
    ) -> None:
        mock_enabled.return_value = True
        mock_interval.return_value = 14400
        # 缓存 5 小时前写入（已过期）
        mock_cache.return_value = VersionCache(
            latest_version="0.3.0",
            checked_at=time.time() - 18000,
        )
        mock_fetch.return_value = "0.4.0"

        result = check_for_update()
        self.assertIsNotNone(result)
        self.assertEqual(result.latest_version, "0.4.0")  # type: ignore
        mock_fetch.assert_called_once()

    @patch("cc_stats.version_checker._write_cache")
    @patch("cc_stats.version_checker.fetch_latest_version")
    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.is_auto_check_enabled")
    @patch("cc_stats.version_checker.__version__", "0.2.0")
    def test_network_failure_returns_none(
        self,
        mock_enabled: MagicMock,
        mock_cache: MagicMock,
        mock_fetch: MagicMock,
        mock_write: MagicMock,
    ) -> None:
        mock_enabled.return_value = True
        mock_cache.return_value = None
        mock_fetch.return_value = None  # 网络失败

        result = check_for_update()
        self.assertIsNone(result)
        mock_write.assert_not_called()


class TestGetCachedUpdate(unittest.TestCase):
    """缓存读取更新测试"""

    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.__version__", "0.2.0")
    def test_cached_update_available(self, mock_cache: MagicMock) -> None:
        mock_cache.return_value = VersionCache(
            latest_version="0.5.0",
            checked_at=time.time(),
        )
        result = get_cached_update()
        self.assertIsNotNone(result)
        self.assertTrue(result.has_update)  # type: ignore
        self.assertEqual(result.latest_version, "0.5.0")  # type: ignore

    @patch("cc_stats.version_checker._read_cache")
    @patch("cc_stats.version_checker.__version__", "0.5.0")
    def test_cached_no_update(self, mock_cache: MagicMock) -> None:
        mock_cache.return_value = VersionCache(
            latest_version="0.5.0",
            checked_at=time.time(),
        )
        result = get_cached_update()
        self.assertIsNone(result)

    @patch("cc_stats.version_checker._read_cache")
    def test_no_cache(self, mock_cache: MagicMock) -> None:
        mock_cache.return_value = None
        result = get_cached_update()
        self.assertIsNone(result)


class TestFormatUpdateMessage(unittest.TestCase):
    """消息格式化测试"""

    def test_format_message(self) -> None:
        result = CheckResult(
            has_update=True,
            current_version="0.2.0",
            latest_version="0.5.0",
        )
        msg = format_update_message(result)
        self.assertIn("v0.5.0", msg)
        self.assertIn("pip install --upgrade cc-statistics", msg)
        self.assertIn("已发布", msg)


if __name__ == "__main__":
    unittest.main()
