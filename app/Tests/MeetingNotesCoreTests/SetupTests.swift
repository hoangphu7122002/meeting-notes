import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("First-run setup state machine")
struct SetupMachineTests {
    /// Runs the machine like SetupRunner does: start the next step, finish it.
    func runNext(_ machine: inout SetupMachine) -> SetupStep? {
        guard let step = machine.nextStep else { return nil }
        machine.stepStarted(step)
        if step == .ollama { machine.ollama(.running) } else { machine.finished(step) }
        return step
    }

    @Test func freshInstallWaitsForTheUserThenRunsEveryStepInOrder() {
        var machine = SetupMachine()
        #expect(machine.phase == .notStarted && machine.nextStep == nil)
        machine.start()
        var order: [SetupStep] = []
        while let step = runNext(&machine) { order.append(step) }
        #expect(order == SetupStep.allCases)
        #expect(machine.phase == .complete && machine.overallFraction == 1)
    }

    @Test func finishedStepsAreSkippedAndAllDoneIsComplete() {
        var machine = SetupMachine(done: [.runtime, .speech])
        machine.start()
        #expect(machine.nextStep == .diarization)
        #expect(SetupMachine(done: Set(SetupStep.allCases)).phase == .complete)
    }

    @Test func anUpdateResumesByItselfWithOnlyTheRuntimeStep() {
        var machine = SetupMachine(done: [.speech, .diarization, .ollama, .summary], started: true)
        #expect(machine.phase == .running && machine.nextStep == .runtime)
        _ = runNext(&machine)
        #expect(machine.phase == .complete)
    }

    @Test func cancelPutsTheRunningStepBackAndContinueResumesIt() {
        var machine = SetupMachine()
        machine.start()
        machine.stepStarted(.runtime)
        machine.progress(.runtime, fraction: 0.4, detail: "Downloading torch")
        machine.cancel()
        #expect(machine.phase == .paused && machine.state(.runtime) == .pending && machine.nextStep == nil)
        machine.start()
        #expect(machine.nextStep == .runtime)
    }

    @Test func recordingOrProcessingPausesSetupAndItResumesByItself() {
        var machine = SetupMachine(done: [.runtime])
        machine.start()
        machine.stepStarted(.speech)
        machine.setBusy(.recording)
        #expect(machine.phase == .waiting(.recording) && machine.state(.speech) == .pending && machine.nextStep == nil)
        machine.setBusy(.processing)
        #expect(machine.phase == .waiting(.processing))
        machine.setBusy(nil)
        #expect(machine.phase == .running && machine.nextStep == .speech)
    }

    @Test func busyNeverStartsASetupTheUserDidNotStart() {
        var machine = SetupMachine()
        machine.setBusy(.recording)
        machine.setBusy(nil)
        #expect(machine.phase == .notStarted)
        machine.start()
        machine.cancel()
        machine.setBusy(nil)
        #expect(machine.phase == .paused)
    }

    @Test func aFailureBlocksAndRetryRunsTheStepAgain() {
        var machine = SetupMachine(done: [.runtime])
        machine.start()
        machine.stepStarted(.speech)
        machine.failed(.speech, message: "HTTP 503")
        #expect(machine.phase == .blocked && machine.state(.speech) == .failed("HTTP 503") && machine.nextStep == nil)
        machine.start()
        #expect(machine.state(.speech) == .pending && machine.nextStep == .speech)
    }

    @Test func missingOllamaNeedsTheUserAndIsNeverInstalled() {
        var machine = SetupMachine(done: [.runtime, .speech, .diarization])
        machine.start()
        machine.stepStarted(.ollama)
        machine.ollama(.missing)
        #expect(machine.state(.ollama) == .needsUser(.missing) && machine.phase == .blocked)
        #expect(machine.nextStep == nil)  // the summary model is not pulled without Ollama
        machine.start()  // "Check again"
        machine.stepStarted(.ollama)
        machine.ollama(.running)
        #expect(machine.nextStep == .summary)
    }

    @Test func lateResultsOfAStoppedStepAreIgnored() {
        var machine = SetupMachine()
        machine.start()
        machine.stepStarted(.runtime)
        machine.cancel()
        machine.finished(.runtime)
        machine.failed(.runtime, message: "x")
        machine.progress(.runtime, fraction: 0.5, detail: nil)
        #expect(machine.state(.runtime) == .pending && machine.phase == .paused)
    }

