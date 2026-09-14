import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class CodexDeepLinkTests: XCTestCase {
    func testRolloutFilenameWithSuffixUsesThreadUUID() {
        let id = "00000000-0000-4000-8000-000000000001"
        let prefix = "rollout-2026-09-14T08-32-49-" + id
        XCTAssertEqual(AppState.extractCodexSessionId(from: prefix + ".jsonl"), id)
        XCTAssertEqual(AppState.extractCodexSessionId(from: prefix + "_00000000-0000-4000-8000-000000000002.jsonl"), id)
        XCTAssertEqual(AppState.extractCodexSessionId(from: "rollout-invalid.jsonl"), "")
    }

    func testCompactSelectionSkipsStaleIdlePointers() {
        let state = AppState()
        var idle = SessionSnapshot()
        idle.status = .idle
        var working = SessionSnapshot()
        working.status = .processing
        state.sessions = ["idle": idle, "working": working]
        state.activeSessionId = "idle"
        state.rotatingSessionId = "idle"
        XCTAssertEqual(state.compactSessionId, "working")
        state.sessions["another"] = working
        state.rotatingSessionId = "another"
        XCTAssertEqual(state.compactSessionId, "another")
        state.sessions["working"]?.status = .idle
        state.sessions["another"]?.status = .idle
        XCTAssertEqual(state.sessions[state.compactSessionId!]!.status, .idle)
    }

    func testLocalAndRemoteUseProviderUUIDAndKeepOtherSourcesUnchanged() throws {
        let id = "00000000-0000-4000-8000-000000000001"
        var local = SessionSnapshot()
        local.source = "codex"
        local.termBundleId = "com.openai.codex"
        local.providerSessionId = id
        local.sessionTitle = "真实任务名"
        XCTAssertEqual(local.codexDesktopURL?.absoluteString, "codex://threads/" + id)
        local.remoteHostId = "remote-ssh-server"
        XCTAssertTrue(local.canActivateSession)
        XCTAssertEqual(local.codexDesktopURL?.absoluteString, "codex://threads/" + id)
        local.termBundleId = nil
        local.remoteHostId = "remote-ssh-codex-managed:test"
        XCTAssertEqual(local.codexDesktopURL?.absoluteString, "codex://threads/" + id)
        XCTAssertTrue(local.canActivateSession)
        local.remoteHostId = "unrelated-ssh-server"
        XCTAssertNil(local.codexDesktopURL)
        local.remoteHostId = "remote-ssh-codex-managed:test"
        local.providerSessionId = "../settings"
        XCTAssertNil(local.codexDesktopURL)
        XCTAssertFalse(local.canActivateSession)
        local.source = "claude"
        XCTAssertNil(local.codexDesktopURL)
    }

}
