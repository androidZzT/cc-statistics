"""cc-statistics: Claude Code 会话统计工具"""

from __future__ import annotations

from importlib.metadata import PackageNotFoundError, version
from pathlib import Path


def _read_source_version() -> str | None:
    pyproject = Path(__file__).resolve().parent.parent / "pyproject.toml"
    try:
        for line in pyproject.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("version"):
                return stripped.split('"')[1]
    except (OSError, IndexError):
        return None
    return None


__version__ = _read_source_version()
if __version__ is None:
    try:
        __version__ = version("cc-statistics")
    except PackageNotFoundError:
        __version__ = "1.0.3"
