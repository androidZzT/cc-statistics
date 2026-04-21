import Foundation

enum BridgeTaskStatus: String, Codable, Hashable {
    case idle = "IDLE"
    case running = "RUNNING"
    case waitingApproval = "WAITING_APPROVAL"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case canceled = "CANCELED"
}

struct BridgeUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
    }
}

struct BridgeTask: Codable, Hashable {
    var taskID: String
    var sessionID: String
    var title: String
    var repo: String
    var model: String
    var status: BridgeTaskStatus
    var phase: String
    var summary: String
    var durationSec: Int
    var usage: BridgeUsage
    var startedAt: Date
    var updatedAt: Date
    var errorMessage: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case sessionID = "session_id"
        case title
        case repo
        case model
        case status
        case phase
        case summary
        case durationSec = "duration_sec"
        case usage
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case errorMessage = "error_message"
    }
}

struct BridgeTaskListResponse: Codable {
    let tasks: [BridgeTask]
}

struct BridgeApprovalItem: Codable, Hashable {
    var approvalID: String
    var taskID: String
    var tool: String
    var action: String
    var risk: String
    var reason: String
    var expiresAt: Date
    var resolved: Bool
    var approved: Bool?

    enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id"
        case taskID = "task_id"
        case tool
        case action
        case risk
        case reason
        case expiresAt = "expires_at"
        case resolved
        case approved
    }
}

struct BridgeApprovalListResponse: Codable {
    let items: [BridgeApprovalItem]
}

enum BridgeEventType: String, Codable, Hashable {
    case taskStarted = "task_started"
    case taskProgress = "task_progress"
    case approvalRequired = "approval_required"
    case approvalResolved = "approval_resolved"
    case taskCompleted = "task_completed"
    case taskFailed = "task_failed"
    case taskCanceled = "task_canceled"
}

struct BridgeEventEnvelope: Codable, Hashable {
    let version: Int
    let eventID: String
    let type: BridgeEventType
    let taskID: String
    let sessionID: String
    let timestamp: Date
    let source: String
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case version
        case eventID = "event_id"
        case type
        case taskID = "task_id"
        case sessionID = "session_id"
        case timestamp
        case source
        case payload
    }
}

struct BridgeResolveApprovalRequest: Encodable {
    let approved: Bool
    let timestamp: Date
    let nonce: String
    let signature: String
    let resolver: String

    init(approved: Bool, nonce: String, signature: String, resolver: String = "ios_device") {
        self.approved = approved
        self.timestamp = Date()
        self.nonce = nonce
        self.signature = signature
        self.resolver = resolver
    }
}

struct BridgeResolveApprovalResponse: Codable {
    let accepted: Bool
    let approvalID: String
    let approved: Bool

    enum CodingKeys: String, CodingKey {
        case accepted
        case approvalID = "approval_id"
        case approved
    }
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            if value.caseInsensitiveCompare("true") == .orderedSame {
                return true
            }
            if value.caseInsensitiveCompare("false") == .orderedSame {
                return false
            }
            return nil
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func int(_ key: String) -> Int? {
        self[key]?.intValue
    }

    func double(_ key: String) -> Double? {
        self[key]?.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func object(_ key: String) -> [String: JSONValue]? {
        self[key]?.objectValue
    }
}
