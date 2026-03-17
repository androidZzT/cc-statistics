import SwiftUI

// MARK: - Color Palette

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Theme

enum Theme {
    static let background = Color(hex: "1A1B2E")
    static let cardBackground = Color(hex: "252640")
    static let cardBackgroundLight = Color(hex: "2E2F4A")
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "9CA3AF")
    static let textTertiary = Color(hex: "6B7280")
    static let border = Color.white.opacity(0.06)

    static let cyan = Color(hex: "00D4FF")
    static let purple = Color(hex: "8B5CF6")
    static let pink = Color(hex: "EC4899")
    static let green = Color(hex: "10B981")
    static let amber = Color(hex: "F59E0B")
    static let blue = Color(hex: "3B82F6")
    static let red = Color(hex: "EF4444")
    static let indigo = Color(hex: "6366F1")
    static let teal = Color(hex: "14B8A6")
    static let orange = Color(hex: "F97316")

    static let gradientCyanBlue = LinearGradient(
        colors: [cyan, blue],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let gradientPurplePink = LinearGradient(
        colors: [purple, pink],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let gradientGreenTeal = LinearGradient(
        colors: [green, teal],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let gradientAmberOrange = LinearGradient(
        colors: [amber, orange],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let barGradientColors: [Color] = [
        cyan, blue, indigo, purple, pink, teal, green, amber, orange, red
    ]
}

// MARK: - StatCard

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accentColor)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.12), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - SectionHeader

struct SectionHeader: View {
    let icon: String
    let title: String
    var accentColor: Color = Theme.cyan

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(accentColor)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - BarChartRow

struct BarChartRow: View {
    let label: String
    let value: Int
    let maxValue: Int
    let color: Color
    let rank: Int

    private var fillFraction: CGFloat {
        guard maxValue > 0 else { return 0 }
        return CGFloat(value) / CGFloat(maxValue)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 14, alignment: .trailing)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 14)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * fillFraction, 4), height: 14)
                        .shadow(color: color.opacity(0.3), radius: 4, x: 0, y: 0)
                }
            }
            .frame(height: 14)

            Text(formatCount(value))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}

// MARK: - ActivityRing

struct ActivityRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let size: CGFloat
    var gradientColors: [Color] = [Theme.cyan, Theme.purple]
    var label: String = ""

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: lineWidth)

            // Fill
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    AngularGradient(
                        colors: gradientColors + [gradientColors.first ?? Theme.cyan],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: gradientColors.first?.opacity(0.4) ?? .clear, radius: 6, x: 0, y: 0)

            // Center text
            VStack(spacing: 2) {
                Text("\(Int(clampedProgress * 100))%")
                    .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: size * 0.1, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - LanguageDot

struct LanguageDot: View {
    let language: String
    let additions: Int
    let deletions: Int

    var color: Color {
        LanguageDot.colorForLanguage(language)
    }

    static func colorForLanguage(_ lang: String) -> Color {
        switch lang.lowercased() {
        case "swift":             return Theme.orange
        case "python":            return Theme.blue
        case "javascript", "js":  return Theme.amber
        case "typescript", "ts":  return Theme.blue
        case "rust":              return Theme.orange
        case "go":                return Theme.cyan
        case "ruby":              return Theme.red
        case "java":              return Theme.red
        case "c", "cpp", "c++":   return Theme.indigo
        case "html":              return Theme.pink
        case "css", "scss":       return Theme.purple
        case "json":              return Theme.amber
        case "yaml", "yml":       return Theme.green
        case "shell", "bash", "sh", "zsh": return Theme.green
        case "markdown", "md":    return Theme.textSecondary
        case "sql":               return Theme.teal
        case "kotlin":            return Theme.purple
        case "dart":              return Theme.cyan
        default:                  return Theme.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.5), radius: 3, x: 0, y: 0)

            Text(language)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 10) {
                Text("+\(additions)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.green)
                Text("-\(deletions)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.red)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - TokenPill

struct TokenPill: View {
    let label: String
    let count: Int
    let color: Color
    var fraction: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 3, height: 14)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            Spacer()

            Text(formatTokens(count))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}

// MARK: - TokenStackedBar

struct TokenStackedBar: View {
    let segments: [(label: String, value: Int, color: Color)]
    let height: CGFloat

    private var total: Int {
        segments.reduce(0) { $0 + $1.value }
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let fraction = total > 0 ? CGFloat(segment.value) / CGFloat(total) : 0
                        if fraction > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [segment.color, segment.color.opacity(0.7)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: max(geometry.size.width * fraction - 1, 2))
                        }
                    }
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )

            // Legend
            HStack(spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 6, height: 6)
                        Text(segment.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - TimeBreakdownRow

struct TimeBreakdownRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
    }
}

// MARK: - ShimmerView (loading placeholder)

struct ShimmerView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.05),
                                .clear
                            ],
                            startPoint: .init(x: phase - 0.5, y: 0.5),
                            endPoint: .init(x: phase + 0.5, y: 0.5)
                        )
                    )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

// MARK: - GlassCard (container)

struct GlassCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            )
    }
}
