// Localization: `Tr` is the key enum (every user-visible string), `L10n` holds the vi/en table and fills
// placeholders, `tr(_:)` looks a key up in the current (or an explicit) UI language.

import Foundation

/// UI language (UserDefaults key `uiLanguage`). Vietnamese is the default.
public enum UILanguage: String, CaseIterable, Sendable {
    case vi, en

    /// Name shown in the language picker (always in its own language).
    public var displayName: String {
        switch self {
        case .vi: return "Tiếng Việt"
        case .en: return "English"
        }
    }

    /// Locale for dates and numbers.
    public var locale: Locale { Locale(identifier: self == .vi ? "vi_VN" : "en_US") }
}

/// Localization table: every user-visible string, in Vietnamese and English.
/// Placeholders are `%1`, `%2`, … and are filled by `L10n.string(_:_:args:)`.
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: UILanguage = .vi

    /// Language used when none is passed explicitly. Set by the app at launch and on change.
    public static var language: UILanguage {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public static func string(_ key: Tr, _ lang: UILanguage, args: [CustomStringConvertible] = []) -> String {
        let entry = key.entry
        var text = lang == .vi ? entry.vi : entry.en
        // Highest index first so %1 does not match inside %10.
        for (index, arg) in args.enumerated().reversed() {
            text = text.replacingOccurrences(of: "%\(index + 1)", with: arg.description)
        }
        return text
    }

    /// Placeholder indices (`%1`, `%2`, …) used by a string.
    public static func placeholders(in text: String) -> Set<Int> {
        var result = Set<Int>()
        var scanner = text[...]
        while let range = scanner.range(of: "%") {
            let digits = scanner[range.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits) { result.insert(value) }
            scanner = scanner[range.upperBound...]
        }
        return result
    }
}

/// Translated string in the current UI language.
public func tr(_ key: Tr, _ args: CustomStringConvertible...) -> String {
    L10n.string(key, L10n.language, args: args)
}

/// Translated string in an explicit language.
public func tr(_ key: Tr, lang: UILanguage, _ args: CustomStringConvertible...) -> String {
    L10n.string(key, lang, args: args)
}

/// Keys of every user-visible string.
public enum Tr: String, CaseIterable, Sendable {
    // States
    case stateReady, statePermissionsNeeded, stateStarting, stateRecording, statePaused, statePausedLong, stateSaving
    case stateProcessingPercent, stateWaiting, stateDone, stateRecordingSaved, stateError, stateWritingNotes

    // Recorder actions
    case actionStartRecording, actionStart, actionPause, actionResume, actionStopCreateNotes, actionStopSave, actionStop
    case actionDiscard, actionDiscardEllipsis, discardQuestion, discardConfirm, discardKeep

    // Meeting actions
    case actionOpenNotes, actionOpenLastNotes, actionShowInFinder, actionCopySummary, actionRetry, actionCreateNotes
    case actionCreateNotesNow, actionCancel, actionDismiss, actionOpenTranscript, actionReprocess, actionShowLog
    case actionOpenSettings, actionOpenSystemSettings, actionRelaunch, actionFix, actionAllow, actionGotIt
    case actionSettingsEllipsis, actionSettings, actionOpenMain, actionOpenNotesFolder, actionHideHour, actionCollapse
    case actionShowControls, actionResetPillPosition, actionPermissionsEllipsis, actionNotNow, actionSnoozeHour
    case actionStopNow, actionKeepRecording, actionRunTest, actionTesting, actionChange, actionUseDefault, actionOpen
    case actionUseFolder, actionOpenInDefaultApp

    // App menu
    case menuAbout, menuHide, menuQuit, menuEdit, menuUndo, menuRedo, menuCut, menuCopy, menuPaste, menuSelectAll
    case menuWindow, menuMinimize, menuClose, menuRecording, menuRecentMeetings, menuNoMeetings
    case statusRecordingTime, statusPausedTime, statusNotesReady

    // Pill and main window
    case me, them, titlePlaceholder, titleTooltip, micNotRecording, systemAudioMissingShort, systemAudioBanner
    case othersSilent, hotkeyStartStop, hotkeyPause, pillHelp, startingCapture, savingRecording, appUsingMic
    case permissionsAttention, finishing, stageCached, queuedOne, queuedMany, audioSavedManual, audioKept
    case notesReadyFor, openWindowHelp, idleHint, hotkeysHeading, processingHeading, recentHeading, noMeetingsYet
    case permissionsHeading, microphone, systemAudio, notificationsOptional, micDetail, systemAudioDetail
    case notificationsDetail, permAllowed, permDenied, permNotDetermined, permUnavailable, relaunchNote
    case relaunchBlocked, gettingStartedHeading, gettingStarted1, gettingStarted2, gettingStarted3
    case audioTestHeading, audioTestHint, testStopFirst, testMeOK, testMeSilent, testMeError, testThemOK
    case testThemSilent, testThemNotPermitted, micAccessDenied, readyHeading, notesFolder, waitingHeading
    case recentDuration, notificationBody, liveHeading, liveListening, livePaused

    // Meeting status (recents)
    case meetingReady, meetingProcessing, meetingProcessingPercent, meetingQueued, meetingRecording, meetingFailed
    case meetingCancelled, meetingNotProcessed

    // Processing stages
    case stagePrepare, stageDiarize, stageTranscribe, stageSummarize, stageRender, stageFinalize

