import AppKit
import MeetingNotesCore
import SwiftUI

struct ElapsedText: View {
    @ObservedObject var clock: ClockModel

    var body: some View {
        Text(clock.elapsed).monospacedDigit()
    }
}

/// Determinate bar (pure SwiftUI, no animation).
struct ProgressBar: View {
    let value: Double
    var color: Color = Palette.label
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Determinate ring (no spinning animation).
struct ProgressRing: View {
    let value: Double
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(Palette.label, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal level meter bar.
struct MeterBar: View {
    let value: Double
    var warning = false
    var height: CGFloat = 6

    var body: some View {
        ProgressBar(value: value, color: warning ? Palette.warning : Palette.ok, height: height)
    }
}

/// Me/Them meter with label and an optional one-line warning (full text as tooltip).
struct MeterRow: View {
    let label: String
    @ObservedObject var levels: LevelModel
    let isMe: Bool
    let warning: String?
    var labelWidth: CGFloat = 78
    var barHeight: CGFloat = 6
    var font: Font = .system(size: 13, weight: .medium)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label).font(font).lineLimit(1).frame(width: labelWidth, alignment: .leading)
                MeterBar(value: isMe ? levels.me : levels.them, warning: warning != nil, height: barHeight)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.warning)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, labelWidth + 8)
                    .help(warning)
            }
        }
    }
}

struct StageRow: View {
    let stage: StageProgress
    let finishing: Bool
    var font: Font = .system(size: 13)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                icon.frame(width: 16)
                Text(stage.title()).font(font).fontWeight(stage.status == .running ? .semibold : .regular)
                    .foregroundStyle(stage.status == .pending ? Palette.secondary : Palette.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let elapsed = stage.elapsedSec, stage.status == .done {
                    Text(Format.duration(elapsed)).font(font).foregroundStyle(Palette.secondary).monospacedDigit()
                } else if stage.status == .skipped {
                    Text(tr(.stageCached)).font(font).foregroundStyle(Palette.secondary)
                }
            }
            if stage.status == .running, !finishing {
                ProgressBar(value: stage.fraction, color: Palette.ok).padding(.leading, 24)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch stage.status {
        case .done, .skipped: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
        case .running: Image(systemName: "circle.circle.fill").foregroundStyle(Palette.label)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.warning)
        case .pending: Image(systemName: "circle").foregroundStyle(Palette.secondary)
        }
    }
}

/// Single-line meeting title editor. An AppKit field so that, in the pill, only clicking it makes the
/// panel key. Commits on Return or when focus leaves; Esc reverts.
struct TitleField: NSViewRepresentable {
    enum Style { case pill, window }

    @Binding var text: String
    var style: Style = .pill
    let onEditingChanged: (Bool) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = tr(.titlePlaceholder)
        field.toolTip = tr(.titleTooltip)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        switch style {
        case .pill:
            field.isBordered = false
            field.drawsBackground = true
            field.backgroundColor = .dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.1))
            field.textColor = .labelColor
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 14)
        case .window:
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.font = .systemFont(ofSize: 15)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleField
        private var original = ""

        init(_ parent: TitleField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onEditingChanged(true) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCommit()
            parent.onEditingChanged(false)
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            original = (control as? NSTextField)?.stringValue ?? ""
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField {
                field.stringValue = original  // Esc reverts
                parent.text = original
                control.window?.makeFirstResponder(nil)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

/// Grouped section of the main window.
struct SectionCard<Content: View, Accessory: View>: View {
    let title: String?
    let accessory: Accessory
    let content: Content

    init(_ title: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.cardBorder, lineWidth: 1))
    }
}

extension SectionCard where Accessory == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}
