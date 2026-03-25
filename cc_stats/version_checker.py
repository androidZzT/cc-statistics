"""后台版本检查模块

定期检查 PyPI 获取 cc-statistics 最新版本，缓存结果到本地文件。
网络请求失败静默处理，不影响正常使用。
"""

from __future__ import annotations

import json
import time
import urllib.request
import urllib.error
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from . import __version__

# ── 常量 ──────────────────────────────────────────────────────────

PYPI_URL = "https://pypi.org/pypi/cc-statistics/json"
CACHE_DIR = Path.home() / ".cc-stats"
CACHE_FILE = CACHE_DIR / "version_cache.json"
CONFIG_FILE = CACHE_DIR / "config.json"

DEFAULT_CHECK_INTERVAL = 4 * 3600  # 4 小时（秒）
REQUEST_TIMEOUT = 5  # 秒


# ── 数据结构 ──────────────────────────────────────────────────────

@dataclass(frozen=True)
class VersionCache:
    """版本缓存（不可变）"""
    latest_version: str
    checked_at: float  # Unix timestamp

    def to_dict(self) -> dict:
        return {
            "latest_version": self.latest_version,
            "checked_at": self.checked_at,
        }

    @staticmethod
    def from_dict(data: dict) -> VersionCache:
        return VersionCache(
            latest_version=str(data.get("latest_version", "")),
            checked_at=float(data.get("checked_at", 0)),
        )


@dataclass(frozen=True)
class CheckResult:
    """版本检查结果（不可变）"""
    has_update: bool
    current_version: str
    latest_version: str
    upgrade_command: str = "pip install --upgrade cc-statistics"


# ── 配置 ──────────────────────────────────────────────────────────

def load_config() -> dict:
    """读取用户配置。返回新的 dict，不修改任何外部状态。"""
    try:
        if CONFIG_FILE.exists():
            text = CONFIG_FILE.read_text(encoding="utf-8")
            return json.loads(text)
    except (json.JSONDecodeError, OSError):
        pass
    return {}


def is_auto_check_enabled() -> bool:
    """判断是否启用自动版本检查（默认启用）"""
    config = load_config()
    return bool(config.get("auto_check_update", True))


def get_check_interval() -> int:
    """获取检查间隔（秒）"""
    config = load_config()
    interval = config.get("check_interval", DEFAULT_CHECK_INTERVAL)
    try:
        return max(300, int(interval))  # 最少 5 分钟
    except (TypeError, ValueError):
        return DEFAULT_CHECK_INTERVAL


# ── 缓存 ──────────────────────────────────────────────────────────

def _read_cache() -> Optional[VersionCache]:
    """读取缓存文件。失败返回 None，不抛异常。"""
    try:
        if CACHE_FILE.exists():
            text = CACHE_FILE.read_text(encoding="utf-8")
            data = json.loads(text)
            return VersionCache.from_dict(data)
    except (json.JSONDecodeError, OSError, KeyError, TypeError):
        pass
    return None


def _write_cache(cache: VersionCache) -> None:
    """写入缓存文件。失败静默处理。"""
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(
            json.dumps(cache.to_dict(), indent=2),
            encoding="utf-8",
        )
    except OSError:
        pass


# ── 版本比较 ──────────────────────────────────────────────────────

def parse_version(version: str) -> tuple[int, ...]:
    """将版本字符串解析为 int 元组，用于比较。

    例如 "0.10.3" → (0, 10, 3)
    非数字部分视为 0。
    """
    parts: list[int] = []
    for part in version.strip().split("."):
        try:
            parts.append(int(part))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def is_newer(remote: str, local: str) -> bool:
    """判断 remote 版本是否比 local 版本更新"""
    return parse_version(remote) > parse_version(local)


# ── 网络请求 ──────────────────────────────────────────────────────

def fetch_latest_version() -> Optional[str]:
    """从 PyPI 获取最新版本号。网络失败返回 None。"""
    try:
        req = urllib.request.Request(
            PYPI_URL,
            headers={"Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            version = data.get("info", {}).get("version")
            return str(version) if version else None
    except (urllib.error.URLError, OSError, json.JSONDecodeError,
            KeyError, TypeError, ValueError):
        return None


# ── 主逻辑 ──────────────────────────────────────────────────────

def check_for_update(force: bool = False) -> Optional[CheckResult]:
    """检查是否有新版本。

    - 如果自动检查被禁用且非强制，返回 None
    - 如果缓存未过期且非强制，使用缓存结果
    - 如果网络请求失败，静默返回 None
    - 返回 CheckResult（不可变）或 None
    """
    if not force and not is_auto_check_enabled():
        return None

    current = __version__
    now = time.time()
    interval = get_check_interval()

    # 检查缓存
    cache = _read_cache()
    if cache is not None and not force:
        elapsed = now - cache.checked_at
        if elapsed < interval:
            # 缓存未过期，直接使用
            if is_newer(cache.latest_version, current):
                return CheckResult(
                    has_update=True,
                    current_version=current,
                    latest_version=cache.latest_version,
                )
            return None

    # 缓存过期或强制刷新，请求 PyPI
    latest = fetch_latest_version()
    if latest is None:
        return None

    # 写入新缓存
    new_cache = VersionCache(latest_version=latest, checked_at=now)
    _write_cache(new_cache)

    if is_newer(latest, current):
        return CheckResult(
            has_update=True,
            current_version=current,
            latest_version=latest,
        )

    return None


def get_cached_update() -> Optional[CheckResult]:
    """仅从缓存读取更新信息（不发起网络请求）。

    适用于 CLI 启动时快速提示，避免阻塞。
    """
    cache = _read_cache()
    if cache is None:
        return None

    current = __version__
    if is_newer(cache.latest_version, current):
        return CheckResult(
            has_update=True,
            current_version=current,
            latest_version=cache.latest_version,
        )
    return None


def format_update_message(result: CheckResult) -> str:
    """格式化更新提示消息"""
    return (
        f"cc-statistics v{result.latest_version} 已发布，"
        f"运行 {result.upgrade_command} 更新"
    )
