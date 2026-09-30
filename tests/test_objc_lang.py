"""Tests for Objective-C / Objective-C++ language detection."""

import unittest

from cc_stats.analyzer import _detect_lang


class TestObjectiveCDetection(unittest.TestCase):
    def test_objective_c(self):
        assert _detect_lang("ViewController.m") == "Objective-C"

    def test_objective_c_with_path(self):
        assert _detect_lang("src/ios/AppDelegate.m") == "Objective-C"

    def test_objective_cpp(self):
        assert _detect_lang("Bridge.mm") == "Objective-C++"

    def test_objective_cpp_with_path(self):
        assert _detect_lang("src/ios/Bridge.mm") == "Objective-C++"


if __name__ == "__main__":
    unittest.main()
