import AppKit
import CoreGraphics

/// Headless recording check: `MeetingNotes --self-test-record <seconds> <folder>`.
/// Exit codes: 0 both tracks, 1 one track only, 2 nothing recorded / error, 3 timeout.
enum SelfTest {
    static func run(seconds: Double, folder: URL) -> Never {
        setlinebuf(stdout)
        let app = NSApplication.shared  // connects to the window server, needed by ScreenCaptureKit
        app.setActivationPolicy(.prohibited)

        let timeout = seconds + 30
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            fputs("self-test: timed out after \(Int(timeout))s (permission prompt pending?)\n", stderr)
            exit(3)
        }
        Task { @MainActor in
            exit(await record(seconds: seconds, folder: folder))
        }
        app.run()
        exit(0)
    }

    @MainActor
    private static func record(seconds: Double, folder: URL) async -> Int32 {
        print("self-test: MeetingNotes \(AppInfo.versionString)")
        print("self-test: microphone permission: \(MicRecorder.permissionDescription)")
        print("self-test: screen capture preflight: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
        print("self-test: recording \(seconds)s into \(folder.path)")
        do {
            let session = try await RecordingSession.start(folder: folder, options: RecordingSession.Options())
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let result = await session.stop()
            for (name, track) in result.tracks.sorted(by: { $0.key < $1.key }) {
                let peak = track.peak > 0 ? String(format: "%.1f dBFS", 20 * log10(track.peak)) : "silent"
                print(String(format: "self-test: %@: %@ %.2fs @ %.0f Hz, start offset %.3fs, peak %@",
                             name, track.file, track.duration, track.sampleRate, track.startOffset, peak))
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
}
