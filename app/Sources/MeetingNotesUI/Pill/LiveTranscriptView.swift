// Last lines of the live transcript inside the recording section of the expanded card (Pill).
// Shows polished paragraphs when the worker sent any, with a small toggle to view the raw chunks.

import MeetingNotesCore
import SwiftUI

struct LiveTranscriptView: View {
    let transcript: LiveTranscript
    var lineCount = 3
    @State private var showRaw = false

    var body: some View {
        let lines = transcript.displayLines(lineCount, polished: !showRaw)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "captions.bubble")
                Text(tr(.liveHeading))
                Spacer(minLength: 0)
                if transcript.hasPolish {
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
                        + Text(line.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(line.text)
                }
            }
            if transcript.isPaused {
                Label(tr(.livePaused), systemImage: "pause.circle")
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
}