    @Test func progressIsWeightedByDownloadSizeAndKeepsOldValues() {
        var machine = SetupMachine(done: [.runtime, .speech, .diarization, .ollama])
        machine.start()
        machine.stepStarted(.summary)
        machine.progress(.summary, fraction: 0.5, detail: "Downloading qwen3:4b")
        machine.progress(.summary, fraction: nil, detail: nil)
        #expect(machine.state(.summary) == .running(fraction: 0.5, detail: "Downloading qwen3:4b"))
        let expected = (Double(SetupStep.totalDownloadBytes) - 0.5 * Double(SetupStep.summary.downloadBytes))
            / Double(SetupStep.totalDownloadBytes)
        #expect(abs(machine.overallFraction - expected) < 1e-9)
        #expect(machine.remainingBytes == SetupStep.summary.downloadBytes)
        #expect(SetupStep.totalDownloadBytes > 3_000_000_000 && SetupStep.totalDownloadBytes < 3_600_000_000)
    }

    @Test func ollamaAvailabilityIsClassified() {
        #expect(OllamaAvailability.classify(reachable: true, hasApp: false, hasCLI: false) == .running)
        #expect(OllamaAvailability.classify(reachable: false, hasApp: true, hasCLI: false) == .notRunning(hasApp: true))
        #expect(OllamaAvailability.classify(reachable: false, hasApp: false, hasCLI: true) == .notRunning(hasApp: false))
        #expect(OllamaAvailability.classify(reachable: false, hasApp: false, hasCLI: false) == .missing)
    }

    @Test func setupJSONLinesAreParsed() {
        let line = SetupLine(data: Data(#"{"event":"setup","step":"summary","status":"progress","message":"pulling","fraction":0.25}"#.utf8))
        #expect(line?.step == "summary" && line?.status == "progress" && line?.fraction == 0.25 && line?.message == "pulling")
        #expect(SetupLine(data: Data(#"{"event":"progress","step":"x","status":"y"}"#.utf8)) == nil)
        #expect(SetupLine(data: Data("not json".utf8)) == nil)
    }
}

@Suite("Packaged runtime paths and records")
struct RuntimeLayoutTests {
    let support = URL(fileURLWithPath: "/Users/me/Library/Application Support/MeetingNotes")
    var layout: RuntimeLayout { RuntimeLayout(supportDir: support) }

    @Test func everythingLivesUnderTheRuntimeFolderNeverInTheBundle() {
        let root = support.path + "/runtime"
        #expect(layout.root.path == root)
        #expect(layout.pipelineDir.path == root + "/pipeline" && layout.cli.path == root + "/pipeline/.venv/bin/meeting-notes")
        #expect(layout.uvPath.path == root + "/bin/uv" && layout.hubCacheDir.path == root + "/models/huggingface/hub")
        #expect(layout.fluidAudioDir.path == root + "/models/fluidaudio")
        // The pipeline finds the marker next to pipeline/ (config/install.py: REPO_ROOT = parent of pipeline/).
        #expect(PipelineLocator.markerPath(forPipeline: layout.pipelineDir.path) == layout.markerURL.path)
    }

    @Test func markerHasTheSharedInstallKeysAndPackagedMode() throws {
        let data = layout.marker(appPath: "/Applications/MeetingNotes.app", appVersion: "0.2.0+1",
                                 date: Date(timeIntervalSince1970: 0))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["mode"] as? String == "packaged" && json["app_version"] as? String == "0.2.0+1")
        #expect(json["hf_hub_cache"] as? String == layout.hubCacheDir.path && json["app"] as? String == "/Applications/MeetingNotes.app")
        let marker = try #require(PipelineLocator.Marker.parse(data))
        #expect(marker.pipelineDir == layout.pipelineDir.path && marker.uvPath == layout.uvPath.path)
    }

    @Test func syncUsesAManagedPythonAndTheBundledLockOnly() {
        let env = layout.syncEnvironment(["VIRTUAL_ENV": "/x/.venv", "UV_PROJECT_ENVIRONMENT": "/y", "HOME": "/Users/me"])
        #expect(env["VIRTUAL_ENV"] == nil && env["UV_PROJECT_ENVIRONMENT"] == nil && env["HOME"] == "/Users/me")
        #expect(env["UV_PYTHON_PREFERENCE"] == "only-managed" && env["UV_PYTHON_INSTALL_DIR"] == layout.pythonDir.path)
        #expect(env["UV_CACHE_DIR"] == layout.uvCacheDir.path)
        #expect(layout.syncArguments.contains("--frozen") && layout.syncArguments.contains("--no-dev"))
    }

    @Test func recordTiesTheRuntimeToTheAppVersionButNotTheModels() {
        var record = SetupRecord()
        record.markDone(.runtime, appVersion: "0.1.0+1")
        record.markDone(.speech, appVersion: "0.1.0+1")
        record.markDone(.summary, appVersion: "0.1.0+1")
        let parsed = SetupRecord.parse(record.encoded())
        #expect(parsed == record)
        #expect(parsed.doneSteps(appVersion: "0.1.0+1", runtimeReady: true) == [.runtime, .speech, .summary, .ollama])
        #expect(parsed.doneSteps(appVersion: "0.2.0+1", runtimeReady: true) == [.speech, .summary, .ollama])
        #expect(parsed.doneSteps(appVersion: "0.1.0+1", runtimeReady: false) == [.speech, .summary, .ollama])
        #expect(SetupRecord.parse(Data("garbage".utf8)) == SetupRecord())
    }

    @Test func appLocationNeedsAnApplicationsFolder() {
        let home = "/Users/me"
        #expect(AppLocation.classify(bundlePath: "/Applications/MeetingNotes.app", home: home) == .applications)
        #expect(AppLocation.classify(bundlePath: "/Users/me/Applications/MeetingNotes.app", home: home) == .applications)
        #expect(AppLocation.classify(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/MeetingNotes.app", home: home) == .translocated)
        #expect(AppLocation.classify(bundlePath: "/Volumes/Meeting Notes 0.1.0/MeetingNotes.app", home: home) == .diskImage)
        #expect(AppLocation.classify(bundlePath: "/Users/me/Downloads/MeetingNotes.app", home: home) == .elsewhere)
    }
}

@Suite("Pipeline location of the packaged app")
struct PackagedPipelineLocationTests {
    let runtime = "/Users/me/Library/Application Support/MeetingNotes/runtime"

