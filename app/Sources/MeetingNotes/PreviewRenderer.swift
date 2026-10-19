#if DEBUG
import AppKit
import MeetingNotesCore
import SwiftUI

/// `MeetingNotes --render-pill-previews <dir>` (debug builds): renders pill states to PNG offscreen.
/// No window is shown and nothing is recorded.
@MainActor
enum PreviewRenderer {
    static func run(dir: URL) -> Never {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = AppController()
        controller.clock.elapsed = "12:34"
        controller.levels.me = 0.7
        controller.levels.them = 0.4
        var processing = ProcessingSnapshot(job: "j", folder: "/tmp/x", title: "Weekly sync")
        for line in [
            #"{"event":"stage","stage":"prepare","status":"done","overall":0.03,"elapsed_sec":1.4,"job":"j"}"#,
            #"{"event":"stage","stage":"diarize","status":"done","overall":0.28,"elapsed_sec":42,"job":"j"}"#,
            #"{"event":"progress","stage":"transcribe","fraction":0.4,"overall":0.45,"eta_sec":130,"message":"Transcribing block 4/10","job":"j"}"#,
            #"{"event":"partial","folder":"/tmp/x","notes":"/tmp/x/notes.md","job":"j"}"#,
        ] { if let event = WorkerEvent(line: line) { processing.apply(event) } }
        processing.queued = 1
        let ready = ReadyInfo(folder: "/tmp/x", title: "Weekly sync", notesPath: "/tmp/x/notes.md")
        var discard = RecorderMachine(phase: .recording)
        _ = discard.handle(.requestDiscard)
        let cases: [(String, PillState, RecorderMachine, Bool)] = [
            ("idle", .idle(attention: false), RecorderMachine(), false),
            ("idle-expanded", .idle(attention: true), RecorderMachine(), true),
            ("recording", .recording, RecorderMachine(phase: .recording), false),
            ("recording-expanded", .recording, RecorderMachine(phase: .recording), true),
            ("paused", .paused, RecorderMachine(phase: .paused), false),
            ("discard-confirm", .recording, discard, true),
            ("processing", .processing(processing), RecorderMachine(), false),
            ("processing-expanded", .processing(processing), RecorderMachine(), true),
            ("ready-expanded", .ready(ready), RecorderMachine(), true),
            ("error-expanded", .error(PillError("Processing failed: Ollama is not reachable", action: .retry(folder: "/tmp/x"))),
             RecorderMachine(), true),
        ]
        let actions = PillActions(sizeChanged: { _ in }, expand: {}, collapse: {}, dragChanged: {}, dragEnded: {}, editingChanged: { _ in })
        for (name, pill, machine, expanded) in cases {
            controller.debugSet(pill: pill, machine: machine)
            let ui = PillUIModel()
            ui.expanded = expanded
            let view = PillRootView(app: controller, ui: ui, clock: controller.clock, levels: controller.levels, actions: actions)
                .background(Color(white: 0.75))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            let url = dir.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("\(url.path) \(image.width / 2)x\(image.height / 2)")
        }
        let card = DetectionCardView(appName: "Zoom", onStart: {}, onNotNow: {}, onSnooze: {}).background(Color(white: 0.75))
        if let image = ImageRenderer(content: card).cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("detection-card.png"))
        }
        exit(0)
    }
}
#endif
