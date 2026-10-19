#if DEBUG
import AppKit
import MeetingNotesCore

/// `MeetingNotes --self-test-worker <folder>... -uvPath <fake worker> -pipelineDir <dir>` (debug builds):
/// runs `JobQueue` + `WorkerClient` against a protocol-compatible fake worker. Folder names select the
/// fake's behaviour (`ok`, `fail`, `crash`, `slow` = cancelled after 1 s). After all jobs end it waits for
/// the worker's idle exit and runs one more job to check respawning.
@MainActor
enum WorkerSelfTest {
    static func run(folders: [URL]) -> Never {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("worker-test: timed out\n", stderr)
            exit(3)
        }
        let jobs = JobQueue()
        var remaining = folders.count
        var phase = 1
        var lastPercent = -1
        jobs.onChange = {
            guard let s = jobs.displaySnapshot, s.percent != lastPercent else { return }
            lastPercent = s.percent
            print("worker-test: progress \(URL(fileURLWithPath: s.folder).lastPathComponent) \(s.percent)% stage=\(s.currentStage ?? "-") queued=\(s.queued)")
        }
        jobs.onPartial = { job, notes in print("worker-test: partial \(job.folder.lastPathComponent) -> \(URL(fileURLWithPath: notes).lastPathComponent)") }
        jobs.onFinished = { job, outcome in
            print("worker-test: finished \(job.originalFolder.lastPathComponent): \(outcome)")
            remaining -= 1
            guard remaining == 0 else { return }
            if phase == 1 {
                phase = 2
                // Let the fake worker idle-exit (2 s), then check it is respawned on demand.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    MainActor.assumeIsolated {
                        let again = folders[0].deletingLastPathComponent().appendingPathComponent("ok-after-idle")
                        try? FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
                        remaining = 1
                        jobs.enqueue(folder: again, title: "again", explicit: true)
                    }
                }
            } else {
                exit(0)
            }
        }
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            jobs.enqueue(folder: folder, title: folder.lastPathComponent, explicit: true)
        }
        // Cancel the "slow" job one second after it starts.
        func cancelSlowWhenRunning() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    if let current = jobs.current, current.folder.lastPathComponent.contains("slow") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            MainActor.assumeIsolated {
                                print("worker-test: cancelling slow job")
                                jobs.cancelCurrent()
                            }
                        }
                    } else if phase == 1 {
                        cancelSlowWhenRunning()
                    }
                }
            }
        }
        cancelSlowWhenRunning()
        app.run()
        exit(0)
    }
}
#endif
