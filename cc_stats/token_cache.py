"""Session token 缓存模块

将 Claude Code OAuth token 缓存到本地文件，避免每次都从 Keychain 读取。
Token 过期时（API 返回 401/403）自动清除缓存并提示用户重新获取。

缓存文件位置: ~/.cc-stats/token.json
Token 来源: macOS Keychain ("Claude Code-credentials")
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# ── 常量 ──────────────────────────────────────────────────────────

CACHE_DIR = Path.home() / ".cc-stats"
CACHE_FILE = CACHE_DIR / "token.json"

KEYCHAIN_SERVICE = "Claude Code-credentials"


# ── 数据结构 ──────────────────────────────────────────────────────

@dataclass(frozen=True)
class TokenData:
    """缓存的 token 数据（不可变）"""
    access_token: str
    cached_at: float  # Unix timestamp

    def to_dict(self) -> dict:
        return {
            "access_token": self.access_token,
            "cached_at": self.cached_at,
        }

    @staticmethod
    def from_dict(data: dict) -> Optional[TokenData]:
        """从 dict 构造 TokenData，数据无效返回 None"""
        token = data.get("access_token")
        if not token or not isinstance(token, str):
            return None
        cached_at = data.get("cached_at", 0)
        try:
            cached_at = float(cached_at)
        except (TypeError, ValueError):
            cached_at = 0.0
        return TokenData(access_token=token, cached_at=cached_at)


# ── 缓存读写 ─────────────────────────────────────────────────────

def read_cached_token() -> Optional[TokenData]:
    """读取缓存的 token。文件不存在或数据无效返回 None。"""
    try:
        if not CACHE_FILE.exists():
            return None
        text = CACHE_FILE.read_text(encoding="utf-8")
        data = json.loads(text)
        return TokenData.from_dict(data)
    except (json.JSONDecodeError, OSError, KeyError, TypeError):
        return None


def write_cached_token(token_data: TokenData) -> bool:
    """写入 token 缓存。成功返回 True，失败返回 False。"""
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(
            json.dumps(token_data.to_dict(), indent=2),
            encoding="utf-8",
        )
        # 限制文件权限为 owner-only (0600)
        CACHE_FILE.chmod(0o600)
        return True
    except OSError:
        return False


def clear_cached_token() -> bool:
    """清除缓存的 token。成功或文件不存在返回 True。"""
    try:
        if CACHE_FILE.exists():
            CACHE_FILE.unlink()
        return True
    except OSError:
        return False


# ── Keychain 读取 ────────────────────────────────────────────────

def _read_from_keychain() -> Optional[str]:
    """从 macOS Keychain 读取 Claude Code OAuth token。

    调用 `security find-generic-password` 获取凭据 JSON，
    解析 claudeAiOauth.accessToken 字段。
    非 macOS 或 Keychain 无凭据返回 None。
    """
    if sys.platform != "darwin":
        return None

    username = os.environ.get("USER", "")
    if not username:
        return None

    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s", KEYCHAIN_SERVICE,
                "-a", username,
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return None

        raw = result.stdout.strip()
        if not raw:
            return None

        creds = json.loads(raw)
        oauth = creds.get("claudeAiOauth", {})
        token = oauth.get("accessToken", "")
        return token if token else None

    except (subprocess.TimeoutExpired, json.JSONDecodeError,
            OSError, KeyError, TypeError):
        return None


# ── 主接口 ───────────────────────────────────────────────────────

def get_token() -> Optional[str]:
    """获取 session token（优先缓存，fallback Keychain）。

    查找顺序:
    1. 本地缓存文件 (~/.cc-stats/token.json)
    2. macOS Keychain (Claude Code-credentials)
    3. 返回 None（调用方决定是否提示用户）

    从 Keychain 成功读取后自动写入缓存。
    """
    # 1. 检查缓存
    cached = read_cached_token()
    if cached is not None:
        return cached.access_token

    # 2. 尝试 Keychain
    token = _read_from_keychain()
    if token is not None:
        token_data = TokenData(access_token=token, cached_at=time.time())
        write_cached_token(token_data)
        return token

    # 3. 无可用 token
    return None


def handle_token_expired() -> None:
    """处理 token 过期：清除缓存并输出提示信息。

    当 API 返回 401/403 时调用此函数。
    """
    clear_cached_token()
    print(
        "\n⚠️  Session token 已过期或无效。\n"
        "\n"
        "请重新获取 token：\n"
        "  1. 打开 Claude Code，确保已登录\n"
        "  2. 重新运行 cc-stats，将自动从 Keychain 获取新 token\n"
        "\n"
        "如果问题持续，请在 Claude Code 中重新登录后再试。",
        file=sys.stderr,
    )


def is_token_expired_response(status_code: int) -> bool:
    """判断 HTTP 状态码是否表示 token 过期"""
    return status_code in (401, 403)
