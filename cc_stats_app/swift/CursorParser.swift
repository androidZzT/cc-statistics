import Foundation
import SQLite3

// MARK: - Cursor Stats Model

struct DailyCodeStats {
    let date: String
    let tabSuggestedLines: Int
    let tabAcceptedLines: Int
    let composerSuggestedLines: Int
    let composerAcceptedLines: Int

    var totalSuggested: Int { tabSuggestedLines + composerSuggestedLines }
    var totalAccepted: Int { tabAcceptedLines + composerAcceptedLines }
    var acceptanceRate: Double {
        totalSuggested > 0 ? Double(totalAccepted) / Double(totalSuggested) : 0
    }
}

struct CursorStats {
    var totalSessions: Int
    var chatSessions: Int
    var agentSessions: Int
    var editSessions: Int
    var totalLinesAdded: Int
    var totalLinesRemoved: Int
    var modelUsage: [String: Int]
    var totalMessages: Int
    var userMessages: Int
    var assistantMessages: Int
    var dateRange: (earliest: Date?, latest: Date?)
    var recentSessions: [(id: String, date: Date, model: String, mode: String, linesAdded: Int, linesRemoved: Int)]

    // AI Code Tracking
    var dailyCodeStats: [DailyCodeStats]
    var totalTabSuggested: Int
    var totalTabAccepted: Int
    var totalComposerSuggested: Int
    var totalComposerAccepted: Int

    var totalSuggested: Int { totalTabSuggested + totalComposerSuggested }
    var totalAccepted: Int { totalTabAccepted + totalComposerAccepted }
    var overallAcceptanceRate: Double {
        totalSuggested > 0 ? Double(totalAccepted) / Double(totalSuggested) : 0
    }
    var tabAcceptanceRate: Double {
        totalTabSuggested > 0 ? Double(totalTabAccepted) / Double(totalTabSuggested) : 0
    }
    var composerAcceptanceRate: Double {
        totalComposerSuggested > 0 ? Double(totalComposerAccepted) / Double(totalComposerSuggested) : 0
    }

    static func empty() -> CursorStats {
        CursorStats(
            totalSessions: 0,
            chatSessions: 0,
            agentSessions: 0,
            editSessions: 0,
            totalLinesAdded: 0,
            totalLinesRemoved: 0,
            modelUsage: [:],
            totalMessages: 0,
            userMessages: 0,
            assistantMessages: 0,
            dateRange: (nil, nil),
            recentSessions: [],
            dailyCodeStats: [],
            totalTabSuggested: 0,
            totalTabAccepted: 0,
            totalComposerSuggested: 0,
            totalComposerAccepted: 0
        )
    }
}

// MARK: - Cursor Parser

final class CursorParser {

    // MARK: - Database Path

    private static var databasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    // MARK: - Public API

    static func parse(since: Date? = nil) -> CursorStats {
        let dbPath = databasePath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .empty()
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            return .empty()
        }
        defer { sqlite3_close(db) }

        let composerEntries = queryComposerData(db: db, since: since)
        let bubbleCounts = queryBubbleCounts(db: db)
        let dailyStats = queryDailyCodeStats(db: db, since: since)

