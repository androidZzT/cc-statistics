import SwiftUI
import ServiceManagement

// MARK: - SettingsView

struct SettingsView: View {
    @Binding var isPresented: Bool
    var onLanguageChanged: (() -> Void)?
    @State private var launchAtLogin: Bool = false
    @State private var language: String = "auto"

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
                                Text("v0.5.1")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer()
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
        }
        .onChange(of: launchAtLogin) { newValue in
            toggleLaunchAtLogin(newValue)
        }
        .onChange(of: language) { newValue in
            saveLanguageSetting(newValue)
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

    // MARK: - Settings Logic

    private func loadSettings() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        language = UserDefaults.standard.string(forKey: "cc_stats_language") ?? "auto"
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
}
