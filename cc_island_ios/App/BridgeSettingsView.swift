import SwiftUI

struct BridgeSettingsView: View {
    @AppStorage(
        BridgeConfiguration.baseURLKey,
        store: UserDefaults(suiteName: BridgeConfiguration.appGroupID)
    ) private var bridgeBaseURL: String = "http://127.0.0.1:8765"

    @State private var draftURL: String = ""
    @State private var lastSavedAt: Date?

    var body: some View {
        Form {
            Section("Bridge URL") {
                TextField("http://192.168.1.10:8765", text: $draftURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                HStack {
                    Button("Save") {
                        bridgeBaseURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        lastSavedAt = Date()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Use Localhost") {
                        draftURL = "http://127.0.0.1:8765"
                        bridgeBaseURL = draftURL
                        lastSavedAt = Date()
                    }
                    .buttonStyle(.bordered)
                }
                if let lastSavedAt {
                    Text("Saved at \(lastSavedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Current") {
                Text(bridgeBaseURL)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Bridge Settings")
        .onAppear {
            draftURL = bridgeBaseURL
        }
    }
}

#Preview {
    NavigationStack {
        BridgeSettingsView()
    }
}