        return buildStats(from: composerEntries, bubbleCounts: bubbleCounts, dailyStats: dailyStats)
    }

    // MARK: - Composer Data Querying

    private struct ComposerEntry {
        let composerId: String
        let createdAt: Date
        let modelName: String
        let mode: String
        let linesAdded: Int
        let linesRemoved: Int
        let status: String
        let isAgentic: Bool
        let bubbleCount: Int
    }

    private static func queryComposerData(db: OpaquePointer?, since: Date?) -> [ComposerEntry] {
        var entries: [ComposerEntry] = []

        let sql = "SELECT value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return entries
        }
        defer { sqlite3_finalize(stmt) }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = parseComposerRow(stmt: stmt, since: since) else {
                continue
            }
            entries.append(entry)
        }

        return entries
    }

    private static func parseComposerRow(stmt: OpaquePointer?, since: Date?) -> ComposerEntry? {
        // Read the blob/text value
        guard let rawBytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let byteCount = Int(sqlite3_column_bytes(stmt, 0))
        guard byteCount > 0 else { return nil }

        let data = Data(bytes: rawBytes, count: byteCount)

        // Parse JSON (allow fragments / control characters)
        guard let json = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            return nil
        }

        // Extract createdAt (milliseconds since epoch)
        let createdAtMs: Double
        if let ms = json["createdAt"] as? Double {
            createdAtMs = ms
        } else if let ms = json["createdAt"] as? Int {
            createdAtMs = Double(ms)
        } else {
            createdAtMs = 0
        }

        let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000.0)

        // Filter by date if requested
        if let since = since, createdAt < since {
            return nil
        }

        // Extract fields
        let composerId = json["composerId"] as? String ?? ""

        let modelConfig = json["modelConfig"] as? [String: Any]
        let modelName = modelConfig?["modelName"] as? String ?? "unknown"

        let mode: String
        if let unifiedMode = json["unifiedMode"] as? String, !unifiedMode.isEmpty {
            mode = unifiedMode
        } else if json["isAgentic"] as? Bool == true {
            mode = "agent"
        } else {
            mode = "chat"
        }

        let linesAdded = json["totalLinesAdded"] as? Int ?? 0
        let linesRemoved = json["totalLinesRemoved"] as? Int ?? 0
        let status = json["status"] as? String ?? "none"
        let isAgentic = json["isAgentic"] as? Bool ?? false

        let conversationMap = json["conversationMap"] as? [String: Any]
        let bubbleCount = conversationMap?.count ?? 0

        return ComposerEntry(
            composerId: composerId,
            createdAt: createdAt,
            modelName: modelName,
            mode: mode,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            status: status,
            isAgentic: isAgentic,
            bubbleCount: bubbleCount
        )
    }

    // MARK: - Bubble Counts Querying

    private struct BubbleCounts {
        var total: Int = 0
        var user: Int = 0
        var assistant: Int = 0
    }

    private static func queryBubbleCounts(db: OpaquePointer?) -> BubbleCounts {
        var counts = BubbleCounts()

        let sql = "SELECT value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return counts
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawBytes = sqlite3_column_blob(stmt, 0) else { continue }
            let byteCount = Int(sqlite3_column_bytes(stmt, 0))
            guard byteCount > 0 else { continue }

            let data = Data(bytes: rawBytes, count: byteCount)

            guard let json = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any] else {
                continue
            }

            counts.total += 1

            if let type = json["type"] as? Int {
                switch type {
                case 1:
                    counts.user += 1
                case 2:
                    counts.assistant += 1
                default:
                    break
                }
            }
        }

        return counts
    }

    // MARK: - Daily Code Stats Querying

    private static func queryDailyCodeStats(db: OpaquePointer?, since: Date?) -> [DailyCodeStats] {
        var results: [DailyCodeStats] = []

        let sql = "SELECT key, value FROM ItemTable WHERE key LIKE 'aiCodeTracking.dailyStats.%'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return results
        }
        defer { sqlite3_finalize(stmt) }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawBytes = sqlite3_column_blob(stmt, 1) else { continue }
            let byteCount = Int(sqlite3_column_bytes(stmt, 1))
            guard byteCount > 0 else { continue }

            let data = Data(bytes: rawBytes, count: byteCount)

            guard let json = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any] else {
                continue
            }

            let dateStr = json["date"] as? String ?? ""

            // Filter by date if requested
            if let since = since, !dateStr.isEmpty {
                if let entryDate = dateFormatter.date(from: dateStr), entryDate < since {
                    continue
                }
            }

            let entry = DailyCodeStats(
                date: dateStr,
                tabSuggestedLines: json["tabSuggestedLines"] as? Int ?? 0,
                tabAcceptedLines: json["tabAcceptedLines"] as? Int ?? 0,
                composerSuggestedLines: json["composerSuggestedLines"] as? Int ?? 0,
                composerAcceptedLines: json["composerAcceptedLines"] as? Int ?? 0
            )
            results.append(entry)
        }

        return results.sorted { $0.date > $1.date }
    }

    // MARK: - Stats Aggregation

    private static func buildStats(from entries: [ComposerEntry], bubbleCounts: BubbleCounts, dailyStats: [DailyCodeStats]) -> CursorStats {
        var stats = CursorStats.empty()

        stats.totalSessions = entries.count
        stats.totalMessages = bubbleCounts.total
        stats.userMessages = bubbleCounts.user
        stats.assistantMessages = bubbleCounts.assistant

        var modelUsage: [String: Int] = [:]
        var earliest: Date?
        var latest: Date?

        for entry in entries {
            // Count session modes
            switch entry.mode {
            case "chat":
                stats.chatSessions += 1
            case "agent":
                stats.agentSessions += 1
            case "edit":
                stats.editSessions += 1
            default:
                stats.chatSessions += 1
            }

            // Aggregate lines
            stats.totalLinesAdded += entry.linesAdded
            stats.totalLinesRemoved += entry.linesRemoved

            // Model usage
            modelUsage[entry.modelName, default: 0] += 1

            // Date range
            if earliest == nil || entry.createdAt < earliest! {
                earliest = entry.createdAt
            }
            if latest == nil || entry.createdAt > latest! {
                latest = entry.createdAt
            }
        }

        stats.modelUsage = modelUsage
        stats.dateRange = (earliest, latest)

        // Build recent sessions (sorted by date descending, up to 50)
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        stats.recentSessions = sorted.prefix(50).map { entry in
            (
                id: entry.composerId,
                date: entry.createdAt,
                model: entry.modelName,
                mode: entry.mode,
                linesAdded: entry.linesAdded,
                linesRemoved: entry.linesRemoved
            )
        }

        // AI Code Tracking
        stats.dailyCodeStats = dailyStats
        stats.totalTabSuggested = dailyStats.reduce(0) { $0 + $1.tabSuggestedLines }
        stats.totalTabAccepted = dailyStats.reduce(0) { $0 + $1.tabAcceptedLines }
        stats.totalComposerSuggested = dailyStats.reduce(0) { $0 + $1.composerSuggestedLines }
        stats.totalComposerAccepted = dailyStats.reduce(0) { $0 + $1.composerAcceptedLines }

        return stats
    }
}
