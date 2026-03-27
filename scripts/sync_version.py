#!/usr/bin/env python3
"""从 pyproject.toml 读取版本号，同步更新所有需要版本号的文件。

用法：
    python scripts/sync_version.py          # 同步当前 pyproject.toml 版本
    python scripts/sync_version.py 0.13.0   # 先更新 pyproject.toml 再同步
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PYPROJECT = os.path.join(ROOT, "pyproject.toml")
INIT_PY = os.path.join(ROOT, "cc_stats", "__init__.py")
SETTINGS_VIEW = os.path.join(
    ROOT, "cc_stats_app", "swift", "Views", "SettingsView.swift"
)

VERSION_RE = re.compile(r'^version\s*=\s*"([^"]+)"', re.MULTILINE)


def read_pyproject_version() -> str:
    with open(PYPROJECT) as f:
        match = VERSION_RE.search(f.read())
    if not match:
        print("Error: could not parse version from pyproject.toml", file=sys.stderr)
        sys.exit(1)
    return match.group(1)


def update_pyproject(new_version: str) -> None:
    with open(PYPROJECT) as f:
        content = f.read()
    updated = VERSION_RE.sub(f'version = "{new_version}"', content, count=1)
    with open(PYPROJECT, "w") as f:
        f.write(updated)
    print(f"  pyproject.toml -> {new_version}")


def update_init_py(version: str) -> None:
    with open(INIT_PY) as f:
        content = f.read()
    updated = re.sub(
        r'__version__\s*=\s*"[^"]+"',
        f'__version__ = "{version}"',
        content,
    )
    with open(INIT_PY, "w") as f:
        f.write(updated)
    print(f"  cc_stats/__init__.py -> {version}")


def update_settings_view(version: str) -> None:
    with open(SETTINGS_VIEW) as f:
        content = f.read()
    updated = re.sub(
        r'fallbackVersion\s*=\s*"[^"]+"',
        f'fallbackVersion = "{version}"',
        content,
    )
    with open(SETTINGS_VIEW, "w") as f:
        f.write(updated)
    print(f"  SettingsView.swift fallbackVersion -> {version}")


def main() -> None:
    if len(sys.argv) > 1:
        new_version = sys.argv[1]
        print(f"Setting version to {new_version}:")
        update_pyproject(new_version)
    else:
        new_version = read_pyproject_version()
        print(f"Syncing version {new_version} from pyproject.toml:")

    update_init_py(new_version)
    update_settings_view(new_version)
    print("Done. All version files are in sync.")


if __name__ == "__main__":
    main()
