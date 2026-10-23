// MeetingNotesLauncher: tiny per-user background agent (SMAppService.agent, registered by the app while
// Settings › Advanced › "Open the app when a meeting starts" is on). It opens MeetingNotes with
// `--opened-for-meeting` when a meeting app launches or starts using the microphone while MeetingNotes is not
// running; the app then offers to record. Never records, never uses the network, no window, no polling.
//
// Usage: MeetingNotesLauncher [--app PATH] [--dry-run]   (--dry-run prints instead of opening the app)

import AppKit
import MeetingNotesLaunch

let arguments = CommandLine.arguments
let dryRun = arguments.contains("--dry-run")

func executablePath() -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    var size = UInt32(buffer.count)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return arguments[0] }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
}

let appURL: URL? = {
    if let index = arguments.firstIndex(of: "--app"), index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1])
    }
    return MeetingLauncher.appBundle(forHelperAt: executablePath())
}()

guard let appURL else {
    fputs("MeetingNotesLauncher: not inside MeetingNotes.app/Contents/MacOS (pass --app PATH)\n", stderr)
    exit(0)  // clean exit: launchd (KeepAlive.SuccessfulExit = false) does not restart it in a loop
}

let agent = LauncherAgent(appURL: appURL, dryRun: dryRun)
agent.start()
withExtendedLifetime(agent) { RunLoop.main.run() }
