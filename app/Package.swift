// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Core ML speaker diarization for the opt-in `diarization_engine = "fluidaudio"` helper only (Apache-2.0).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        // Pure logic (state machines, clock, WAV writing, event parsing, localization, layout); unit-tested.
        .target(
            name: "MeetingNotesCore",
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
            dependencies: ["MeetingNotesCore"],
            path: "Sources/MeetingNotesUI",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "MeetingNotes",
            dependencies: ["MeetingNotesCore", "MeetingNotesUI"],
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
        // JSON on stdout; the pipeline shells out to it (adapters/outbound/fluidaudio_diarizer.py). Not in the app bundle.
        .executableTarget(
            name: "MeetingNotesDiarize",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MeetingNotesDiarize"
        ),
        .testTarget(
            name: "MeetingNotesCoreTests",
            dependencies: ["MeetingNotesCore"],
            path: "Tests/MeetingNotesCoreTests"
        ),
        .testTarget(
            name: "MeetingNotesUITests",
            dependencies: ["MeetingNotesCore", "MeetingNotesUI"],
            path: "Tests/MeetingNotesUITests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
