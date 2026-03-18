"""cc-stats-app 入口：编译并启动 SwiftUI 菜单栏 App"""

import glob
import os
import subprocess
import sys

_swift_dir = os.path.join(os.path.dirname(__file__), "swift")
_swift_bin = os.path.join(_swift_dir, "CCStats")


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

    result = subprocess.run(
        [
            "swiftc",
            *swift_files,
            "-o", _swift_bin,
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


def main():
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
