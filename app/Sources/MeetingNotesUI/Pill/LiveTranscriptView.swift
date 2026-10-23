// Last lines of the live transcript inside the recording section of the expanded card (Pill).
// Shows polished paragraphs when the worker sent any, with a small toggle to view the raw chunks. Fast captions
// (design B) not yet covered by the worker's text follow as gray drafts.

import MeetingNotesCore
import SwiftUI

struct LiveTranscriptView: View {
    let transcript: LiveTranscript?
    var captions: LiveCaptions?
    var lineCount = 3
    @State private var showRaw = false

    var body: some View {
        let lines = LiveDisplay.lines(transcript: transcript, captions: captions, count: lineCount, polished: !showRaw)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "captions.bubble")
                Text(tr(.liveHeading))
                Spacer(minLength: 0)
                if transcript?.hasPolish == true {
                    Button(tr(showRaw ? .liveShowPolished : .liveShowRaw)) { showRaw.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Palette.secondary)
                        .underline()
                        .help(tr(showRaw ? .liveShowPolished : .liveShowRaw))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.secondary)
            if lines.isEmpty {
                Text(tr(.liveListening)).foregroundStyle(Palette.secondary).lineLimit(1)
            } else {
                ForEach(lines) { line in
                    (Text("\(tr(line.isMe ? .me : .them)): ").fontWeight(.semibold)
                        .foregroundColor(line.isMe ? Palette.label : Palette.secondary)
                        + Text(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .foregroundColor(line.isDraft ? Palette.secondary : Palette.label)
                        .italic(line.isDraft))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(line.isDraft ? tr(.captionsDraftHelp) : line.text)
                }
            }
            if let note = captionNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = pauseReason {
                Label(tr(reason == "memory" ? .livePausedMemory : reason == "battery" ? .livePausedBattery : .livePaused), systemImage: "pause.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.paused)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.control))
    }

    /// Design A's pause wins; otherwise a caption pause (same rules) is shown.
    private var pauseReason: String? {
        if let transcript, transcript.isPaused { return transcript.reason ?? "" }
        if case let .paused(reason)? = captions?.phase { return reason }
        return nil
    }

    /// Caption model download / preparation / failure line.
    private var captionNote: String? {
        switch captions?.phase {
        case let .preparing(fraction)?:
            guard let fraction, fraction < 0.85 else { return tr(.captionsPreparing) }
            return tr(.captionsDownloading, Int((fraction / 0.85 * 100).rounded()))
        case let .failed(message)?:
            return tr(.captionsFailed, message)
        default:
            return nil
        }
    }
}
