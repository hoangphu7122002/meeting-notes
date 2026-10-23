import Foundation

/// The FluidAudio diarization helper (`MeetingNotesDiarize`) that scripts/build-app.sh bundles next to the app's
/// executable in Contents/MacOS. The app hands its path to the pipeline worker through the environment, so the
/// pipeline uses the bundled copy without any config (the `fluidaudio_cli` config key still overrides it).
public enum DiarizeHelper {
    public static let binaryName = "MeetingNotesDiarize"
    public static let environmentKey = "MEETING_NOTES_DIARIZE_CLI"

    /// The helper next to `executableURL` (Contents/MacOS/MeetingNotes), if it is there and executable.
    public static func bundledPath(executableURL: URL?, isExecutable: (String) -> Bool) -> String? {
        guard let executableURL else { return nil }
        let path = executableURL.deletingLastPathComponent().appendingPathComponent(binaryName).path
        return isExecutable(path) ? path : nil
    }

    /// `environment` plus the bundled helper's path; a value already set (by the user) is kept.
    public static func workerEnvironment(_ environment: [String: String], executableURL: URL?,
                                         isExecutable: (String) -> Bool) -> [String: String] {
        var result = environment
        if (result[environmentKey] ?? "").isEmpty,
           let path = bundledPath(executableURL: executableURL, isExecutable: isExecutable) {
            result[environmentKey] = path
        }
        return result
    }
}
