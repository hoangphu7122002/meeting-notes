// Meeting apps by bundle ID, shared by the in-app meeting detector and the background launcher (Launch).

import Foundation

public enum MeetingApps {
    /// MeetingNotes itself; its helpers use `<id>.<suffix>` (e.g. `.diarize`, `.launcher`).
    public static let ownBundleID = "com.hoangphu.meetingnotes"

    /// Apps whose microphone use counts as a meeting. Bundle ID prefixes: exact match or followed by "."
    /// (e.g. `com.google.Chrome.helper`).
    public static let known: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Teams"),
        ("com.microsoft.teams", "Teams"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit.GPU", "Safari"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("org.mozilla.firefox", "Firefox"),
    ]

    /// Dedicated meeting apps whose launch alone opens MeetingNotes. Browsers, Slack and Discord stay open all
    /// day, so they count only while they use the microphone.
    public static let launchTriggers: [String] = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark", "com.apple.FaceTime",
    ]

    /// Display name of a known meeting app, or nil.
    public static func name(bundleID: String) -> String? {
        known.first { matches(bundleID, prefix: $0.prefix) }?.name
    }

    public static func isLaunchTrigger(bundleID: String) -> Bool {
        launchTriggers.contains { matches(bundleID, prefix: $0) }
    }

    /// MeetingNotes or one of its helpers (never a reason to open the app).
    public static func isOwn(bundleID: String) -> Bool {
        matches(bundleID, prefix: ownBundleID)
    }

    static func matches(_ bundleID: String, prefix: String) -> Bool {
        bundleID == prefix || bundleID.hasPrefix(prefix + ".")
    }
}
