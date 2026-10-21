import AppKit
import MeetingNotesCore
import SwiftUI

/// Loads a meeting folder's transcript.json + .work/summary.json (or notes.md as fallback) and reloads
/// when files change (directory vnode watch, no polling).
@MainActor
public final class NotesViewerModel: ObservableObject {
    @Published public private(set) var folder: URL
    @Published public private(set) var title = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var transcript: Transcript?
    @Published private(set) var summary: MeetingSummary?
    @Published private(set) var markdown: AttributedString?
    @Published private(set) var summaryPending = false
    @Published var search = ""

    private var watchers: [DispatchSourceFileSystemObject] = []
    private var reloadWork: DispatchWorkItem?
    private var loadGeneration = 0

    public init(folder: URL) {
        self.folder = folder
        title = folder.lastPathComponent
        load()
        watch()
    }

    public func setFolder(_ folder: URL) {
        guard MeetingFolders.key(folder) != MeetingFolders.key(self.folder) else { return }
        self.folder = folder
        watch()
        load()
    }

    public func stop() {
        watchers.forEach { $0.cancel() }
        watchers = []
    }

    public func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.load() } }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let folder = self.folder
        Task.detached(priority: .userInitiated) {
            let loaded = Self.read(folder)
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.apply(loaded)
            }
        }
    }

    private struct Loaded: Sendable {
        var title: String?
        var startedAt: Date?
        var transcript: Transcript?
        var summary: MeetingSummary?
        var markdown: AttributedString?
        var summaryPending: Bool
    }

    nonisolated private static func read(_ folder: URL) -> Loaded {
        let decoder = JSONDecoder()
        let transcript = (try? Data(contentsOf: folder.appendingPathComponent("transcript.json")))
            .flatMap { try? decoder.decode(Transcript.self, from: $0) }
        let summary = (try? Data(contentsOf: folder.appendingPathComponent(".work/summary.json")))
            .flatMap { try? decoder.decode(MeetingSummary.self, from: $0) }
        let meeting = MeetingFolders.readJSON(folder.appendingPathComponent("meeting.json"))
        let status = MeetingFolders.readJSON(folder.appendingPathComponent("status.json"))?["state"] as? String
        var markdown: AttributedString?
        if transcript == nil || summary == nil, let text = try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) {
            markdown = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        }
        let iso = ISO8601DateFormatter()
        let started = (transcript?.startedAt ?? meeting?["started_at"] as? String).flatMap { iso.date(from: $0) }
        return Loaded(title: summary?.title.flatMap { $0.isEmpty ? nil : $0 } ?? transcript?.title ?? meeting?["title"] as? String,
                      startedAt: started, transcript: transcript, summary: summary, markdown: markdown,
                      summaryPending: summary == nil && status == "running")
    }

    private func apply(_ loaded: Loaded) {
        title = loaded.title ?? folder.lastPathComponent
        startedAt = loaded.startedAt
        transcript = loaded.transcript
        summary = loaded.summary
        markdown = loaded.markdown
        summaryPending = loaded.summaryPending
    }

    private func watch() {
        stop()
        for url in [folder, folder.appendingPathComponent(".work", isDirectory: true)] {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReload() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }
}

public struct NotesView: View {
    @ObservedObject var model: NotesViewerModel
    let commands: any AppCommands

    public init(model: NotesViewerModel, commands: any AppCommands) {
        self.model = model
        self.commands = commands
    }

    private static let speakerColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    public var body: some View {
        Localized { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let summary = model.summary {
                        summarySections(summary)
                    } else if model.summaryPending {
                        Label(tr(.summaryInProgress), systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    if let transcript = model.transcript {
                        transcriptSection(transcript)
                    } else if let markdown = model.markdown {
                        Text(markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.summary == nil {
                        Text(tr(.noNotes)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 10) {
                if let date = model.startedAt {
                    Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.language.locale)))
                }
                if let duration = model.transcript?.durationSec {
                    Text("· \(Format.duration(duration))")
                }
                if let speakers = model.transcript?.speakers, !speakers.isEmpty {
                    Text("·")
                    ForEach(Array(speakers.enumerated()), id: \.offset) { index, speaker in
                        Text(speaker).font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Self.speakerColors[index % Self.speakerColors.count].opacity(0.18)))
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(tr(.searchTranscript), text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Button(tr(.actionCopySummary)) { commands.copySummary(folder: model.folder) }
                Button(tr(.actionOpenInDefaultApp)) { commands.openInDefaultApp(model.folder.appendingPathComponent("notes.md")) }
                Button(tr(.actionShowInFinder)) { commands.reveal(model.folder) }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func summarySections(_ summary: MeetingSummary) -> some View {
        if !summary.summary.isEmpty { bulletSection(tr(.summaryHeading), summary.summary) }
        if !summary.decisions.isEmpty { bulletSection(tr(.decisionsHeading), summary.decisions) }
        if !summary.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(.actionItemsHeading)).font(.headline)
                ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "square").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.task).textSelection(.enabled)
                            let meta = [item.owner, item.due.map { tr(.dueDate, $0) }].compactMap { $0 }.filter { !$0.isEmpty }
                            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        if !summary.openQuestions.isEmpty { bulletSection(tr(.openQuestionsHeading), summary.openQuestions) }
    }

    private func bulletSection(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func transcriptSection(_ transcript: Transcript) -> some View {
        Divider()
        Text(tr(.transcriptHeading)).font(.headline)
        let blocks = transcript.blocks(filter: model.search)
        if blocks.isEmpty {
            Text(model.search.isEmpty ? tr(.noSpeech) : tr(.noMatches)).foregroundStyle(.secondary)
        }
        ForEach(blocks) { block in
            switch block {
            case let .paragraph(_, speaker, start, text):
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(speaker).font(.callout.weight(.semibold)).foregroundStyle(color(for: speaker, in: transcript))
                        Text(Format.timestamp(start)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            case let .pause(_, at, duration):
                HStack {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                    Text(tr(.pausedAt, Format.duration(duration), Format.timestamp(at))).font(.caption).foregroundStyle(.secondary)
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                }
            }
        }
    }

    private func color(for speaker: String, in transcript: Transcript) -> Color {
        let index = transcript.speakers.firstIndex(of: speaker) ?? abs(speaker.hashValue)
        return Self.speakerColors[index % Self.speakerColors.count]
    }
}
