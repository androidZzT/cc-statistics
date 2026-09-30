import Foundation

struct LoadingProgressState: Equatable {
    var stage: String
    var detail: String
    var completed: Int
    var total: Int
    private var explicitFraction: Double?

    init(
        stage: String = "",
        detail: String = "",
        completed: Int = 0,
        total: Int = 0,
        fraction: Double? = nil
    ) {
        self.stage = stage
        self.detail = detail
        self.completed = completed
        self.total = total
        self.explicitFraction = fraction
    }

    static let idle = LoadingProgressState()

    var fraction: Double {
        let raw: Double
        if let explicitFraction {
            raw = explicitFraction
        } else if total > 0 {
            raw = Double(completed) / Double(total)
        } else {
            raw = 0
        }
        return min(max(raw, 0), 1)
    }

    var percentText: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    var countText: String? {
        guard total > 0 else { return nil }
        return "\(max(completed, 0))/\(total)"
    }
}

enum LoadingProgressSmoothing {
    static func shouldResetDisplay(from current: Double, to target: Double) -> Bool {
        clamped(target) < clamped(current) - 0.15
    }

    static func animationDuration(from current: Double, to target: Double) -> Double {
        let delta = abs(clamped(target) - clamped(current))
        return min(2.4, max(0.45, delta * 2.8))
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
