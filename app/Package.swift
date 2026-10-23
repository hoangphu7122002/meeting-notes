// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Core ML speaker diarization for the MeetingNotesDiarize helper only (default engine, Apache-2.0).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        // Live captions (design B) for the MeetingNotesCaptions helper only: Whisper Core ML on the Neural Engine (MIT).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        // Meeting-app list and the "open the app when a meeting starts" rules (Foundation only): shared by the app
        // and the tiny launcher agent, which must stay small (no Core frameworks).
        .target(
            name: "MeetingNotesLaunch",
            path: "Sources/MeetingNotesLaunch"
        ),
        // Live captions (Foundation only): helper wire protocol, streaming window policy, energy gate, text cleanup.
        // Shared by the MeetingNotesCaptions helper and the app (through Core); unit-tested without WhisperKit.
        .target(
            name: "MeetingNotesCaptionKit",
            path: "Sources/MeetingNotesCaptionKit"
        ),
        // Pure logic (state machines, clock, WAV writing, event parsing, localization, layout); unit-tested.
        .target(
            name: "MeetingNotesCore",
            dependencies: ["MeetingNotesCaptionKit"],
            path: "Sources/MeetingNotesCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
        // SwiftUI views, view state and panel hosting shared by the app and the preview renderer.
        // Contains no capture, worker or app-delegate code.
        .target(
            name: "MeetingNotesUI",
            dependencies: ["MeetingNotesCore", "MeetingNotesLaunch"],
            path: "Sources/MeetingNotesUI",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "MeetingNotes",
            dependencies: ["MeetingNotesCore", "MeetingNotesUI", "MeetingNotesLaunch", "MeetingNotesCaptionKit"],
            path: "Sources/MeetingNotes",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        // `swift run MeetingNotesPreviews <dir>`: renders the pill and the main window to PNG offscreen
        // with fake state. Never starts the app, records or touches the app's settings.
        .executableTarget(
            name: "MeetingNotesPreviews",
            dependencies: ["MeetingNotesCore", "MeetingNotesUI"],
            path: "Sources/MeetingNotesPreviews"
        ),
        // `MeetingNotesDiarize <wav>`: offline diarization with FluidAudio (Core ML port of pyannote community-1),
        // JSON on stdout; the pipeline shells out to it (adapters/outbound/fluidaudio_diarizer.py). scripts/build-app.sh
        // copies it into MeetingNotes.app/Contents/MacOS; the app passes its path to the worker (DiarizeHelper).
        .executableTarget(
            name: "MeetingNotesDiarize",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MeetingNotesDiarize"
        ),
        // `MeetingNotesCaptions`: live caption helper (design B). The app streams 16 kHz PCM of the recording on stdin
        // and reads caption JSON lines; WhisperKit runs on the Neural Engine in this separate process, so its memory
        // and crashes never touch the app. scripts/build-app.sh copies it into Contents/MacOS.
        .executableTarget(
            name: "MeetingNotesCaptions",
            dependencies: ["MeetingNotesCaptionKit", .product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/MeetingNotesCaptions"
        ),
        // `MeetingNotesLauncher`: per-user background agent (SMAppService.agent) that opens the app when a meeting
        // starts while it is not running. scripts/build-app.sh copies it into Contents/MacOS with its launchd plist.
        .executableTarget(
            name: "MeetingNotesLauncher",
            dependencies: ["MeetingNotesLaunch"],
            path: "Sources/MeetingNotesLauncher",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio")]
        ),
        .testTarget(
            name: "MeetingNotesCoreTests",
            dependencies: ["MeetingNotesCore", "MeetingNotesLaunch", "MeetingNotesCaptionKit"],
            path: "Tests/MeetingNotesCoreTests"
        ),
        .testTarget(
            name: "MeetingNotesUITests",
            dependencies: ["MeetingNotesCore", "MeetingNotesUI", "MeetingNotesLaunch"],
            path: "Tests/MeetingNotesUITests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
