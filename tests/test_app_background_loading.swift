// Run with: python3 tests/run_swift_app_tests.py
// The runner appends this harness to StatsViewModel.swift so it can exercise
// private cache/task state without exposing production testing APIs.
import Foundation

extension StatsViewModel {
    @MainActor
    static func testBackgroundLoading() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        var paths: [String] = []
        for index in 0..<17 {
            let file = directory.appendingPathComponent("session-\(index).jsonl")
            let row: [String: Any] = [
                "type": "session_meta", "timestamp": "2026-09-30T10:00:00Z",
                "payload": ["id": "session-\(index)", "cwd": "/tmp/cpu-test"]
            ]
            let message: [String: Any] = [
                "type": "event_msg", "timestamp": "2026-09-30T10:00:01Z",
                "payload": ["type": "user_message", "message": "test instruction"]
            ]
            let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
                + JSONSerialization.data(withJSONObject: message) + Data([10])
            try data.write(to: file)
            paths.append(file.path)
        }

        let model = StatsViewModel()
        // Cancel initialization before yielding so tests never scan user sessions.
        model.refreshTask?.cancel()
        model.versionCheckTimer?.invalidate()
        model.timeFilter = .all
        model.selectedSource = .codex
        model.didFinishInitialRefresh = true
        let invalidFile = directory.appendingPathComponent("invalid.jsonl")
        try Data("not json\n".utf8).write(to: invalidFile)
        model.deferredHistoricalFilePaths = paths + [invalidFile.path]

        model.triggerDeferredHistoricalLoadIfNeeded()
        precondition(model.historicalLoadTask == nil, "Hidden panel must not start historical parsing")

        model.isPanelVisible = true
        // Visibility starts the normal refresh; isolate historical loading here.
        model.refreshTask?.cancel()
        model.pauseAutoRefresh()
        model.triggerDeferredHistoricalLoadIfNeeded()
        let firstLoad = model.historicalLoadTask
        for _ in 0..<100 {
            if model.cachedSessions.count >= 8 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(model.cachedSessions.count == 8, "One small chunk must commit before the pacing delay")
        let completedPaths = Set(model.cachedSessions.map(\.filePath))
        model.isPanelVisible = false
        await firstLoad?.value
        precondition(model.cachedSessions.count == 8, "Hidden panel must stop further parsing")
        precondition(model.deferredHistoricalFilePaths.count == 18, "Pending history must survive cancellation")

        model.isPanelVisible = true
        model.refreshTask?.cancel()
        model.pauseAutoRefresh()
        model.triggerDeferredHistoricalLoadIfNeeded()
        let resumedLoad = model.historicalLoadTask
        precondition(resumedLoad != nil, "Reopening must resume pending history")
        await resumedLoad?.value
        let resultPaths = model.cachedSessions.map(\.filePath)
        precondition(resultPaths.count == 17 && Set(resultPaths) == Set(paths), "Resume must neither lose nor duplicate sessions")
        precondition(completedPaths.isSubset(of: Set(resultPaths)), "Previously loaded sessions must be retained")
        precondition(model.deferredHistoricalFilePaths.isEmpty, "Completed history must clear its pending queue")
        model.isPanelVisible = false
        print("Background loading: hidden, cancel, preserve, resume, deduplicate passed")
    }
}

@main
struct AppBackgroundLoadingTests {
    @MainActor
    static func main() async throws {
        try await StatsViewModel.testBackgroundLoading()
    }
}
