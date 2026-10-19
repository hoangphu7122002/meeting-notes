import Foundation

public enum Format {
    /// `03:07` or `1:02:03`.
    public static func elapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "about 2 min left", "less than a minute left", "about 1 h 5 min left"; nil when unknown.
    public static func eta(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 45 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(max(1, minutes)) min left" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "about \(h) h left" : "about \(h) h \(m) min left"
    }

    /// Compact duration: "45 s", "12 min", "1 h 5 min".
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Transcript timestamp: `4:05` or `1:04:05`.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// Single line, clipped with an ellipsis.
    public static func clip(_ text: String, _ limit: Int = 90) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(max(1, limit - 1))) + "…" : single
    }
}

/// `meetingnotes://<command>` (also `meetingnotes:<command>` and `meetingnotes:///<command>`).
public enum URLCommand: String, CaseIterable, Sendable {
    case start, stop, pause, resume, toggle, show

    public static let scheme = "meetingnotes"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        var name = url.host ?? ""
        if name.isEmpty {
            name = url.pathComponents.first(where: { $0 != "/" }) ?? ""
        }
        if name.isEmpty, let rest = url.absoluteString.split(separator: ":", maxSplits: 1).last {
            name = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        self.init(rawValue: name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }
}
