// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (state machines, clock, WAV writing, event parsing); unit-tested.
        .target(
            name: "MeetingNotesCore",
            path: "Sources/MeetingNotesCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "MeetingNotes",
            dependencies: ["MeetingNotesCore"],
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
        .testTarget(
            name: "MeetingNotesCoreTests",
            dependencies: ["MeetingNotesCore"],
            path: "Tests/MeetingNotesCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
