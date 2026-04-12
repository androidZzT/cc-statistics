"""token_cache 模块的单元测试"""

from __future__ import annotations

import json
import os
import time
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

from cc_stats.token_cache import (
    TokenData,
    read_cached_token,
    write_cached_token,
    clear_cached_token,
    get_token,
    handle_token_expired,
    is_token_expired_response,
    _read_from_keychain,
    CACHE_FILE,
)


class TestTokenData(unittest.TestCase):
    """TokenData 数据结构测试"""

    def test_to_dict(self) -> None:
        td = TokenData(access_token="abc123", cached_at=1000.0)
        result = td.to_dict()
        self.assertEqual(result["access_token"], "abc123")
        self.assertEqual(result["cached_at"], 1000.0)

    def test_from_dict_valid(self) -> None:
        data = {"access_token": "abc123", "cached_at": 1000.0}
        td = TokenData.from_dict(data)
        self.assertIsNotNone(td)
        self.assertEqual(td.access_token, "abc123")
        self.assertEqual(td.cached_at, 1000.0)

    def test_from_dict_missing_token(self) -> None:
        self.assertIsNone(TokenData.from_dict({"cached_at": 1000.0}))

    def test_from_dict_empty_token(self) -> None:
        self.assertIsNone(TokenData.from_dict({"access_token": "", "cached_at": 1000.0}))

    def test_from_dict_non_string_token(self) -> None:
        self.assertIsNone(TokenData.from_dict({"access_token": 12345, "cached_at": 1000.0}))

    def test_from_dict_missing_cached_at(self) -> None:
        td = TokenData.from_dict({"access_token": "abc123"})
        self.assertIsNotNone(td)
        self.assertEqual(td.cached_at, 0.0)

    def test_from_dict_invalid_cached_at(self) -> None:
        td = TokenData.from_dict({"access_token": "abc123", "cached_at": "not_a_number"})
        self.assertIsNotNone(td)
        self.assertEqual(td.cached_at, 0.0)

    def test_immutable(self) -> None:
        td = TokenData(access_token="abc", cached_at=1.0)
        with self.assertRaises(AttributeError):
            td.access_token = "xyz"  # type: ignore[misc]

    def test_roundtrip(self) -> None:
        original = TokenData(access_token="token123", cached_at=9999.0)
        restored = TokenData.from_dict(original.to_dict())
        self.assertEqual(original, restored)


class TestCacheReadWrite(unittest.TestCase):
    """缓存文件读写测试"""

    def setUp(self) -> None:
        """使用 tmp_path 模拟缓存目录"""
        import tempfile
        self.tmp_dir = tempfile.mkdtemp()
        self.tmp_file = Path(self.tmp_dir) / "token.json"
        self._patcher_dir = patch("cc_stats.token_cache.CACHE_DIR", Path(self.tmp_dir))
        self._patcher_file = patch("cc_stats.token_cache.CACHE_FILE", self.tmp_file)
        self._patcher_dir.start()
        self._patcher_file.start()

    def tearDown(self) -> None:
        self._patcher_dir.stop()
        self._patcher_file.stop()
        import shutil
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_read_no_file(self) -> None:
        self.assertIsNone(read_cached_token())

    def test_write_and_read(self) -> None:
        td = TokenData(access_token="test_token", cached_at=1000.0)
        self.assertTrue(write_cached_token(td))
        result = read_cached_token()
        self.assertIsNotNone(result)
        self.assertEqual(result.access_token, "test_token")
        self.assertEqual(result.cached_at, 1000.0)

    def test_write_sets_permissions(self) -> None:
        td = TokenData(access_token="secret", cached_at=1.0)
        write_cached_token(td)
        mode = self.tmp_file.stat().st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_read_corrupted_json(self) -> None:
        self.tmp_file.write_text("not json", encoding="utf-8")
        self.assertIsNone(read_cached_token())

    def test_read_empty_file(self) -> None:
        self.tmp_file.write_text("", encoding="utf-8")
        self.assertIsNone(read_cached_token())

    def test_read_valid_json_invalid_token(self) -> None:
        self.tmp_file.write_text('{"access_token": ""}', encoding="utf-8")
        self.assertIsNone(read_cached_token())

    def test_clear_existing(self) -> None:
        td = TokenData(access_token="to_clear", cached_at=1.0)
        write_cached_token(td)
        self.assertTrue(self.tmp_file.exists())
        self.assertTrue(clear_cached_token())
        self.assertFalse(self.tmp_file.exists())

    def test_clear_nonexistent(self) -> None:
        self.assertTrue(clear_cached_token())

    def test_write_creates_directory(self) -> None:
        import shutil
        shutil.rmtree(self.tmp_dir)
        nested = Path(self.tmp_dir) / "sub"
        nested_file = nested / "token.json"
        with patch("cc_stats.token_cache.CACHE_DIR", nested), \
             patch("cc_stats.token_cache.CACHE_FILE", nested_file):
            td = TokenData(access_token="tok", cached_at=1.0)
            self.assertTrue(write_cached_token(td))
            self.assertTrue(nested_file.exists())


