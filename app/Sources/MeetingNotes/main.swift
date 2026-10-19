import AppKit

// Command-line entry points run before (and instead of) the app.
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
    let usage = "usage: MeetingNotes --self-test-record <seconds> <folder> [--pause-at S --pause-for D]\n"
    guard rest.count >= 2, let seconds = Double(rest[0]), seconds > 0 else {
        fputs(usage, stderr)
        exit(64)
    }
    func value(_ flag: String) -> Double? {
        guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
        return Double(rest[i + 1])
    }
    let pauseAt = value("--pause-at")
    let pauseFor = value("--pause-for")
    if (pauseAt == nil) != (pauseFor == nil) || (pauseAt ?? 0) < 0 || (pauseAt ?? 0) >= seconds || (pauseFor ?? 1) <= 0 {
        fputs(usage, stderr)
        exit(64)
    }
    let folder = URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath, isDirectory: true)
    SelfTest.run(seconds: seconds, folder: folder, pause: pauseAt.flatMap { at in pauseFor.map { (at, $0) } })
}

#if DEBUG
if let index = arguments.firstIndex(of: "--render-pill-previews"), index + 1 < arguments.count {
    let dir = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    MainActor.assumeIsolated { PreviewRenderer.run(dir: dir) }
}
if let index = arguments.firstIndex(of: "--self-test-worker") {
    let folders = arguments.dropFirst(index + 1).prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    MainActor.assumeIsolated { WorkerSelfTest.run(folders: Array(folders)) }
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
