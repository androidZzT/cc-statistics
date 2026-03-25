"""cc-stats-app 入口：启动 SwiftUI 菜单栏 App

优先使用预编译二进制（从 GitHub Release 下载），没有则 fallback 到本地 swiftc 编译。
"""

import glob
import json
import os
import platform
import subprocess
import sys
import urllib.request
import urllib.error

_swift_dir = os.path.join(os.path.dirname(__file__), "swift")
_swift_bin = os.path.join(_swift_dir, "CCStats")
_version_file = os.path.join(_swift_dir, ".binary_version")

GITHUB_REPO = "androidZzT/cc-statistics"


def _get_current_version() -> str:
    """从 pyproject.toml 或 SettingsView 读取当前版本"""
    settings = os.path.join(_swift_dir, "Views", "SettingsView.swift")
    if os.path.exists(settings):
        with open(settings) as f:
            for line in f:
                if "appVersion" in line and "=" in line:
                    return line.split('"')[1]
    return "unknown"


def _get_binary_version() -> str:
    """读取已下载二进制的版本"""
    if os.path.exists(_version_file):
        with open(_version_file) as f:
            return f.read().strip()
    return ""


def _save_binary_version(version: str):
    with open(_version_file, "w") as f:
        f.write(version)


def _try_download_binary() -> bool:
    """尝试从 GitHub Release 下载预编译二进制"""
    # 如果本地源码比二进制新，跳过预编译，走本地编译
    if _need_recompile():
        return False

    current_version = _get_current_version()
    binary_version = _get_binary_version()

    # 已有匹配版本的二进制且文件存在
    if (
        binary_version == current_version
        and os.path.exists(_swift_bin)
        and os.access(_swift_bin, os.X_OK)
    ):
        return True

    arch = platform.machine()  # arm64 or x86_64
    if arch not in ("arm64", "x86_64"):
        return False

    asset_name = f"CCStats-{arch}"
    tag = f"v{current_version}"

    try:
        # 查询 release assets
        url = f"https://api.github.com/repos/{GITHUB_REPO}/releases/tags/{tag}"
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            release = json.loads(resp.read().decode())

        # 找到对应架构的 asset
        asset_url = None
        for asset in release.get("assets", []):
            if asset["name"] == asset_name:
                asset_url = asset["browser_download_url"]
                break

        if not asset_url:
            return False

        print(f"Downloading prebuilt binary ({arch})...")
        urllib.request.urlretrieve(asset_url, _swift_bin)
        os.chmod(_swift_bin, 0o755)
        _save_binary_version(current_version)
        print("Done.")
        return True

    except (urllib.error.URLError, json.JSONDecodeError, OSError, KeyError):
        return False


def _need_recompile() -> bool:
    """检查是否需要重新编译"""
    if not os.path.exists(_swift_bin):
        return True
    bin_mtime = os.path.getmtime(_swift_bin)
    for swift_file in glob.glob(os.path.join(_swift_dir, "**", "*.swift"), recursive=True):
        if os.path.getmtime(swift_file) > bin_mtime:
            return True
    return False


def _compile_swift():
    """编译 SwiftUI 菜单栏 App（仅首次或源码更新时）"""
    if not _need_recompile():
        return

    print("Compiling CCStats app...")

    # 收集所有 Swift 文件
    swift_files = glob.glob(os.path.join(_swift_dir, "**", "*.swift"), recursive=True)

    import platform
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    target = f"{arch}-apple-macosx12.0"

    result = subprocess.run(
        [
            "swiftc",
            *swift_files,
            "-o", _swift_bin,
            "-target", target,
            "-framework", "Cocoa",
            "-framework", "SwiftUI",
            "-framework", "Carbon",
            "-lsqlite3",
            "-O",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Swift compilation failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print("Done.")


def _write_current_version() -> None:
    """将当前版本写入 ~/.cc-stats/current_version 供 Swift 层读取"""
    try:
        from cc_stats import __version__
        version_dir = os.path.join(os.path.expanduser("~"), ".cc-stats")
        os.makedirs(version_dir, exist_ok=True)
        version_file = os.path.join(version_dir, "current_version")
        with open(version_file, "w") as f:
            f.write(__version__)
    except Exception:
        pass


def main():
    # 写入当前版本供 Swift 层读取
    _write_current_version()

    # 优先下载预编译二进制
    if not _try_download_binary():
        # fallback: 本地编译
        _compile_swift()

    # 自动后台运行：fork 进程后父进程退出，不占用终端
    if os.fork() != 0:
        # 父进程：打印提示后退出
        print("CCStats is running in the background.")
        sys.exit(0)

    # 子进程：脱离终端
    os.setsid()

    # 关闭标准输入输出
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    os.close(devnull)

    # 启动 Swift app
    os.execv(_swift_bin, [_swift_bin])


if __name__ == "__main__":
    main()
