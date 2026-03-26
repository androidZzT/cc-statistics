"""cc-stats-app 入口：启动 SwiftUI 菜单栏 App

优先使用预编译 .app bundle（从 GitHub Release 下载），没有则 fallback 到本地 swiftc 编译。
"""

import glob
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error
import zipfile

_swift_dir = os.path.join(os.path.dirname(__file__), "swift")
_app_bundle = os.path.join(_swift_dir, "CCStats.app")
_swift_bin = os.path.join(_app_bundle, "Contents", "MacOS", "CCStats")
_version_file = os.path.join(_swift_dir, ".binary_version")
_info_plist_template = os.path.join(_swift_dir, "Info.plist")

GITHUB_REPO = "androidZzT/cc-statistics"

_ALLOWED_DOWNLOAD_PREFIXES = (
    "https://github.com/",
    "https://objects.githubusercontent.com/",
)


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


def _is_binary_ready() -> bool:
    """检查 .app bundle 中的二进制是否存在且可执行"""
    return os.path.exists(_swift_bin) and os.access(_swift_bin, os.X_OK)


def _source_is_newer_than_binary() -> bool:
    """检查源码是否比已有二进制更新（仅当二进制存在时才比较）"""
    if not os.path.exists(_swift_bin):
        return False
    bin_mtime = os.path.getmtime(_swift_bin)
    for swift_file in glob.glob(os.path.join(_swift_dir, "**", "*.swift"), recursive=True):
        if os.path.getmtime(swift_file) > bin_mtime:
            return True
    return False


def _safe_extract_zip(zip_path: str, dest_dir: str):
    """安全解压 zip，防止 zip slip 路径穿越攻击"""
    dest = pathlib.Path(dest_dir).resolve()
    with zipfile.ZipFile(zip_path, "r") as zf:
        for member in zf.infolist():
            member_path = (dest / member.filename).resolve()
            if not str(member_path).startswith(str(dest)):
                raise ValueError(f"Unsafe zip entry: {member.filename}")
        zf.extractall(dest_dir)


def _try_download_binary() -> bool:
    """尝试从 GitHub Release 下载预编译 .app bundle"""
    # 如果本地源码比二进制新，跳过预编译，走本地编译
    if _source_is_newer_than_binary():
        return False

    current_version = _get_current_version()
    binary_version = _get_binary_version()

    # 已有匹配版本的二进制且文件存在
    if binary_version == current_version and _is_binary_ready():
        return True

    arch = platform.machine()  # arm64 or x86_64
    if arch not in ("arm64", "x86_64"):
        return False

    asset_name = f"CCStats-{arch}.zip"
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

        # 验证下载 URL 来源
        if not asset_url.startswith(_ALLOWED_DOWNLOAD_PREFIXES):
            return False

        print(f"Downloading prebuilt app ({arch})...")

        # 下载 zip 到临时文件
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
            tmp_path = tmp.name
            urllib.request.urlretrieve(asset_url, tmp_path)

        try:
            # 移除旧 .app bundle
            if os.path.exists(_app_bundle):
                shutil.rmtree(_app_bundle)

            # 使用 ditto 解压（保留权限和 macOS 元数据）
            result = subprocess.run(
                ["ditto", "-x", "-k", tmp_path, _swift_dir],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                # fallback: 安全解压后手动设置权限
                _safe_extract_zip(tmp_path, _swift_dir)
                if os.path.exists(_swift_bin):
                    os.chmod(_swift_bin, 0o755)
        finally:
            os.unlink(tmp_path)

        # 验证解压结果
        if not _is_binary_ready():
            return False

        _save_binary_version(current_version)
        print("Done.")
        return True

    except (urllib.error.URLError, json.JSONDecodeError, OSError, KeyError):
        return False


def _need_recompile() -> bool:
    """检查是否需要编译（二进制不存在或源码更新）"""
    if not os.path.exists(_swift_bin):
        return True
    return _source_is_newer_than_binary()


def _create_app_bundle(binary_path: str, version: str):
    """将编译好的二进制打包为 .app bundle"""
    if not os.path.exists(_info_plist_template):
        raise FileNotFoundError(
            f"Info.plist template not found: {_info_plist_template}. "
            "Package installation may be corrupted."
        )

    # 创建 bundle 结构
    macos_dir = os.path.join(_app_bundle, "Contents", "MacOS")
    resources_dir = os.path.join(_app_bundle, "Contents", "Resources")
    os.makedirs(macos_dir, exist_ok=True)
    os.makedirs(resources_dir, exist_ok=True)

    # 移动二进制
    dest_bin = os.path.join(macos_dir, "CCStats")
    shutil.move(binary_path, dest_bin)
    os.chmod(dest_bin, 0o755)

    # 生成 Info.plist（从模板替换版本号）
    with open(_info_plist_template) as f:
        plist_content = f.read()
    plist_content = plist_content.replace("__VERSION__", version)

    plist_path = os.path.join(_app_bundle, "Contents", "Info.plist")
    with open(plist_path, "w") as f:
        f.write(plist_content)


def _compile_swift():
    """编译 SwiftUI 菜单栏 App（仅首次或源码更新时）"""
    if not _need_recompile():
        return

    print("Compiling CCStats app...")

    # 收集所有 Swift 文件
    swift_files = glob.glob(os.path.join(_swift_dir, "**", "*.swift"), recursive=True)

    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    target = f"{arch}-apple-macosx13.0"

    # 编译到临时路径
    tmp_bin = os.path.join(_swift_dir, "CCStats.tmp")
    result = subprocess.run(
        [
            "swiftc",
            *swift_files,
            "-o", tmp_bin,
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

    # 清理旧 bundle，创建新 bundle
    if os.path.exists(_app_bundle):
        shutil.rmtree(_app_bundle)

    version = _get_current_version()
    _create_app_bundle(tmp_bin, version)
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
    except Exception as e:
        print(f"Warning: could not write version file: {e}", file=sys.stderr)


def main():
    # 写入当前版本供 Swift 层读取
    _write_current_version()

    # 优先下载预编译二进制
    if not _try_download_binary():
        # fallback: 本地编译
        _compile_swift()

    # 使用 open 命令启动 .app bundle（macOS 标准方式）
    subprocess.Popen(
        ["open", _app_bundle],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print("CCStats is running.")


if __name__ == "__main__":
    main()