class TestReadFromKeychain(unittest.TestCase):
    """Keychain 读取测试"""

    @patch("cc_stats.token_cache.sys")
    def test_non_darwin_returns_none(self, mock_sys: MagicMock) -> None:
        mock_sys.platform = "linux"
        self.assertIsNone(_read_from_keychain())

    @patch("cc_stats.token_cache.subprocess.run")
    @patch.dict(os.environ, {"USER": "testuser"})
    @patch("cc_stats.token_cache.sys")
    def test_success(self, mock_sys: MagicMock, mock_run: MagicMock) -> None:
        mock_sys.platform = "darwin"
        creds = json.dumps({
            "claudeAiOauth": {"accessToken": "keychain_token_123"}
        })
        mock_run.return_value = MagicMock(returncode=0, stdout=creds)
        result = _read_from_keychain()
        self.assertEqual(result, "keychain_token_123")

    @patch("cc_stats.token_cache.subprocess.run")
    @patch.dict(os.environ, {"USER": "testuser"})
    @patch("cc_stats.token_cache.sys")
    def test_no_keychain_entry(self, mock_sys: MagicMock, mock_run: MagicMock) -> None:
        mock_sys.platform = "darwin"
        mock_run.return_value = MagicMock(returncode=44, stdout="")
        self.assertIsNone(_read_from_keychain())

    @patch("cc_stats.token_cache.subprocess.run")
    @patch.dict(os.environ, {"USER": "testuser"})
    @patch("cc_stats.token_cache.sys")
    def test_invalid_json(self, mock_sys: MagicMock, mock_run: MagicMock) -> None:
        mock_sys.platform = "darwin"
        mock_run.return_value = MagicMock(returncode=0, stdout="not-json")
        self.assertIsNone(_read_from_keychain())

    @patch("cc_stats.token_cache.subprocess.run")
    @patch.dict(os.environ, {"USER": "testuser"})
    @patch("cc_stats.token_cache.sys")
    def test_missing_oauth_key(self, mock_sys: MagicMock, mock_run: MagicMock) -> None:
        mock_sys.platform = "darwin"
        mock_run.return_value = MagicMock(returncode=0, stdout='{"other": "data"}')
        self.assertIsNone(_read_from_keychain())

    @patch("cc_stats.token_cache.subprocess.run")
    @patch.dict(os.environ, {"USER": "testuser"})
    @patch("cc_stats.token_cache.sys")
    def test_empty_access_token(self, mock_sys: MagicMock, mock_run: MagicMock) -> None:
        mock_sys.platform = "darwin"
        creds = json.dumps({"claudeAiOauth": {"accessToken": ""}})
        mock_run.return_value = MagicMock(returncode=0, stdout=creds)
        self.assertIsNone(_read_from_keychain())

    @patch("cc_stats.token_cache.subprocess.run")
    @patch.dict(os.environ, {"USER": "testuser"})
    @patch("cc_stats.token_cache.sys")
    def test_timeout(self, mock_sys: MagicMock, mock_run: MagicMock) -> None:
        import subprocess
        mock_sys.platform = "darwin"
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="security", timeout=5)
        self.assertIsNone(_read_from_keychain())

    @patch.dict(os.environ, {"USER": ""})
    @patch("cc_stats.token_cache.sys")
    def test_empty_user(self, mock_sys: MagicMock) -> None:
        mock_sys.platform = "darwin"
        self.assertIsNone(_read_from_keychain())