    // Toasts
    case toastAlreadyRecording, toastStillSaving, toastNotRecording, toastStoppedCreating, toastPaused
    case toastAlreadyPaused, toastResumed, toastStoppedSaved, toastMeetingEndedCreating, toastMeetingEndedSaved
    case toastRecordingStarted, toastCouldNotStart, toastDiscarded, toastCancelling, toastProcessingCancelled
    case toastHiddenHour, toastNoNotes, toastNoSummary, toastSummaryCopied, toastUnknownCommand, toastCouldNotRename

    // Errors and warnings
    case errCouldNotStart, errNoAudio, errCouldNotDelete, errProcessingFailed, errNoNotesProduced
    case errPipelineRejected, errPipelineExit, errWorkerStopped, errWorkerNotRunning, errUvNotFound
    case errPipelineNotConfigured, errPipelineNotFound, errNoAudioSource, warnMicUnavailable, warnMicDenied
    case warnSystemNotRecorded, warnMicResume, warnSystemResume, warnTrackWriteFailed, warnTrackNoAudio
    case warnTrackSilent, warnMeetingJSON, errNoMicDevice, warnMicDeviceChanged, warnMicStoppedAfterChange, errNoDisplay
    case warnSystemStopped, waitIdlePlugged, waitManual, hotkeyInvalid, hotkeyUnavailable

    // First-run setup (packaged app)
    case setupHeading, setupIntro, setupGatekeeperNote, setupStepRuntime, setupStepSpeech, setupStepDiarization
    case setupStepOllama, setupStepSummary, actionSetUp, actionContinueSetup, actionCheckAgain, actionDownloadOllama
    case actionOpenOllama, actionCopyBrewCommand, setupWaitingRecording, setupWaitingProcessing, setupPaused
    case setupComplete, setupFailed, setupOllamaMissing, setupOllamaNotRunning, setupMoveToApplications
    case setupStepWaiting, setupStepDone, setupWorking, errSetupIncomplete

    // Cards
    case autoStopTitle, autoStopDetail, autoStopSilence, autoStopAppEnded, detectionTitle, detectionHint

    // Default titles
    case defaultMeetingTitle, appMeetingTitle

    // Formatting
    case etaUnderMinute, etaMinutes, etaHours, etaHoursMinutes, durSeconds, durMinutes, durHours, durHoursMinutes

    // Settings
    case settingsWindowTitle, groupBasics, groupDuringMeeting, groupAfterMeeting, groupAdvanced, language, helpLanguage
    case launchAtLogin, helpLaunchAtLogin, loginNeedsApproval, loginUnavailable, actionOpenLoginItems
    case missingPermissions, helpMissingPermissions, actionGrantMicrophone, actionGrantSystemAudio
    case setupUnfinished, helpSetupUnfinished, actionOpenSetup
    case suggestRecording, helpDetection, detectionRequires, stopOnCallEnd, helpStopOnCallEndNeedsDetection, helpCountdown
    case stopAfterSilence, silenceNever, helpSilence, helpSilenceOff, shortcutsLabel, helpShortcuts, hotkeyNone
    case createNotesLabel, modeRightAway, modeWhenIdle, modeManual, helpRightAway, helpWhenIdle, helpManual
    case summaryModelLabel, modelLight, modelBetter, helpSummary, helpSummaryLowMemory, saveLocation
    case liveTranscriptionToggle, liveTranscriptionCaption, livePolishToggle, livePolishCaption, liveShowRaw, liveShowPolished
    case pillLabel, pillWhileRecording, pillAlways, pillNever, helpPill, helpPillNever, actionResetPosition
    case showInDock, helpDock, version, openForMeetings, helpOpenForMeetings

    // Notes viewer
    case summaryInProgress, noNotes, searchTranscript, summaryHeading, decisionsHeading, actionItemsHeading
    case openQuestionsHeading, transcriptHeading, noSpeech, noMatches, pausedAt, dueDate

