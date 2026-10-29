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
        XCTAssertTrue(local.canJumpFromNotch)
        XCTAssertEqual(local.codexDesktopURL?.absoluteString, "codex://threads/" + id)
        local.termBundleId = nil
        local.remoteHostId = "remote-ssh-codex-managed:test"
        let remoteURL = try XCTUnwrap(local.codexDesktopURL)
        XCTAssertEqual(URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "hostId", value: local.remoteHostId)])
        XCTAssertTrue(local.canActivateSession)
        local.remoteHostId = "unrelated-ssh-server"
        XCTAssertNil(local.codexDesktopURL)
        local.remoteHostId = "remote-ssh-codex-managed:test"
        local.providerSessionId = "../settings"
        XCTAssertNil(local.codexDesktopURL)
        XCTAssertFalse(local.canActivateSession)
        XCTAssertFalse(local.canJumpFromNotch)
        local.source = "claude"
        XCTAssertNil(local.codexDesktopURL)
    }

    func testRemoteSSHCardResolvesCodexHostFromThreadMembership() throws {
        let id = "00000000-0000-4000-8000-000000000001"
        let host = "remote-ssh-codex-managed:test"
        var remote = SessionSnapshot()
        remote.source = "codex"
        remote.providerSessionId = id
        remote.remoteHostId = "codeisland-ssh-host"
        let state: [String: Any] = ["thread-project-membership-host-ids": [id: host]]
        let url = try XCTUnwrap(remote.codexDesktopURL(state: state))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "threads")
        XCTAssertEqual(components.path, "/" + id)
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "hostId", value: host)])
        XCTAssertNil(remote.codexDesktopURL(state: [:]))
        XCTAssertNil(remote.codexDesktopURL(state: ["thread-project-membership-host-ids": [id: "local"]]))
        remote.source = "claude"
        XCTAssertNil(remote.codexDesktopURL(state: state))
    }

    func testRemoteThreadResolvesMigratedHostWithoutLegacyMembership() throws {
        var remote = SessionSnapshot()
        remote.source = "codex"
        remote.remoteHostId = "codeisland-ssh-host"
        let id = "01a186c0-4a9c-7402-b9a3-4fb17ef71c43"
        remote.providerSessionId = id
        let host = "remote-ssh-codex-managed:d2ef6974-5cef-48fa-a68c-5be2a1ae4b67"
        let key = "app-server-migrated-pinned-thread-ids-by-host"
        let state: [String: Any] = [key: [host + ":/home/leo/.codex": [id]]]
        let url = try XCTUnwrap(remote.codexDesktopURL(state: state))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "hostId", value: host)])
        XCTAssertNil(remote.codexDesktopURL(state: [key: ["local:/home/leo/.codex": [id]]]))
        XCTAssertNil(remote.codexDesktopURL(state: [key: [host + ":/home/leo/.codex": ["other"]]]))
        XCTAssertNil(remote.codexDesktopURL(state: [key: [
            host + ":/home/leo/.codex": [id],
            "remote-ssh-codex-managed:other:/home/leo/.codex": [id]
        ]]))
    }

}
