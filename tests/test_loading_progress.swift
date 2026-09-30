import Foundation

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        print("FAIL: \(message): \(actual) != \(expected)")
        exit(1)
    }
}

private func assertClose(_ actual: Double, _ expected: Double, _ message: String) {
    if abs(actual - expected) > 0.0001 {
        print("FAIL: \(message): \(actual) != \(expected)")
        exit(1)
    }
}

@main
struct LoadingProgressTests {
    static func main() {
        let explicit = LoadingProgressState(
            stage: "Scanning",
            detail: "Finding files",
            completed: 0,
            total: 0,
            fraction: 0.12
        )
        assertClose(explicit.fraction, 0.12, "explicit fraction is used when total is unknown")
        assertEqual(explicit.percentText, "12%", "explicit percent")

        let counted = LoadingProgressState(
            stage: "Parsing",
            detail: "Files",
            completed: 25,
            total: 100
        )
        assertClose(counted.fraction, 0.25, "fraction derives from completed/total")
        assertEqual(counted.countText, "25/100", "count text")
        assertEqual(counted.percentText, "25%", "counted percent")

        let overall = LoadingProgressState(
            stage: "Parsing",
            detail: "Files",
            completed: 25,
            total: 100,
            fraction: 0.62
        )
        assertClose(overall.fraction, 0.62, "explicit overall fraction wins")
        assertEqual(overall.countText, "25/100", "count text remains available")
        assertEqual(overall.percentText, "62%", "overall percent")

        let clampedLow = LoadingProgressState(stage: "Bad", completed: -10, total: 100)
        assertClose(clampedLow.fraction, 0.0, "negative completed clamps to 0")

        let clampedHigh = LoadingProgressState(stage: "Done", completed: 120, total: 100)
        assertClose(clampedHigh.fraction, 1.0, "over-complete clamps to 1")

        assertEqual(
            LoadingProgressSmoothing.shouldResetDisplay(from: 0.95, to: 0.08),
            true,
            "new loading cycle resets from near-complete to low progress"
        )
        assertEqual(
            LoadingProgressSmoothing.shouldResetDisplay(from: 0.50, to: 0.46),
            false,
            "small backwards jitter does not reset"
        )

        let smallDuration = LoadingProgressSmoothing.animationDuration(from: 0.20, to: 0.24)
        assertClose(smallDuration, 0.45, "small changes use minimum smooth duration")

        let largeDuration = LoadingProgressSmoothing.animationDuration(from: 0.10, to: 0.80)
        assertEqual(largeDuration > smallDuration, true, "large jumps animate more slowly")
        assertEqual(largeDuration <= 2.4, true, "large jumps are capped")

        print("LoadingProgressState tests passed")
    }
}
