"""CLI version flag tests."""

from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout

from cc_stats import __version__
from cc_stats.cli import main


class TestCliVersion(unittest.TestCase):
    def test_version_flag_prints_package_version(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            with self.assertRaises(SystemExit) as ctx:
                main(["--version"])
        self.assertEqual(ctx.exception.code, 0)
        self.assertEqual(stdout.getvalue().strip(), f"cc-statistics {__version__}")

    def test_short_version_flag_prints_package_version(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            with self.assertRaises(SystemExit) as ctx:
                main(["-v"])
        self.assertEqual(ctx.exception.code, 0)
        self.assertEqual(stdout.getvalue().strip(), f"cc-statistics {__version__}")


if __name__ == "__main__":
    unittest.main()
