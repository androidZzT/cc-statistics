"""Compile the Swift app with a standalone regression harness instead of its UI entrypoint."""
from pathlib import Path
import platform
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    sources = root / "cc_stats_app" / "swift"
    with tempfile.TemporaryDirectory(prefix="cc-stats-tests-") as temporary:
        directory = Path(temporary)
        app = directory / "CCStatsApp.swift"
        app.write_text((sources / app.name).read_text().replace("@main\n", "", 1))
        model = directory / "StatsViewModel.swift"
        model.write_text(
            (sources / model.name).read_text()
            + "\n" + (root / "tests" / "test_app_background_loading.swift").read_text()
        )
        files = [str(path) for path in sources.rglob("*.swift")
                 if path.name not in {app.name, model.name}]
        binary = directory / "app-tests"
        target = f"{platform.machine()}-apple-macosx12.0"
        subprocess.run([
            "swiftc", "-target", target, *files, str(app), str(model), "-o", str(binary),
            "-framework", "Cocoa", "-framework", "SwiftUI", "-framework", "Carbon",
            "-framework", "UserNotifications", "-framework", "WebKit", "-lsqlite3",
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
