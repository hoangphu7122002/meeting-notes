import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Pipeline location (per-user and shared install)")
struct PipelineLocationTests {
    let shared = "/Users/Shared/MeetingNotes"
    var marker: Data {
        Data(#"{"version":1,"pipeline_dir":"/Users/Shared/MeetingNotes/pipeline","uv_path":"/Users/Shared/MeetingNotes/bin/uv"}"#.utf8)
    }

    func files(_ map: [String: Data]) -> (String) -> Data? { { map[$0] } }

    @Test func perUserInstallUsesTheBakedInfoPlistPaths() {
        let loc = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: "/Users/me/meeting-notes/pipeline",
                                          pipelineEnv: nil, uvOverride: nil, uvInfo: "/Users/me/.local/bin/uv",
                                          readFile: files([:]))
        #expect(loc == PipelineLocation(pipelineDir: "/Users/me/meeting-notes/pipeline", uvPath: "/Users/me/.local/bin/uv",
                                        shared: false))
    }

    @Test func overridesWinThenInfoThenEnvironment() {
        let loc = PipelineLocator.resolve(pipelineOverride: "/custom", pipelineInfo: "/info", pipelineEnv: "/env",
                                          uvOverride: " ", uvInfo: nil, readFile: files([:]))
        #expect(loc?.pipelineDir == "/custom" && loc?.uvPath == PipelineLocator.defaultUvPath)
        let env = PipelineLocator.resolve(pipelineOverride: "", pipelineInfo: nil, pipelineEnv: "/env",
                                          uvOverride: nil, uvInfo: nil, readFile: files([:]))
        #expect(env?.pipelineDir == "/env")
    }

    @Test func nothingConfiguredAndNoSharedInstallIsNil() {
        #expect(PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: nil, pipelineEnv: nil, uvOverride: nil,
                                        uvInfo: nil, readFile: files([:])) == nil)
    }

    @Test func sharedMarkerIsTheFallbackAndItsUvBeatsAStaleInfoPlist() {
        let read = files(["\(shared)/shared-install.json": marker])
        let fallback = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: nil, pipelineEnv: nil,
                                               uvOverride: nil, uvInfo: nil, readFile: read)
        #expect(fallback == PipelineLocation(pipelineDir: "\(shared)/pipeline", uvPath: "\(shared)/bin/uv", shared: true))
        // An app baked with the shared pipeline but a private uv (other account cannot run it) uses the shared uv.
        let baked = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: "\(shared)/pipeline", pipelineEnv: nil,
                                            uvOverride: nil, uvInfo: "/Users/hoangphu/.local/bin/uv", readFile: read)
        #expect(baked?.uvPath == "\(shared)/bin/uv" && baked?.shared == true)
        let user = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: "\(shared)/pipeline", pipelineEnv: nil,
                                           uvOverride: "/opt/uv", uvInfo: nil, readFile: read)
        #expect(user?.uvPath == "/opt/uv")
    }

    @Test func aPerUserPipelineIgnoresTheSharedMarker() {
        let read = files(["\(shared)/shared-install.json": marker])
        let loc = PipelineLocator.resolve(pipelineOverride: nil, pipelineInfo: "/Users/me/meeting-notes/pipeline",
                                          pipelineEnv: nil, uvOverride: nil, uvInfo: "/Users/me/.local/bin/uv", readFile: read)
        #expect(loc?.shared == false && loc?.uvPath == "/Users/me/.local/bin/uv")
    }

    @Test func markerSitsNextToThePipelineDir() {
        #expect(PipelineLocator.markerPath(forPipeline: "\(shared)/pipeline/") == "\(shared)/shared-install.json")
    }

    @Test func sharedWorkerNeverSyncsTheEnvironment() {
        let loc = PipelineLocation(pipelineDir: "\(shared)/pipeline", uvPath: "\(shared)/bin/uv", shared: true)
        let env = PipelineLocator.workerEnvironment(["PATH": "/usr/bin", "UV_FROZEN": "0"], location: loc)
        #expect(env == ["PATH": "/usr/bin", "UV_NO_SYNC": "1", "UV_FROZEN": "0", "UV_PYTHON_DOWNLOADS": "never"])
        let perUser = PipelineLocation(pipelineDir: "/p", uvPath: "/uv", shared: false)
        #expect(PipelineLocator.workerEnvironment(["A": "1"], location: perUser) == ["A": "1"])
    }
}
