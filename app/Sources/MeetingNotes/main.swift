import AppKit

// Command-line entry points run before (and instead of) the menu bar app.
let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("MeetingNotes \(AppInfo.versionString)")
    exit(0)
}

if arguments.contains("--list-mic-clients") {
    // Debug aid for meeting detection: processes currently capturing microphone input.
    for process in MeetingDetector.processesCapturingInput() {
        let match = MeetingDetector.match(bundleID: process.bundleID).map { " -> \($0)" } ?? ""
        print("\(process.pid)\t\(process.bundleID.isEmpty ? "?" : process.bundleID)\(match)")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--self-test-record") {
    let rest = Array(arguments.dropFirst(index + 1))
    guard rest.count >= 2, let seconds = Double(rest[0]), seconds > 0 else {
        fputs("usage: MeetingNotes --self-test-record <seconds> <folder>\n", stderr)
        exit(64)
    }
    let folder = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath, isDirectory: true)
    SelfTest.run(seconds: seconds, folder: folder)
}

MeetingNotesApp.main()
