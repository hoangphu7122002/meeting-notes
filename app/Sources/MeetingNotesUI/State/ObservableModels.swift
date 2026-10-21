// Small observable models (clock, levels, UI language) kept apart from AppState to limit re-renders (State).

import Foundation
import MeetingNotesCore
import SwiftUI

/// Elapsed time, published once per second while recording.
@MainActor
public final class ClockModel: ObservableObject {
    @Published public var elapsed = "00:00"
    public init() {}
}

/// Me/Them meter values (0...1), published only while a meter is visible and recording.
@MainActor
public final class LevelModel: ObservableObject {
    @Published public var me: Double = 0
    @Published public var them: Double = 0
    public init() {}
}

/// Publishes the UI language so every window re-renders when it changes (no restart).
@MainActor
public final class LanguageModel: ObservableObject {
    public static let shared = LanguageModel()
    @Published public private(set) var current: UILanguage = L10n.language

    public func set(_ language: UILanguage) {
        L10n.language = language
        if current != language { current = language }
    }
}

/// Root wrapper of every hosted view: rebuilds the tree when the language changes.
public struct Localized<Content: View>: View {
    @ObservedObject private var language = LanguageModel.shared
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .id(language.current)
            .environment(\.locale, language.current.locale)
    }
}