    func marker(_ root: String) -> Data {
        Data(#"{"version":1,"mode":"packaged","pipeline_dir":"\#(root)/pipeline","uv_path":"\#(root)/bin/uv"}"#.utf8)
    }

    @Test func packagedRuntimeIsUsedOnceSetupWroteItsMarker() {
        let read: (String) -> Data? = { [runtime] path in path == "\(runtime)/shared-install.json" ? marker(runtime) : nil }
        let loc = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: nil, pipelineEnv: nil, uvOverride: nil,
                                          uvInfo: nil, packagedRoot: runtime, readFile: read)
        #expect(loc == PipelineLocation(pipelineDir: "\(runtime)/pipeline", uvPath: "\(runtime)/bin/uv", shared: true))
        // The worker then never syncs the environment (the setup does).
        let env = PipelineLocator.workerEnvironment([:], location: loc!)
        #expect(env["UV_NO_SYNC"] == "1" && env["UV_FROZEN"] == "1")
    }

    @Test func beforeSetupThereIsNoPipelineUnlessASharedInstallExists() {
        let none = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: nil, pipelineEnv: nil, uvOverride: nil,
                                           uvInfo: nil, packagedRoot: runtime, readFile: { _ in nil })
        #expect(none == nil)
        let shared = "/Users/Shared/MeetingNotes"
        let read: (String) -> Data? = { path in path == "\(shared)/shared-install.json" ? marker(shared) : nil }
        let loc = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: nil, pipelineEnv: nil, uvOverride: nil,
                                          uvInfo: nil, packagedRoot: runtime, readFile: read)
        #expect(loc?.pipelineDir == "\(shared)/pipeline")
    }

    @Test func devOverridesStillWinOverThePackagedRuntime() {
        let read: (String) -> Data? = { [runtime] path in path == "\(runtime)/shared-install.json" ? marker(runtime) : nil }
        let loc = PipelineLocator.resolve(pipelineOverride: "/Users/me/meeting-notes/pipeline", pipelineInfo: nil,
                                          pipelineEnv: nil, uvOverride: nil, uvInfo: nil, packagedRoot: runtime, readFile: read)
        #expect(loc?.pipelineDir == "/Users/me/meeting-notes/pipeline" && loc?.shared == false)
    }
}
