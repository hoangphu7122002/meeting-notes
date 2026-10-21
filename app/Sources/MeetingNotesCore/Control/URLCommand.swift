// Parsing of meetingnotes:// URLs into app commands (Control).

import Foundation

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
