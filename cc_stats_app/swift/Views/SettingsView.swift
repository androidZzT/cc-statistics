import SwiftUI
import ServiceManagement

// MARK: - SettingsView

struct SettingsView: View {
    @Binding var isPresented: Bool
    var onLanguageChanged: (() -> Void)?
    var onThemeChanged: ((String) -> Void)?
    @State private var launchAtLogin: Bool = false
    @State private var language: String = "auto"
    @State private var theme: String = "auto"
    @State private var dailyCostLimit: String = ""
    @State private var weeklyCostLimit: String = ""
    @State private var latestVersion: String?
    @State private var checkingUpdate: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L10n.settings)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle().fill(Theme.cardBackground)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().background(Theme.border)

            ScrollView {
                VStack(spacing: 16) {
                    // General section
                    settingsSection(title: L10n.general, icon: "gearshape.fill") {
                        // Launch at login
                        settingsToggle(
                            icon: "power",
                            title: L10n.launchAtLogin,
                            subtitle: L10n.launchAtLoginDesc,
                            isOn: $launchAtLogin
                        )
                    }

                    // Language section
                    settingsSection(title: L10n.language, icon: "globe") {
                        settingsPicker(
                            icon: "character.bubble",
                            title: L10n.displayLanguage,
                            selection: $language,
                            options: [
                                ("auto", L10n.followSystem),
                                ("zh", "中文"),
                                ("en", "English"),
                            ]
                        )
                    }

                    // Appearance section
                    settingsSection(title: L10n.appearance, icon: "paintbrush.fill") {
                        settingsPicker(
                            icon: "circle.lefthalf.filled",
                            title: L10n.theme,
                            selection: $theme,
                            options: [
                                ("auto", L10n.themeAuto),
                                ("dark", L10n.themeDark),
                                ("light", L10n.themeLight),
                            ]
                        )
                    }

                    // Alerts section
                    settingsSection(title: L10n.alerts, icon: "exclamationmark.triangle.fill") {
                        alertInput(
                            icon: "sun.max",
                            title: L10n.dailyCostLimit,
                            subtitle: L10n.dailyCostLimitDesc,
                            text: $dailyCostLimit,
                            key: "cc_stats_daily_cost_limit"
                        )
                        Divider().background(Theme.border)
                        alertInput(
                            icon: "calendar",
                            title: L10n.weeklyCostLimit,
                            subtitle: L10n.weeklyCostLimitDesc,
                            text: $weeklyCostLimit,
                            key: "cc_stats_weekly_cost_limit"
                        )
                    }

                    // About section
                    settingsSection(title: L10n.about, icon: "info.circle.fill") {
                        HStack {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.cyan)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("CC Statistics")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text("v\(currentVersion)")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()

                            if let latest = latestVersion, latest != currentVersion {
                                Button {
                                    NSWorkspace.shared.open(URL(string: "https://github.com/androidZzT/cc-statistics/releases/latest")!)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.system(size: 9))
                                        Text("v\(latest)")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Theme.green)
                                    )
                                }
                                .buttonStyle(.plain)
                            } else if checkingUpdate {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            }

                            Button {
                                NSWorkspace.shared.open(URL(string: "https://github.com/androidZzT/cc-statistics")!)
                            } label: {
                                Text("GitHub")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Theme.cyan)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 480)
        .background(Theme.background)
        .onAppear {
            loadSettings()
            checkForUpdate()
        }
        .onChange(of: launchAtLogin) { newValue in
            toggleLaunchAtLogin(newValue)
        }
        .onChange(of: language) { newValue in
            saveLanguageSetting(newValue)
        }
        .onChange(of: theme) { newValue in
            saveThemeSetting(newValue)
        }
    }

    // MARK: - Section Builder

    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: icon, title: title, accentColor: Theme.cyan)
                content()
            }
        }
    }

    // MARK: - Toggle Row

    private func settingsToggle(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Theme.purple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.7)
        }
    }

    // MARK: - Picker Row

    private func settingsPicker(icon: String, title: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Theme.green)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }
    }

    // MARK: - Alert Input

    private func alertInput(icon: String, title: String, subtitle: String, text: Binding<String>, key: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Theme.amber)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            Spacer()
            HStack(spacing: 2) {
                Text("$")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                TextField("0", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 50)
                    .foregroundColor(Theme.textPrimary)
                    .onChange(of: text.wrappedValue) { newValue in
                        let filtered = newValue.filter { $0.isNumber || $0 == "." }
                        if filtered != newValue { text.wrappedValue = filtered }
                        UserDefaults.standard.set(Double(filtered) ?? 0, forKey: key)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.cardBackground)
            )
        }
    }

    // MARK: - Version

    static let appVersion = "0.6.2"
    private var currentVersion: String { Self.appVersion }

    private func checkForUpdate() {
        guard !checkingUpdate else { return }
        checkingUpdate = true

        // 查询 GitHub Releases 最新版本
        guard let url = URL(string: "https://api.github.com/repos/androidZzT/cc-statistics/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { DispatchQueue.main.async { checkingUpdate = false } }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }
            // tag_name 格式为 "v0.6.1"，去掉 "v" 前缀
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            DispatchQueue.main.async {
                latestVersion = version
            }
        }.resume()
    }

    // MARK: - Settings Logic

    private func loadSettings() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        language = UserDefaults.standard.string(forKey: "cc_stats_language") ?? "auto"
        theme = UserDefaults.standard.string(forKey: "cc_stats_theme") ?? "auto"
        let daily = UserDefaults.standard.double(forKey: "cc_stats_daily_cost_limit")
        dailyCostLimit = daily > 0 ? String(format: "%.0f", daily) : ""
        let weekly = UserDefaults.standard.double(forKey: "cc_stats_weekly_cost_limit")
        weeklyCostLimit = weekly > 0 ? String(format: "%.0f", weekly) : ""
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {}
        }
    }

    private func saveLanguageSetting(_ lang: String) {
        UserDefaults.standard.set(lang, forKey: "cc_stats_language")
        onLanguageChanged?()
    }

    private func saveThemeSetting(_ theme: String) {
        UserDefaults.standard.set(theme, forKey: "cc_stats_theme")
        onThemeChanged?(theme)
    }
}
