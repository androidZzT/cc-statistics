"""cc-stats-app entrypoint tests."""

from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout

from cc_stats import __version__
from cc_stats_app.__main__ import main


class TestAppEntrypoint(unittest.TestCase):
    def test_version_flag_does_not_launch_app(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            main(["--version"])
        self.assertEqual(stdout.getvalue().strip(), f"cc-statistics {__version__}")

    def test_short_version_flag_does_not_launch_app(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            main(["-v"])
        self.assertEqual(stdout.getvalue().strip(), f"cc-statistics {__version__}")


if __name__ == "__main__":
    unittest.main()
