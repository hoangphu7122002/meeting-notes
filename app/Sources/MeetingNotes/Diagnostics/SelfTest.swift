import AppKit
import CoreGraphics
import MeetingNotesCore
import MeetingNotesUI

/// Headless recording check:
/// `MeetingNotes --self-test-record <seconds> <folder> [--pause-at S --pause-for D]`.
/// Records `seconds` of recorded time; with a pause, capture stops at recorded S for D wall seconds.
/// Exit codes: 0 both tracks, 1 one track only, 2 nothing recorded / error, 3 timeout.
enum SelfTest {
    static func run(seconds: Double, folder: URL, pause: (at: Double, duration: Double)?) -> Never {
        setlinebuf(stdout)
        let app = NSApplication.shared  // connects to the window server, needed by ScreenCaptureKit
        app.setActivationPolicy(.prohibited)

        let timeout = seconds + (pause?.duration ?? 0) + 30
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            fputs("self-test: timed out after \(Int(timeout))s (permission prompt pending?)\n", stderr)
            exit(3)
        }
        Task { @MainActor in
            exit(await record(seconds: seconds, folder: folder, pause: pause))
        }
        app.run()
        exit(0)
    }

    @MainActor
    private static func record(seconds: Double, folder: URL, pause: (at: Double, duration: Double)?) async -> Int32 {
        print("self-test: MeetingNotes \(AppInfo.versionString) pid \(getpid())")
        print("self-test: microphone permission: \(MicRecorder.permissionDescription)")
        print("self-test: screen capture preflight: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
        print("self-test: recording \(seconds)s into \(folder.path)" + (pause.map { ", pause at \($0.at)s for \($0.duration)s" } ?? ""))
        do {
            let session = try await RecordingSession.start(folder: folder, options: RecordingSession.Options())
            if let pause {
                await sleep(until: pause.at, session: session)
                session.pause()
                print(String(format: "self-test: paused at %.2fs recorded", session.recordedSeconds))
                try? await Task.sleep(nanoseconds: UInt64(pause.duration * 1_000_000_000))
                session.resume()
                print(String(format: "self-test: resumed at %.2fs recorded", session.recordedSeconds))
            }
            await sleep(until: seconds, session: session)
            let result = await session.stop()
            print(String(format: "self-test: recorded duration %.2fs", result.recordedDuration))
            for (name, track) in result.tracks.sorted(by: { $0.key < $1.key }) {
                let peak = track.peak > 0 ? String(format: "%.1f dBFS", 20 * log10(track.peak)) : "silent"
                print(String(format: "self-test: %@: %@ %.2fs @ %.0f Hz, start offset %.3fs, ends at %.3fs, peak %@",
                             name, track.file, track.duration, track.sampleRate, track.startOffset,
                             track.startOffset + track.duration, peak))
            }
            for pause in result.pauses {
                print(String(format: "self-test: pause at %.2fs recorded, %.2fs wall", pause.atSec, pause.durationSec))
            }
            for warning in result.warnings { print("self-test: warning: \(warning)") }
            print("self-test: wrote \(folder.appendingPathComponent("meeting.json").path)")
            switch result.tracks.count {
            case 2: return 0
            case 1:
                fputs("self-test: only one track recorded (see warnings)\n", stderr)
                return 1
            default:
                fputs("self-test: no audio recorded\n", stderr)
                return 2
            }
        } catch {
            fputs("self-test: failed: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    /// Sleeps until the session has `target` seconds of recorded time.
    @MainActor
    private static func sleep(until target: Double, session: RecordingSession) async {
        while true {
            let remaining = target - session.recordedSeconds
            if remaining <= 0.0005 { return }
            try? await Task.sleep(nanoseconds: UInt64(min(remaining, 0.5) * 1_000_000_000))
        }
    }
}
