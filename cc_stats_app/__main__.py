"""cc-stats-app 入口：启动 HTTP 服务器 + Swift 菜单栏 App"""

import os
import signal
import subprocess
import sys
import threading

from .server import start_server

_swift_src = os.path.join(os.path.dirname(__file__), "swift", "MenuBarApp.swift")
_swift_bin = os.path.join(os.path.dirname(__file__), "swift", "MenuBarApp")


def _compile_swift():
    """编译 Swift 菜单栏 App（仅首次或源码更新时）"""
    # 检查是否需要重新编译
    if os.path.exists(_swift_bin):
        src_mtime = os.path.getmtime(_swift_src)
        bin_mtime = os.path.getmtime(_swift_bin)
        if bin_mtime >= src_mtime:
            return  # 已是最新

    print("Compiling menubar app...")
    result = subprocess.run(
        [
            "swiftc",
            _swift_src,
            "-o", _swift_bin,
            "-framework", "Cocoa",
            "-framework", "WebKit",
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
    # 1. 编译 Swift app
    _compile_swift()

    # 2. 启动 HTTP 服务器
    server, port = start_server()
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    print(f"Server running at http://127.0.0.1:{port}/")

    # 3. 启动 Swift 菜单栏 app
    proc = subprocess.Popen([_swift_bin, str(port)])

    # 4. 等待 Swift 进程退出
    def on_signal(sig, frame):
        proc.terminate()
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
