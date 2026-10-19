import MeetingNotesCore
import SwiftUI

/// Chrome of the small floating cards (same surface as the pill).
struct CardChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .font(.system(size: 13))
            .foregroundStyle(Palette.label)
            .padding(16)
            .frame(width: 340, alignment: .leading)
            .background(SurfaceBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
    }
}

/// "Zoom is using the microphone — start notes?"
public struct DetectionCardView: View {
    let appName: String
    let onStart: () -> Void
    let onNotNow: () -> Void
    let onSnooze: () -> Void
    let sizeChanged: (CGSize) -> Void

    public init(appName: String, onStart: @escaping () -> Void, onNotNow: @escaping () -> Void, onSnooze: @escaping () -> Void,
                sizeChanged: @escaping (CGSize) -> Void) {
        self.appName = appName
        self.onStart = onStart
        self.onNotNow = onNotNow
        self.onSnooze = onSnooze
        self.sizeChanged = sizeChanged
    }

    public var body: some View {
        Localized {
            CardChrome {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "waveform.circle.fill").foregroundStyle(Palette.recording).font(.system(size: 18))
                    Text(tr(.detectionTitle, appName)).font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(tr(.detectionHint)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(tr(.actionStartRecording), action: onStart).buttonStyle(PillButtonStyle(kind: .record))
                    Button(tr(.actionNotNow), action: onNotNow).buttonStyle(PillButtonStyle(kind: .secondary))
                    Button(tr(.actionSnoozeHour), action: onSnooze).buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
        }
        .onFittingSizeChange(sizeChanged)
    }
}

@MainActor
public final class AutoStopModel: ObservableObject {
    @Published public var prompt = AutoStopPrompt(reason: "", remaining: 60, appEnded: false)
    public init() {}
}

public struct AutoStopCardView: View {
    @ObservedObject var model: AutoStopModel
    let onStop: () -> Void
    let onKeep: () -> Void
    let sizeChanged: (CGSize) -> Void

    public init(model: AutoStopModel, onStop: @escaping () -> Void, onKeep: @escaping () -> Void,
                sizeChanged: @escaping (CGSize) -> Void) {
        self.model = model
        self.onStop = onStop
        self.onKeep = onKeep
        self.sizeChanged = sizeChanged
    }

    public var body: some View {
        Localized {
            CardChrome {
                Text(tr(.autoStopTitle, model.prompt.remaining))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                Text(tr(.autoStopDetail, model.prompt.reason))
                    .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(tr(.actionStopNow), action: onStop).buttonStyle(PillButtonStyle(kind: .primary))
                    Button(tr(.actionKeepRecording), action: onKeep).buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
        }
        .onFittingSizeChange(sizeChanged)
    }
}

@MainActor
public final class ToastModel: ObservableObject {
    @Published public var text = ""
    public init() {}
}

/// Brief message above the pill.
public struct ToastView: View {
    @ObservedObject var model: ToastModel
    let sizeChanged: (CGSize) -> Void

    public init(model: ToastModel, sizeChanged: @escaping (CGSize) -> Void) {
        self.model = model
        self.sizeChanged = sizeChanged
    }

    public var body: some View {
        Text(model.text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.label)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(SurfaceBackground(shape: Capsule(style: .circular)))
            .onFittingSizeChange(sizeChanged)
    }
}