class TestGetToken(unittest.TestCase):
    """get_token 集成测试"""

    def setUp(self) -> None:
        import tempfile
        self.tmp_dir = tempfile.mkdtemp()
        self.tmp_file = Path(self.tmp_dir) / "token.json"
        self._patcher_dir = patch("cc_stats.token_cache.CACHE_DIR", Path(self.tmp_dir))
        self._patcher_file = patch("cc_stats.token_cache.CACHE_FILE", self.tmp_file)
        self._patcher_dir.start()
        self._patcher_file.start()

    def tearDown(self) -> None:
        self._patcher_dir.stop()
        self._patcher_file.stop()
        import shutil
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_returns_cached_token(self) -> None:
        td = TokenData(access_token="cached_one", cached_at=1.0)
        write_cached_token(td)
        with patch("cc_stats.token_cache._read_from_keychain") as mock_kc:
            result = get_token()
            self.assertEqual(result, "cached_one")
            mock_kc.assert_not_called()

    @patch("cc_stats.token_cache._read_from_keychain", return_value="kc_token")
    def test_falls_back_to_keychain(self, mock_kc: MagicMock) -> None:
        result = get_token()
        self.assertEqual(result, "kc_token")
        mock_kc.assert_called_once()
        # 验证已写入缓存
        cached = read_cached_token()
        self.assertIsNotNone(cached)
        self.assertEqual(cached.access_token, "kc_token")

    @patch("cc_stats.token_cache._read_from_keychain", return_value=None)
    def test_returns_none_when_no_source(self, mock_kc: MagicMock) -> None:
        self.assertIsNone(get_token())

    @patch("cc_stats.token_cache._read_from_keychain", return_value="new_token")
    def test_keychain_result_cached_with_timestamp(self, mock_kc: MagicMock) -> None:
        before = time.time()
        get_token()
        after = time.time()
        cached = read_cached_token()
        self.assertGreaterEqual(cached.cached_at, before)
        self.assertLessEqual(cached.cached_at, after)


class TestHandleTokenExpired(unittest.TestCase):
    """token 过期处理测试"""

    def setUp(self) -> None:
        import tempfile
        self.tmp_dir = tempfile.mkdtemp()
        self.tmp_file = Path(self.tmp_dir) / "token.json"
        self._patcher_dir = patch("cc_stats.token_cache.CACHE_DIR", Path(self.tmp_dir))
        self._patcher_file = patch("cc_stats.token_cache.CACHE_FILE", self.tmp_file)
        self._patcher_dir.start()
        self._patcher_file.start()

    def tearDown(self) -> None:
        self._patcher_dir.stop()
        self._patcher_file.stop()
        import shutil
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_clears_cache_on_expired(self) -> None:
        td = TokenData(access_token="expired_tok", cached_at=1.0)
        write_cached_token(td)
        self.assertTrue(self.tmp_file.exists())
        with patch("sys.stderr"):
            handle_token_expired()
        self.assertFalse(self.tmp_file.exists())

    def test_prints_guidance(self) -> None:
        import io
        with patch("sys.stderr", new_callable=io.StringIO) as mock_err:
            handle_token_expired()
        output = mock_err.getvalue()
        self.assertIn("过期", output)
        self.assertIn("重新获取", output)


class TestIsTokenExpiredResponse(unittest.TestCase):
    """HTTP 状态码判断测试"""

    def test_401(self) -> None:
        self.assertTrue(is_token_expired_response(401))

    def test_403(self) -> None:
        self.assertTrue(is_token_expired_response(403))

    def test_200(self) -> None:
        self.assertFalse(is_token_expired_response(200))

    def test_500(self) -> None:
        self.assertFalse(is_token_expired_response(500))

    def test_404(self) -> None:
        self.assertFalse(is_token_expired_response(404))


if __name__ == "__main__":
    unittest.main()
