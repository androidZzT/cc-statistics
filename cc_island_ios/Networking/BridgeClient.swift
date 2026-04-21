import Foundation

enum BridgeClientError: Error {
    case invalidURL
    case invalidResponse
    case unexpectedStatus(Int)
}

final class BridgeClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = BridgeConfiguration.bridgeBaseURL(), session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder.bridgeDecoder()
        self.encoder = JSONEncoder.bridgeEncoder()
    }

    func health() async throws -> Bool {
        let url = try endpoint("/v1/health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try ensure2xx(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["ok"] as? Bool) == true
    }

    func currentTask() async throws -> BridgeTask? {
        let url = try endpoint("/v1/tasks/current")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try ensure2xx(response)
        if data.isEmpty || data == Data("{}".utf8) {
            return nil
        }
        return try decoder.decode(BridgeTask.self, from: data)
    }

    func listTasks(limit: Int = 20) async throws -> [BridgeTask] {
        var components = URLComponents(url: try endpoint("/v1/tasks"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw BridgeClientError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try ensure2xx(response)
        return try decoder.decode(BridgeTaskListResponse.self, from: data).tasks
    }

    func pendingApprovals() async throws -> [BridgeApprovalItem] {
        let url = try endpoint("/v1/approvals")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try ensure2xx(response)
        return try decoder.decode(BridgeApprovalListResponse.self, from: data).items
    }

    func resolveApproval(approvalID: String, approved: Bool) async throws -> BridgeResolveApprovalResponse {
        let url = try endpoint("/v1/approvals/\(approvalID):resolve")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = BridgeResolveApprovalRequest(
            approved: approved,
            nonce: UUID().uuidString,
            signature: UUID().uuidString.replacingOccurrences(of: "-", with: "")
        )
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try ensure2xx(response)
        return try decoder.decode(BridgeResolveApprovalResponse.self, from: data)
    }

    func eventStream(lastEventID: String? = nil) -> AsyncThrowingStream<BridgeEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var request = URLRequest(url: try endpoint("/v1/events/stream"))
                request.httpMethod = "GET"
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let lastEventID, !lastEventID.isEmpty {
                    request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
                }

                let (bytes, response) = try await session.bytes(for: request)
                try ensure2xx(response)

                var currentID: String?
                var currentType: String?
                var dataLines: [String] = []

                for try await line in bytes.lines {
                    if line.isEmpty {
                        if !dataLines.isEmpty {
                            let raw = dataLines.joined(separator: "\n")
                            if let eventData = raw.data(using: .utf8) {
                                var envelope = try decoder.decode(BridgeEventEnvelope.self, from: eventData)
                                if let currentID, envelope.eventID.isEmpty {
                                    envelope = BridgeEventEnvelope(
                                        version: envelope.version,
                                        eventID: currentID,
                                        type: envelope.type,
                                        taskID: envelope.taskID,
                                        sessionID: envelope.sessionID,
                                        timestamp: envelope.timestamp,
                                        source: envelope.source,
                                        payload: envelope.payload
                                    )
                                }
                                continuation.yield(envelope)
                            }
                        }
                        currentID = nil
                        currentType = nil
                        dataLines.removeAll(keepingCapacity: true)
                        continue
                    }
                    if line.hasPrefix(":") {
                        continue
                    }
                    if line.hasPrefix("id:") {
                        currentID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        continue
                    }
                    if line.hasPrefix("event:") {
                        currentType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        _ = currentType
                        continue
                    }
                    if line.hasPrefix("data:") {
                        dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw BridgeClientError.invalidURL
        }
        return url
    }

    private func ensure2xx(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BridgeClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw BridgeClientError.unexpectedStatus(http.statusCode)
        }
    }
}
