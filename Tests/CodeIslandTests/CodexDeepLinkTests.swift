import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class CodexDeepLinkTests: XCTestCase {
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
