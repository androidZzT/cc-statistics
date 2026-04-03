import SwiftUI
import ServiceManagement

// MARK: - SettingsView

struct SettingsView: View {
    @Binding var isPresented: Bool
    var onLanguageChanged: (() -> Void)?
    var onThemeChanged: ((String) -> Void)?
    var onModulesChanged: (() -> Void)?
    @State private var launchAtLogin: Bool = false
    @State private var language: String = "auto"
    @State private var theme: String = "auto"
    @State private var dailyCostLimit: String = ""
    @State private var weeklyCostLimit: String = ""
    @State private var apiToken: String = ""
    @State private var latestVersion: String?
    @State private var checkingUpdate: Bool = false
    // Notification settings
    @State private var notifySessionComplete: Bool = true
    @State private var notifyCostAlert: Bool = true
    @State private var notifyPermission: Bool = true
    @State private var notifySmartSuppress: Bool = true
    @State private var notifyWebhookURL: String = ""
    @State private var hooksInstalled: Bool = false
    @State private var notifyTestSent: Bool = false

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

                    // Dashboard Modules section
                    settingsSection(title: L10n.dashboardModules, icon: "square.grid.2x2.fill") {
                        // Core modules (always visible, not toggleable)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.coreModules)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.bottom, 2)

                            ForEach(
                                [
                                    ("chart.bar.fill", L10n.headerCardsLabel),
                                    ("circle.hexagonpath.fill", L10n.tokenUsageLabel),
                                    ("chart.xyaxis.line", L10n.trendChartLabel),
                                ],
                                id: \.1
                            ) { icon, label in
                                HStack(spacing: 8) {
                                    Image(systemName: icon)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.cyan)
                                        .frame(width: 20)
                                    Text(label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Theme.textSecondary)
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.green.opacity(0.6))
                                }
                                .frame(height: 24)
                            }
                        }

                        Divider().background(Theme.border)

                        // Optional modules (toggleable)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.optionalModules)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.bottom, 2)

                            ForEach(DashboardModule.allCases) { module in
                                moduleToggleRow(module: module)
                            }
                        }
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

                    // Notifications section
                    settingsSection(title: L10n.notifications, icon: "bell.fill") {
                        settingsToggle(
                            icon: "checkmark.circle",
                            title: L10n.notifySessionComplete,
                            subtitle: L10n.notifySessionCompleteDesc,
                            isOn: $notifySessionComplete
                        )
                        Divider().background(Theme.border)
                        settingsToggle(
                            icon: "dollarsign.circle",
                            title: L10n.notifyCostAlert,
                            subtitle: L10n.notifyCostAlertDesc,
                            isOn: $notifyCostAlert
                        )
                        Divider().background(Theme.border)
                        settingsToggle(
                            icon: "lock.shield",
                            title: L10n.notifyPermission,
                            subtitle: L10n.notifyPermissionDesc,
                            isOn: $notifyPermission
                        )
                        Divider().background(Theme.border)
                        settingsToggle(
                            icon: "eye.slash",
                            title: L10n.notifySmartSuppress,
                            subtitle: L10n.notifySmartSuppressDesc,
                            isOn: $notifySmartSuppress
                        )
                        Divider().background(Theme.border)

                        // Webhook URL
                        HStack {
                            Image(systemName: "link")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.cyan)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.notifyWebhook)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(L10n.notifyWebhookDesc)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
                        }
                        HStack(spacing: 6) {
                            TextField(L10n.notifyWebhookPlaceholder, text: $notifyWebhookURL)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            if !notifyWebhookURL.isEmpty {
                                Button {
                                    notifyWebhookURL = ""
                                    saveNotifyConfig()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.cardBackground)
                        )
                        .onChange(of: notifyWebhookURL) { _ in
                            saveNotifyConfig()
                        }

                        Divider().background(Theme.border)

                        // Hook install status + actions
                        HStack {
                            Image(systemName: "terminal")
                                .font(.system(size: 12))
                                .foregroundColor(hooksInstalled ? Theme.green : Theme.amber)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.installHooks)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(L10n.installHooksDesc)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
                            Text(hooksInstalled ? L10n.hooksInstalled : L10n.hooksNotInstalled)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(hooksInstalled ? Theme.green : Theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(hooksInstalled ? Theme.green.opacity(0.15) : Theme.cardBackground)
                                )
                            Button {
                                installOrUninstallHooks()
                            } label: {
                                Text(hooksInstalled ? "Uninstall" : "Install")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(hooksInstalled ? Color.red.opacity(0.8) : Theme.cyan)
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        // Test notification button
                        HStack {
                            Spacer()
                            Button {
                                sendTestNotification()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: notifyTestSent ? "checkmark.circle.fill" : "bell.badge")
                                        .font(.system(size: 9))
                                    Text(notifyTestSent ? L10n.notifySent : L10n.testNotification)
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundColor(notifyTestSent ? Theme.green : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(notifyTestSent ? Theme.green.opacity(0.15) : Theme.purple)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Rate Limit section
                    settingsSection(title: L10n.rateLimit, icon: "gauge.with.dots.needle.50percent") {
                        HStack {
                            Image(systemName: "key")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.cyan)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.apiToken)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(L10n.apiTokenDesc)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
                            Button {
                                autoFetchToken()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 9))
                                    Text(L10n.isChinese ? "自动获取" : "Auto Fetch")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Theme.cyan)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            SecureField(L10n.apiTokenPlaceholder, text: $apiToken)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            if !apiToken.isEmpty {
                                Button {
                                    apiToken = ""
                                    UserDefaults.standard.set("", forKey: UsageAPI.tokenKey)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.cardBackground)
                        )
                        .onChange(of: apiToken) { newValue in
                            UserDefaults.standard.set(newValue, forKey: UsageAPI.tokenKey)
                        }
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
            loadNotifyConfig()
            checkHooksInstalled()
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
        .onChange(of: notifySessionComplete) { _ in saveNotifyConfig() }
        .onChange(of: notifyCostAlert) { _ in saveNotifyConfig() }
        .onChange(of: notifyPermission) { _ in saveNotifyConfig() }
        .onChange(of: notifySmartSuppress) { _ in saveNotifyConfig() }
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

    // MARK: - Module Toggle Row

    private func moduleToggleRow(module: DashboardModule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: module.icon)
                .font(.system(size: 11))
                .foregroundColor(Theme.purple)
                .frame(width: 20)
            Text(module.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { module.isVisible },
                set: { newValue in
                    module.isVisible = newValue
                    onModulesChanged?()
                }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.7)
        }
        .frame(height: 26)
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

    static let fallbackVersion = "0.12.11"

    /// 动态读取 Python 层写入的版本号，fallback 到编译时默认值
    static var appVersion: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let versionFile = home.appendingPathComponent(".cc-stats/current_version")
        if let version = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return version
        }
        return fallbackVersion
    }

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
        apiToken = UserDefaults.standard.string(forKey: UsageAPI.tokenKey) ?? ""
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
        print("[CCStats] saveThemeSetting: theme=\(theme)")
        UserDefaults.standard.set(theme, forKey: "cc_stats_theme")
        onThemeChanged?(theme)
    }

    // MARK: - Notification Config

    private static let notifyConfigPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-stats/notify_config.json")
    }()

    private func loadNotifyConfig() {
        guard let data = try? Data(contentsOf: Self.notifyConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        notifySessionComplete = json["session_complete"] as? Bool ?? true
        notifyCostAlert = json["cost_alert"] as? Bool ?? true
        notifyPermission = json["permission_request"] as? Bool ?? true
        notifySmartSuppress = json["smart_suppress"] as? Bool ?? true
        notifyWebhookURL = json["webhook_url"] as? String ?? ""
    }

    private func saveNotifyConfig() {
        let config: [String: Any] = [
            "enabled": true,
            "session_complete": notifySessionComplete,
            "cost_alert": notifyCostAlert,
            "permission_request": notifyPermission,
            "smart_suppress": notifySmartSuppress,
            "webhook_url": notifyWebhookURL,
            "webhook_platform": "auto",
            "sound": "Glass",
        ]
        let dir = Self.notifyConfigPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.notifyConfigPath)
        }
    }

    private func checkHooksInstalled() {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            hooksInstalled = false
            return
        }
        // 检查 Stop hooks 中是否包含 cc_stats.hooks
        if let stopHooks = hooks["Stop"] as? [[String: Any]] {
            hooksInstalled = stopHooks.contains { hook in
                (hook["command"] as? String ?? "").contains("cc_stats.hooks")
            }
        } else {
            hooksInstalled = false
        }
    }

    private func installOrUninstallHooks() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = hooksInstalled
            ? ["python3", "-m", "cc_stats.hooks_cli", "--uninstall"]
            : ["python3", "-c", """
              from cc_stats.hooks import install_hooks; install_hooks('user')
              """]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        // 直接操作 JSON 作为 fallback
        if !hooksInstalled {
            installHooksDirect()
        } else {
            uninstallHooksDirect()
        }
        checkHooksInstalled()
    }

    private func installHooksDirect() {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookCmd = "python3 -m cc_stats.hooks"

        for event in ["Stop", "PreToolUse"] {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            let alreadyExists = eventHooks.contains { ($0["command"] as? String ?? "").contains("cc_stats.hooks") }
            if !alreadyExists {
                eventHooks.append(["type": "command", "command": hookCmd])
            }
            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks

        let dir = settingsPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsPath)
        }
    }

    private func uninstallHooksDirect() {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in ["Stop", "PreToolUse"] {
            if var eventHooks = hooks[event] as? [[String: Any]] {
                eventHooks.removeAll { ($0["command"] as? String ?? "").contains("cc_stats.hooks") }
                if eventHooks.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = eventHooks
                }
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        if let newData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: settingsPath)
        }
    }

    private func sendTestNotification() {
        let title = "CC Stats 通知测试"
        let body = L10n.isChinese ? "通知功能正常工作 ✓" : "Notification is working ✓"
        NotificationManager.shared.send(title: title, body: body)
        notifyTestSent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            notifyTestSent = false
        }
    }

    // MARK: - Debug Animation

    private func autoFetchToken() {
        let username = NSUserName()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-a", username,
            "-w",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  !token.isEmpty else {
                return
            }
            apiToken = token
            UserDefaults.standard.set(token, forKey: UsageAPI.tokenKey)
        } catch {
            // Keychain access failed — user may have denied the prompt
        }
    }
}
