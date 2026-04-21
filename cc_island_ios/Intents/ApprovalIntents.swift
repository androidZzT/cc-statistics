import AppIntents
import Foundation

@available(iOSApplicationExtension 17.0, *)
struct ApproveApprovalIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Approve"
    static var description = IntentDescription("Approve pending Claude Code action.")

    @Parameter(title: "Approval ID")
    var approvalID: String

    init() {}

    init(approvalID: String) {
        self.approvalID = approvalID
    }

    func perform() async throws -> some IntentResult {
        guard !approvalID.isEmpty else { return .result() }
        _ = try await BridgeIntentClient.shared.resolveApproval(id: approvalID, approved: true)
        return .result()
    }
}

@available(iOSApplicationExtension 17.0, *)
struct RejectApprovalIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Reject"
    static var description = IntentDescription("Reject pending Claude Code action.")

    @Parameter(title: "Approval ID")
    var approvalID: String

    init() {}

    init(approvalID: String) {
        self.approvalID = approvalID
    }

    func perform() async throws -> some IntentResult {
        guard !approvalID.isEmpty else { return .result() }
        _ = try await BridgeIntentClient.shared.resolveApproval(id: approvalID, approved: false)
        return .result()
    }
}

actor BridgeIntentClient {
    static let shared = BridgeIntentClient()

    private let session = URLSession.shared
    private let decoder = JSONDecoder.bridgeDecoder()
    private let encoder = JSONEncoder.bridgeEncoder()

    func resolveApproval(id: String, approved: Bool) async throws -> BridgeResolveApprovalResponse {
        let baseURL = BridgeConfiguration.bridgeBaseURL()
        guard let url = URL(string: "/v1/approvals/\(id):resolve", relativeTo: baseURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = BridgeResolveApprovalRequest(
            approved: approved,
            nonce: UUID().uuidString,
            signature: UUID().uuidString.replacingOccurrences(of: "-", with: "")
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.cannotParseResponse)
        }
        return try decoder.decode(BridgeResolveApprovalResponse.self, from: data)
    }
}