    var entry: (vi: String, en: String) {
        switch self {
        case .stateReady: return ("Sẵn sàng", "Ready")
        case .statePermissionsNeeded: return ("Cần cấp quyền", "Permissions needed")
        case .stateStarting: return ("Đang bắt đầu…", "Starting…")
        case .stateRecording: return ("Đang ghi", "Recording")
        case .statePaused: return ("Tạm dừng", "Paused")
        case .statePausedLong: return ("Đã tạm dừng", "Paused")
        case .stateSaving: return ("Đang lưu…", "Saving…")
        case .stateProcessingPercent: return ("Đang tạo ghi chú %1%", "Writing notes %1%")
        case .stateWaiting: return ("Đang chờ tạo ghi chú", "Waiting to write notes")
        case .stateDone: return ("Xong", "Done")
        case .stateRecordingSaved: return ("Đã lưu bản ghi", "Recording saved")
        case .stateError: return ("Lỗi", "Error")
        case .stateWritingNotes: return ("Đang tạo ghi chú…", "Writing notes…")

        case .actionStartRecording: return ("Bắt đầu ghi", "Start recording")
        case .actionStart: return ("Bắt đầu", "Start")
        case .actionPause: return ("Tạm dừng", "Pause")
        case .actionResume: return ("Tiếp tục", "Resume")
        case .actionStopCreateNotes: return ("Dừng & tạo ghi chú", "Stop & create notes")
        case .actionStopSave: return ("Dừng & lưu", "Stop & save")
        case .actionStop: return ("Dừng", "Stop")
        case .actionDiscard: return ("Huỷ bản ghi", "Discard")
        case .actionDiscardEllipsis: return ("Huỷ bản ghi…", "Discard…")
        case .discardQuestion: return ("Huỷ bản ghi này? Âm thanh sẽ bị xoá.", "Discard this recording? The audio will be deleted.")
        case .discardConfirm: return ("Xoá bản ghi", "Delete recording")
        case .discardKeep: return ("Không, giữ lại", "No, keep it")

        case .actionOpenNotes: return ("Mở ghi chú", "Open notes")
        case .actionOpenLastNotes: return ("Mở ghi chú gần nhất", "Open last notes")
        case .actionShowInFinder: return ("Hiện trong Finder", "Show in Finder")
        case .actionCopySummary: return ("Sao chép tóm tắt", "Copy summary")
        case .actionRetry: return ("Thử lại", "Retry")
        case .actionCreateNotes: return ("Tạo ghi chú", "Create notes")
        case .actionCreateNotesNow: return ("Tạo ghi chú ngay", "Create notes now")
        case .actionCancel: return ("Huỷ", "Cancel")
        case .actionDismiss: return ("Đóng", "Dismiss")
        case .actionOpenTranscript: return ("Mở bản chép lời", "Open transcript")
        case .actionReprocess: return ("Xử lý lại", "Reprocess")
        case .actionShowLog: return ("Xem nhật ký xử lý", "Show pipeline log")
        case .actionOpenSettings: return ("Mở Cài đặt", "Open Settings")
        case .actionOpenSystemSettings: return ("Mở Cài đặt hệ thống", "Open System Settings")
        case .actionRelaunch: return ("Khởi động lại", "Relaunch")
        case .actionFix: return ("Sửa", "Fix")
        case .actionAllow: return ("Cho phép", "Allow")
        case .actionGotIt: return ("Đã hiểu", "Got it")
        case .actionSettingsEllipsis: return ("Cài đặt…", "Settings…")
        case .actionSettings: return ("Cài đặt", "Settings")
        case .actionOpenMain: return ("Mở MeetingNotes", "Open MeetingNotes")
        case .actionOpenNotesFolder: return ("Mở thư mục ghi chú", "Open notes folder")
        case .actionHideHour: return ("Ẩn 1 giờ", "Hide for 1 hour")
        case .actionCollapse: return ("Thu gọn", "Collapse")
        case .actionShowControls: return ("Hiện thanh điều khiển nổi", "Show floating control")
        case .actionResetPillPosition: return ("Đặt lại vị trí thanh điều khiển", "Reset floating control position")
        case .actionPermissionsEllipsis: return ("Quyền truy cập…", "Permissions…")
        case .actionNotNow: return ("Để sau", "Not now")
        case .actionSnoozeHour: return ("Tạm ẩn 1 giờ", "Snooze 1 h")
        case .actionStopNow: return ("Dừng ngay", "Stop now")
        case .actionKeepRecording: return ("Tiếp tục ghi", "Keep recording")
        case .actionRunTest: return ("Kiểm tra", "Run test")
        case .actionTesting: return ("Đang kiểm tra…", "Testing…")
        case .actionChange: return ("Đổi…", "Change…")
        case .actionUseDefault: return ("Dùng mặc định", "Use default")
        case .actionOpen: return ("Mở", "Open")
        case .actionUseFolder: return ("Dùng thư mục này", "Use Folder")
        case .actionOpenInDefaultApp: return ("Mở bằng ứng dụng mặc định", "Open in default app")

        case .menuAbout: return ("Giới thiệu Meeting Notes", "About Meeting Notes")
        case .menuHide: return ("Ẩn Meeting Notes", "Hide Meeting Notes")
        case .menuQuit: return ("Thoát Meeting Notes", "Quit Meeting Notes")
        case .menuEdit: return ("Sửa", "Edit")
        case .menuUndo: return ("Hoàn tác", "Undo")
        case .menuRedo: return ("Làm lại", "Redo")
        case .menuCut: return ("Cắt", "Cut")
        case .menuCopy: return ("Sao chép", "Copy")
        case .menuPaste: return ("Dán", "Paste")
        case .menuSelectAll: return ("Chọn tất cả", "Select All")
        case .menuWindow: return ("Cửa sổ", "Window")
        case .menuMinimize: return ("Thu nhỏ", "Minimize")
        case .menuClose: return ("Đóng", "Close")
        case .menuRecording: return ("Ghi âm", "Recording")
        case .menuRecentMeetings: return ("Cuộc họp gần đây", "Recent meetings")
        case .menuNoMeetings: return ("Chưa có cuộc họp nào", "No meetings yet")
        case .statusRecordingTime: return ("Đang ghi %1", "Recording %1")
        case .statusPausedTime: return ("Tạm dừng %1", "Paused %1")
        case .statusNotesReady: return ("Ghi chú đã sẵn sàng: %1", "Notes ready: %1")

        case .me: return ("Tôi", "Me")
        case .them: return ("Người khác", "Others")
        case .titlePlaceholder: return ("Tên cuộc họp", "Meeting title")
        case .titleTooltip: return ("Tên cuộc họp (dùng cho ghi chú và tên thư mục)", "Meeting title (used for the notes and the folder name)")
        case .micNotRecording: return ("Micro không ghi được – kiểm tra quyền hoặc thiết bị đầu vào", "Microphone not recording – check permission or input device")
        case .systemAudioMissingShort: return ("Chưa thu được tiếng người khác", "Others are not being recorded")
        case .systemAudioBanner:
            return ("Chưa thu được tiếng người khác — bật Screen & System Audio Recording cho MeetingNotes, rồi mở lại ứng dụng.",
                    "Other participants are not being recorded — enable Screen & System Audio Recording for MeetingNotes, then reopen the app.")
        case .othersSilent: return ("Không nghe thấy người khác hơn 10 giây", "No sound from others for 10 s+")
        case .hotkeyStartStop: return ("%1 bắt đầu/dừng", "%1 start/stop")
        case .hotkeyPause: return ("%1 tạm dừng/tiếp tục", "%1 pause/resume")
        case .pillHelp: return ("Meeting Notes – di chuột vào để mở, kéo để di chuyển.", "Meeting Notes – hover to open, drag to move.")
        case .startingCapture: return ("Đang khởi động ghi âm…", "Starting capture…")
        case .savingRecording: return ("Đang lưu bản ghi…", "Saving the recording…")
        case .appUsingMic: return ("%1 đang dùng micro.", "%1 is using the microphone.")
        case .permissionsAttention: return ("Cần cấp quyền micro hoặc âm thanh hệ thống.", "Microphone or system audio access needs attention.")
        case .finishing: return ("Đang hoàn tất…", "Finishing…")
        case .stageCached: return ("đã có sẵn", "cached")
        case .queuedOne: return ("Còn 1 cuộc họp đang chờ", "1 more meeting queued")
        case .queuedMany: return ("Còn %1 cuộc họp đang chờ", "%1 more meetings queued")
        case .audioSavedManual: return ("Đã lưu âm thanh. Ghi chú được tạo khi bạn yêu cầu.", "Audio saved. Notes are created when you ask.")
        case .audioKept: return ("Âm thanh vẫn được giữ.", "The audio is kept.")
        case .notesReadyFor: return ("Ghi chú đã sẵn sàng: %1", "Notes ready: %1")
        case .openWindowHelp: return ("Mở cửa sổ MeetingNotes", "Open the MeetingNotes window")
        case .idleHint: return ("Bấm Bắt đầu ghi khi cuộc họp bắt đầu.", "Click Start recording when the meeting begins.")
        case .hotkeysHeading: return ("Phím tắt", "Hotkeys")
        case .processingHeading: return ("Đang tạo ghi chú", "Writing notes")
        case .recentHeading: return ("Cuộc họp gần đây", "Recent meetings")
        case .noMeetingsYet: return ("Chưa có cuộc họp nào. Bản ghi sẽ xuất hiện ở đây.", "No meetings yet. Recordings will appear here.")
        case .permissionsHeading: return ("Quyền truy cập", "Permissions")
        case .microphone: return ("Micro", "Microphone")
        case .systemAudio: return ("Âm thanh hệ thống", "System audio")
        case .notificationsOptional: return ("Thông báo (không bắt buộc)", "Notifications (optional)")
        case .micDetail: return ("Ghi giọng của bạn (“Tôi”).", "Records your voice (“Me”).")
        case .systemAudioDetail:
            return ("Ghi tiếng người khác (“Người khác”). Quyền Screen & System Audio Recording; chỉ thu âm thanh, không lưu hình.",
                    "Records the other participants (“Them”). Screen & System Audio Recording permission; only audio is captured.")
        case .notificationsDetail: return ("Báo khi ghi chú đã sẵn sàng.", "A banner when notes are ready.")
        case .permAllowed: return ("Đã cho phép", "Allowed")
        case .permDenied: return ("Chưa cho phép", "Not allowed")
        case .permNotDetermined: return ("Chưa hỏi", "Not asked yet")
        case .permUnavailable: return ("Không khả dụng", "Unavailable")
        case .relaunchNote: return ("macOS chỉ áp dụng quyền mới sau khi ứng dụng khởi động lại.", "macOS applies the new permission only after the app restarts.")
        case .relaunchBlocked: return ("Chỉ khởi động lại được khi không ghi và không tạo ghi chú.", "Relaunch is only possible while not recording or writing notes.")
        case .gettingStartedHeading: return ("Bắt đầu sử dụng", "Getting started")
        case .gettingStarted1: return ("Mọi thứ chạy trên máy Mac này. Cấp hai quyền bên dưới rồi bấm Kiểm tra.", "Everything runs on this Mac. Grant the two permissions below, then run the test.")
        case .gettingStarted2: return ("Khi đang ghi, một thanh điều khiển nhỏ nổi ở cuối màn hình; di chuột vào để mở.", "While recording, a small floating control sits at the bottom of the screen; hover it to open it.")
        case .gettingStarted3: return ("Sau khi dừng, ghi chú được tạo trong nền; cửa sổ này hiển thị từng bước.", "After you stop, notes are written in the background; this window shows each step.")
        case .audioTestHeading: return ("Kiểm tra âm thanh (5 giây)", "Audio test (5 s)")
        case .audioTestHint: return ("Không lưu gì xuống đĩa. Phát một âm thanh ngắn để kiểm tra âm thanh hệ thống.", "Records nothing to disk. Plays a short sound to check system audio.")
        case .testStopFirst: return ("Hãy dừng ghi trước.", "Stop the recording first.")
        case .testMeOK: return ("Tôi: tốt (mức %1 dB)", "Me: OK (level %1 dB)")
        case .testMeSilent: return ("Tôi: im lặng – kiểm tra thiết bị đầu vào", "Me: silent – check the input device")
        case .testMeError: return ("Tôi: %1", "Me: %1")
        case .testThemOK: return ("Người khác: tốt (đã nghe thấy âm thử)", "Others: OK (heard the test sound)")
        case .testThemSilent: return ("Người khác: không nghe thấy gì – kiểm tra quyền Screen & System Audio Recording", "Others: nothing heard – check Screen & System Audio Recording")
        case .testThemNotPermitted: return ("Người khác: chưa được phép thu âm thanh hệ thống", "Others: system audio not permitted")
        case .micAccessDenied: return ("Không có quyền dùng micro", "Microphone access denied")
        case .readyHeading: return ("Ghi chú đã sẵn sàng", "Notes ready")
        case .notesFolder: return ("Thư mục ghi chú", "Notes folder")
        case .waitingHeading: return ("Đang chờ", "Waiting")
        case .recentDuration: return ("%1 · %2", "%1 · %2")
        case .notificationBody: return ("Bấm để mở ghi chú.", "Click to open the notes.")
        case .liveHeading: return ("Chép lời trực tiếp", "Live transcript")
        case .liveListening: return ("Đang nghe…", "Listening…")
        case .livePaused: return ("Chép lời trực tiếp tạm dừng – ghi chú vẫn đầy đủ", "Live transcript paused – notes will still be complete")

        case .meetingReady: return ("Có ghi chú", "Ready")
        case .meetingProcessing: return ("Đang xử lý", "Processing")
        case .meetingProcessingPercent: return ("Đang xử lý %1%", "Processing %1%")
        case .meetingQueued: return ("Đang chờ", "Queued")
        case .meetingRecording: return ("Đang ghi", "Recording")
        case .meetingFailed: return ("Thất bại", "Failed")
        case .meetingCancelled: return ("Đã huỷ", "Cancelled")
        case .meetingNotProcessed: return ("Chưa tạo ghi chú", "Not processed")

        case .stagePrepare: return ("Chuẩn bị âm thanh", "Prepare audio")
        case .stageDiarize: return ("Nhận diện người nói", "Identify speakers")
        case .stageTranscribe: return ("Chép lời", "Transcribe")
        case .stageSummarize: return ("Tóm tắt", "Summarize")
        case .stageRender: return ("Tạo tệp ghi chú", "Write notes file")
        case .stageFinalize: return ("Hoàn tất", "Finalize")

        case .toastAlreadyRecording: return ("Đang ghi rồi", "Already recording")
        case .toastStillSaving: return ("Vẫn đang lưu bản ghi trước", "Still saving the last recording")
        case .toastNotRecording: return ("Chưa ghi âm", "Not recording")
        case .toastStoppedCreating: return ("Đã dừng – đang tạo ghi chú…", "Stopped – creating notes…")
        case .toastPaused: return ("Đã tạm dừng", "Paused")
        case .toastAlreadyPaused: return ("Đang tạm dừng rồi", "Already paused")
        case .toastResumed: return ("Đã tiếp tục ghi", "Resumed")
        case .toastStoppedSaved: return ("Đã dừng – đã lưu bản ghi", "Stopped – recording saved")
        case .toastMeetingEndedCreating: return ("Cuộc họp đã kết thúc – đang tạo ghi chú…", "Meeting ended – creating notes…")
        case .toastMeetingEndedSaved: return ("Cuộc họp đã kết thúc – đã lưu bản ghi", "Meeting ended – recording saved")
        case .toastRecordingStarted: return ("Đã bắt đầu ghi", "Recording started")
        case .toastCouldNotStart: return ("Không thể bắt đầu ghi", "Could not start recording")
        case .toastDiscarded: return ("Đã huỷ bản ghi", "Recording discarded")
        case .toastCancelling: return ("Đang huỷ…", "Cancelling…")
        case .toastProcessingCancelled: return ("Đã huỷ tạo ghi chú", "Processing cancelled")
        case .toastHiddenHour: return ("Đã ẩn 1 giờ – mở lại từ Dock hoặc menu", "Hidden for 1 hour – reopen it from the Dock or menu")
        case .toastNoNotes: return ("Chưa có ghi chú", "No notes yet")
        case .toastNoSummary: return ("Chưa có tóm tắt", "No summary yet")
        case .toastSummaryCopied: return ("Đã sao chép tóm tắt", "Summary copied")
        case .toastUnknownCommand: return ("Lệnh không hợp lệ: %1", "Unknown command: %1")
        case .toastCouldNotRename: return ("Không đổi được tên: %1", "Could not rename: %1")

        case .errCouldNotStart: return ("Không thể bắt đầu ghi: %1", "Could not start recording: %1")
        case .errNoAudio: return ("Bản ghi không có âm thanh. Hãy kiểm tra quyền micro và âm thanh hệ thống.", "The recording has no audio. Check microphone and system audio permissions.")
        case .errCouldNotDelete: return ("Không xoá được bản ghi: %1", "Could not delete the recording: %1")
        case .errProcessingFailed: return ("Tạo ghi chú thất bại: %1", "Processing failed: %1")
        case .errNoNotesProduced: return ("Quá trình xử lý kết thúc mà không có ghi chú", "The pipeline finished without notes")
        case .errPipelineRejected: return ("Quá trình xử lý từ chối yêu cầu", "The pipeline rejected the request")
        case .errPipelineExit: return ("Xử lý thất bại (mã %1); xem pipeline.app.log", "Processing failed (exit %1); see pipeline.app.log")
        case .errWorkerStopped: return ("Tiến trình xử lý dừng đột ngột; âm thanh vẫn được giữ.", "The processing worker stopped unexpectedly; the audio is kept.")
        case .errWorkerNotRunning: return ("Tiến trình xử lý không chạy", "The processing worker is not running")
        case .errUvNotFound: return ("Không tìm thấy uv tại %1", "uv not found at %1")
        case .errPipelineNotConfigured: return ("Chưa cấu hình thư mục pipeline (Info.plist MNPipelineDir).", "Pipeline folder not configured (Info.plist MNPipelineDir).")
        case .errPipelineNotFound: return ("Không tìm thấy thư mục pipeline: %1", "Pipeline folder not found: %1")
        case .errNoAudioSource: return ("Không khởi động được nguồn âm thanh nào. %1", "No audio source could be started. %1")
        case .warnMicUnavailable: return ("Micro không dùng được: %1", "Microphone unavailable: %1")
        case .warnMicDenied:
            return ("Không có quyền dùng micro (Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Micro); chỉ ghi âm thanh hệ thống.",
                    "Microphone access denied (System Settings › Privacy & Security › Microphone); recording system audio only.")
        case .warnSystemNotRecorded: return ("Không ghi được âm thanh hệ thống: %1", "System audio not recorded: %1")
        case .warnMicResume: return ("Micro không tiếp tục được: %1", "Microphone could not resume: %1")
        case .warnSystemResume: return ("Âm thanh hệ thống không tiếp tục được: %1", "System audio could not resume: %1")
        case .warnTrackWriteFailed: return ("%1: ghi %2 thất bại: %3", "%1: writing %2 failed: %3")
        case .warnTrackNoAudio: return ("%1 không có âm thanh; đã bỏ track này.", "%1 produced no audio; track omitted.")
        case .warnTrackSilent: return ("Track %1 hoàn toàn im lặng (kiểm tra quyền hoặc thiết bị đầu vào).", "%1 track is completely silent (check permission or input device).")
        case .warnMeetingJSON: return ("Không ghi được meeting.json: %1", "Could not write meeting.json: %1")
        case .errNoMicDevice: return ("Không có thiết bị micro nào", "No microphone input device available")
        case .warnMicDeviceChanged: return ("Thiết bị micro đã đổi khi đang ghi; khoảng trống được lấp bằng im lặng.", "Microphone input changed during recording; the gap was filled with silence.")
        case .warnMicStoppedAfterChange: return ("Micro ngừng ghi sau khi đổi thiết bị đầu vào: %1", "Microphone stopped after an input device change: %1")
        case .errNoDisplay: return ("Không có màn hình nào để thu âm thanh hệ thống", "No display available for system audio capture")
        case .warnSystemStopped: return ("Thu âm thanh hệ thống đã dừng: %1", "System audio capture stopped: %1")
        case .waitIdlePlugged: return ("Đang chờ máy rảnh và cắm sạc", "Waiting until idle and plugged in")
        case .waitManual: return ("Ghi chú được tạo thủ công", "Notes are created manually")
        case .hotkeyInvalid: return ("Phím tắt “%1” không hợp lệ; dùng %2.", "Invalid hotkey “%1”; using %2.")
        case .hotkeyUnavailable: return ("Phím tắt %1 không dùng được (ứng dụng khác đang dùng?).", "Global hotkey %1 is unavailable (used by another app?).")

        case .setupHeading: return ("Cài đặt lần đầu", "First-time setup")
        case .setupIntro:
            return ("Meeting Notes chạy hoàn toàn trên máy này. Cần tải khoảng %1 một lần: môi trường Python, mô hình chép lời, nhận diện người nói và mô hình tóm tắt. Không cần tài khoản hay token. Bạn vẫn dùng máy bình thường; cài đặt tự tạm dừng khi bạn ghi âm hoặc đang tạo ghi chú.",
                    "Meeting Notes runs entirely on this Mac. It downloads about %1 once: the Python environment, the transcription, speaker and summary models. No account or token needed. Keep working meanwhile; setup pauses by itself while you record or notes are being created.")
        case .setupGatekeeperNote:
            return ("Bước “Vẫn mở” (Open Anyway) trong Cài đặt hệ thống chỉ cần một lần cho mỗi bản tải về, và bạn đã làm xong.",
                    "The “Open Anyway” step in System Settings is needed only once per download, and you have done it.")
        case .setupStepRuntime: return ("Môi trường Python", "Python environment")
        case .setupStepSpeech: return ("Mô hình chép lời (Whisper)", "Transcription model (Whisper)")
        case .setupStepDiarization: return ("Nhận diện người nói (FluidAudio)", "Speaker identification (FluidAudio)")
        case .setupStepOllama: return ("Ollama (chạy mô hình tóm tắt trên máy)", "Ollama (runs the summary model on this Mac)")
        case .setupStepSummary: return ("Mô hình tóm tắt %1", "Summary model %1")
        case .actionSetUp: return ("Cài đặt (~%1)", "Set up (~%1)")
        case .actionContinueSetup: return ("Tiếp tục cài đặt", "Continue setup")
        case .actionCheckAgain: return ("Kiểm tra lại", "Check again")
        case .actionDownloadOllama: return ("Tải Ollama…", "Download Ollama…")
        case .actionOpenOllama: return ("Mở Ollama", "Open Ollama")
        case .actionCopyBrewCommand: return ("Sao chép lệnh Homebrew", "Copy Homebrew command")
        case .setupWaitingRecording: return ("Tạm dừng trong lúc ghi âm; sẽ tự tiếp tục sau đó.", "Paused while recording; continues by itself afterwards.")
        case .setupWaitingProcessing: return ("Tạm dừng trong lúc tạo ghi chú; sẽ tự tiếp tục sau đó.", "Paused while notes are being created; continues by itself afterwards.")
        case .setupPaused: return ("Đã tạm dừng. Phần đã tải được giữ lại.", "Paused. Everything downloaded so far is kept.")
        case .setupComplete: return ("Đã cài đặt xong. Bạn có thể bắt đầu ghi cuộc họp.", "Setup complete. You can record meetings now.")
        case .setupFailed: return ("Bước này chưa xong: %1", "This step did not finish: %1")
        case .setupOllamaMissing:
            return ("Chưa có Ollama. Tải bản chính thức từ ollama.com, mở nó một lần, rồi bấm Kiểm tra lại. Hoặc dùng Homebrew: brew install ollama && brew services start ollama.",
                    "Ollama is not installed. Download the official app from ollama.com, open it once, then press Check again. Or use Homebrew: brew install ollama && brew services start ollama.")
        case .setupOllamaNotRunning: return ("Ollama đã cài nhưng chưa chạy. Mở Ollama rồi bấm Kiểm tra lại.", "Ollama is installed but not running. Open it, then press Check again.")
        case .setupMoveToApplications:
            return ("Hãy kéo Meeting Notes vào thư mục Applications rồi mở lại từ đó: quyền micro và mở khi đăng nhập cần một vị trí cố định.",
                    "Drag Meeting Notes to the Applications folder and open it from there: microphone permission and Launch at Login need a fixed location.")
        case .setupStepWaiting: return ("Đang chờ", "Waiting")
        case .setupStepDone: return ("Xong", "Done")
        case .setupWorking: return ("Đang chạy…", "Working…")
        case .errSetupIncomplete: return ("Chưa cài đặt xong. Mở cửa sổ chính và bấm Cài đặt.", "Setup is not finished. Open the main window and press Set up.")

        case .autoStopTitle: return ("Có vẻ cuộc họp đã kết thúc — dừng sau %1 giây", "Meeting seems to have ended — stopping in %1 s")
        case .autoStopDetail: return ("%1. Âm thanh được giữ và ghi chú sẽ được tạo.", "%1. The audio is kept and notes are created.")
        case .autoStopSilence: return ("Không có âm thanh trong %1 phút", "No sound for %1 min")
        case .autoStopAppEnded: return ("%1 đã ngừng dùng micro", "%1 stopped using the microphone")
        case .detectionTitle: return ("%1 đang dùng micro — bắt đầu ghi chú?", "%1 is using the microphone — start notes?")
        case .detectionHint: return ("Hãy báo cho mọi người biết bạn đang ghi chú.", "Tell participants you're taking notes.")

        case .defaultMeetingTitle: return ("Cuộc họp", "Meeting")
        case .appMeetingTitle: return ("Cuộc họp %1", "%1 meeting")

        case .etaUnderMinute: return ("Còn chưa đến 1 phút", "less than a minute left")
        case .etaMinutes: return ("Còn khoảng %1 phút", "about %1 min left")
        case .etaHours: return ("Còn khoảng %1 giờ", "about %1 h left")
        case .etaHoursMinutes: return ("Còn khoảng %1 giờ %2 phút", "about %1 h %2 min left")
        case .durSeconds: return ("%1 giây", "%1 s")
        case .durMinutes: return ("%1 phút", "%1 min")
        case .durHours: return ("%1 giờ", "%1 h")
        case .durHoursMinutes: return ("%1 giờ %2 phút", "%1 h %2 min")

        case .settingsWindowTitle: return ("Cài đặt Meeting Notes", "Meeting Notes Settings")
        case .groupBasics: return ("Cơ bản", "Basics")
        case .groupDuringMeeting: return ("Khi họp", "During meetings")
        case .groupAfterMeeting: return ("Sau khi họp", "After meetings")
        case .groupAdvanced: return ("Nâng cao", "Advanced")
        case .language: return ("Ngôn ngữ (Language)", "Language (Ngôn ngữ)")
        case .helpLanguage: return ("Chữ trong app đổi ngay.", "The app's text changes right away.")
        case .launchAtLogin: return ("Mở cùng máy", "Open at login")
        case .helpLaunchAtLogin: return ("Để không quên ghi khi vào họp.", "So you never forget to record a meeting.")
        case .loginNeedsApproval: return ("Cần cho phép trong Cài đặt hệ thống › Cài đặt chung › Mục đăng nhập.", "Needs approval in System Settings › General › Login Items.")
        case .loginUnavailable: return ("Không khả dụng (hãy chạy bản đã cài trong ~/Applications)", "Unavailable (run the installed app from ~/Applications)")
        case .actionOpenLoginItems: return ("Mở Mục đăng nhập…", "Open Login Items…")
        case .missingPermissions: return ("Thiếu quyền để ghi", "Recording needs permission")
        case .helpMissingPermissions: return ("Mở đúng mục trong Cài đặt hệ thống để cho phép.", "Opens the right place in System Settings.")
        case .actionGrantMicrophone: return ("Micro…", "Microphone…")
        case .actionGrantSystemAudio: return ("Âm thanh hệ thống…", "System audio…")
        case .setupUnfinished: return ("Thiết lập lần đầu chưa xong", "First-run setup is not finished")
        case .helpSetupUnfinished: return ("Xong bước này thì mới viết được ghi chú.", "Notes can be written once it is done.")
        case .actionOpenSetup: return ("Mở thiết lập", "Open setup")
        case .suggestRecording: return ("Hỏi ghi khi có cuộc họp", "Ask to record when a meeting starts")
        case .helpDetection: return ("Khi Zoom, Meet, Teams… bật micro. App không bao giờ tự ghi.", "When Zoom, Meet, Teams… turn on the mic. The app never records on its own.")
        case .detectionRequires: return ("Cần macOS 14.2 trở lên.", "Needs macOS 14.2 or later.")
        case .stopOnCallEnd: return ("Tự dừng khi cuộc gọi kết thúc", "Stop when the call ends")
        case .helpStopOnCallEndNeedsDetection: return ("Cần bật “Hỏi ghi khi có cuộc họp” ở trên.", "Needs “Ask to record when a meeting starts” above.")
        case .helpCountdown: return ("Đếm ngược 60 giây rồi dừng; bấm “Tiếp tục ghi” để giữ.", "Counts down 60 s, then stops; click “Keep recording” to continue.")
        case .stopAfterSilence: return ("Tự dừng khi im lặng", "Stop after silence")
        case .silenceNever: return ("Không tự dừng", "Never")
        case .helpSilence: return ("Khi không ai nói trong khoảng này; cũng đếm ngược 60 giây trước.", "When nobody speaks for this long; also counts down 60 s first.")
        case .helpSilenceOff: return ("App ghi đến khi bạn bấm Dừng.", "Records until you click Stop.")
        case .shortcutsLabel: return ("Phím tắt", "Shortcuts")
        case .helpShortcuts: return ("Dùng được khi đang ở app khác.", "Work from any app.")
        case .hotkeyNone: return ("không có", "none")
        case .createNotesLabel: return ("Viết ghi chú", "Write notes")
        case .modeRightAway: return ("Ngay sau buổi họp", "Right after the meeting")
        case .modeWhenIdle: return ("Khi máy rảnh và cắm sạc", "When idle and plugged in")
        case .modeManual: return ("Khi tôi bấm", "When I click")
        case .helpRightAway: return ("Chép lời và tóm tắt ngay trên máy, chạy nhẹ để máy không bị chậm.", "Transcribes and summarizes on this Mac, gently so it stays responsive.")
        case .helpWhenIdle: return ("Chờ cắm sạc và 3 phút không dùng máy. Cần gấp thì bấm “Tạo ghi chú ngay”.", "Waits for power and 3 minutes without use. In a hurry? Click “Create notes now”.")
        case .helpManual: return ("Chỉ lưu bản ghi; bấm “Tạo ghi chú” ở buổi họp khi cần.", "Only saves the recording; click “Create notes” on a meeting when needed.")
        case .summaryModelLabel: return ("Chất lượng tóm tắt", "Summary quality")
        case .modelLight: return ("Nhanh (máy 8 GB)", "Fast (8 GB Mac)")
        case .modelBetter: return ("Kỹ hơn (cần 16 GB)", "Thorough (needs 16 GB)")
        case .helpSummary: return ("Chạy bằng Ollama ngay trên máy; “Kỹ hơn” tải thêm ~5 GB lần đầu.", "Runs in Ollama on this Mac; “Thorough” downloads ~5 GB once.")
        case .helpSummaryLowMemory: return ("Máy này có %1 GB RAM: “Kỹ hơn” có thể rất chậm. Nên chọn “Nhanh”.", "This Mac has %1 GB of RAM: “Thorough” may be very slow. “Fast” is safer.")
        case .saveLocation: return ("Nơi lưu", "Save to")
        case .liveTranscriptionToggle: return ("Hiện chữ khi đang họp", "Show text during the meeting")
        case .liveTranscriptionCaption: return ("Chỉ chạy khi cắm sạc, tốn thêm RAM. Ghi chú sau họp không đổi.", "Runs only when plugged in and uses more memory. Notes do not change.")
        case .livePolishToggle: return ("Làm chữ dễ đọc", "Make the text easier to read")
        case .livePolishCaption: return ("Viết hoa, bỏ tiếng đệm; áp dụng từ lần ghi sau.", "Capitalizes and drops fillers, from the next recording on.")
        case .pillLabel: return ("Thanh nổi", "Floating control")
        case .pillWhileRecording: return ("Khi đang ghi", "While recording")
        case .pillAlways: return ("Luôn hiện", "Always")
        case .pillNever: return ("Không hiện", "Never")
        case .helpPill: return ("Thanh nhỏ có đồng hồ và nút dừng.", "A small bar with the timer and Stop.")
        case .helpPillNever: return ("Dừng ghi bằng thanh menu hoặc phím tắt.", "Stop from the menu bar or with the shortcut.")
        case .actionResetPosition: return ("Đặt lại vị trí", "Reset position")
        case .showInDock: return ("Hiện biểu tượng ở Dock", "Show icon in the Dock")
        case .helpDock: return ("Tắt: app chỉ nằm trên thanh menu.", "Off: the app lives only in the menu bar.")
        case .version: return ("Phiên bản", "Version")
        case .openForMeetings: return ("Tự mở app khi vào họp", "Open the app when a meeting starts")
        case .helpOpenForMeetings: return ("Mở và hỏi ghi khi Zoom, Meet… bắt đầu, kể cả sau khi Thoát. Tắt để ngừng.", "Opens and asks to record when Zoom, Meet… start, even after Quit. Turn off to stop.")
        case .liveShowRaw: return ("Xem bản gốc", "Show raw")
        case .liveShowPolished: return ("Xem bản đã làm gọn", "Show tidied")

        case .summaryInProgress: return ("Đang tóm tắt…", "Summary in progress…")
        case .noNotes: return ("Chưa có ghi chú.", "No notes yet.")
        case .searchTranscript: return ("Tìm trong bản chép lời", "Search transcript")
        case .summaryHeading: return ("Tóm tắt", "Summary")
        case .decisionsHeading: return ("Quyết định chính", "Key decisions")
        case .actionItemsHeading: return ("Việc cần làm", "Action items")
        case .openQuestionsHeading: return ("Câu hỏi còn mở", "Open questions")
        case .transcriptHeading: return ("Bản chép lời", "Transcript")
        case .noSpeech: return ("Không có lời nào được chép.", "No speech was transcribed.")
        case .noMatches: return ("Không tìm thấy kết quả.", "No matches.")
        case .pausedAt: return ("Tạm dừng %1 lúc %2", "Paused %1 at %2")
        case .dueDate: return ("hạn %1", "due %1")
        }
    }
}
