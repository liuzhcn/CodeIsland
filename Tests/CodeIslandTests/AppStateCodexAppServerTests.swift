import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateCodexAppServerTests: XCTestCase {
    func testCodexExecutablePathRecognizesChatGPTDesktopBundle() {
        XCTAssertTrue(AppState.isCodexExecutablePath(
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ))
    }

    func testNestedDesktopExecutableAndPersistedHookUseDesktopIdentity() {
        let path = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        XCTAssertTrue(AppState.isCodexExecutablePath(path))
        XCTAssertFalse(AppState.isCodexExecutablePath("/opt/homebrew/bin/codex"))
        XCTAssertEqual(AppState.canonicalRestoredCodexSessionId(
            sessionId: "thread", source: "codex", providerSessionId: "thread",
            termBundleId: nil, executablePath: path
        ), "codexapp:thread")
        XCTAssertEqual(AppState.canonicalRestoredCodexSessionId(
            sessionId: "thread", source: "codex", providerSessionId: "thread",
            termBundleId: nil, executablePath: "/opt/homebrew/bin/codex"
        ), "thread")
    }

    func testCodexExecutablePathRejectsUnrelatedResourceBinary() {
        XCTAssertFalse(AppState.isCodexExecutablePath(
            "/Applications/OtherAgent.app/Contents/Resources/codex"
        ))
    }

    func testCodexDiscoveryUsesTranscriptCwdForDesktopProcess() {
        XCTAssertTrue(AppState.codexDiscoveryUsesTranscriptCwd(processCwd: nil))
        XCTAssertTrue(AppState.codexDiscoveryUsesTranscriptCwd(processCwd: "/"))
        XCTAssertFalse(AppState.codexDiscoveryUsesTranscriptCwd(
            processCwd: "/Users/haoo/Documents/project"
        ))
    }

    func testCodexPlaceholderHookIsIgnoredButProjectHookIsKept() {
        XCTAssertTrue(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: "/",
            hasTranscriptPath: false
        ))
        XCTAssertTrue(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: nil,
            hasTranscriptPath: false
        ))
        XCTAssertFalse(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: "/Users/haoo/Documents/project",
            hasTranscriptPath: false
        ))
        XCTAssertFalse(AppState.isCodexPlaceholderHook(
            source: "codex",
            cwd: "/",
            hasTranscriptPath: true
        ))
    }

    func testDesktopHookRolloutAndAppServerUseOneCanonicalCard() throws {
        let appState = AppState()
        let rawId = "desktop-hook-thread"
        let sessionId = AppState.codexAppSessionPrefix + rawId
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-hook-\(UUID().uuidString).jsonl")
        try Data((#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n").utf8)
            .write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let hookPayload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": rawId,
            "_source": "codex",
            "_term_bundle": AppState.codexAppBundleId,
            "cwd": "/desktop/repo",
            "transcript_path": transcript.path,
        ]
        let hook = try XCTUnwrap(HookEvent(
            from: JSONSerialization.data(withJSONObject: hookPayload)
        ))
        XCTAssertEqual(hook.sessionId, sessionId)
        appState.handleEvent(hook)
        XCTAssertEqual(Set(appState.sessions.keys), [sessionId])
        XCTAssertEqual(appState.sessions[sessionId]?.providerSessionId, rawId)

        appState.integrateDiscovered([AppState.DiscoveredSession(
            sessionId: sessionId,
            cwd: "/desktop/repo",
            tty: nil,
            model: nil,
            pid: nil,
            modifiedAt: Date(),
            recentMessages: [],
            source: "codex",
            transcriptPath: transcript.path,
            status: .processing,
            termBundleId: AppState.codexAppBundleId,
            providerSessionId: rawId
        )])

        let started = try XCTUnwrap(CodexAppServerClient.parseMessage(Data(
            """
            {"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"\(rawId)","cwd":"/desktop/repo","path":"\(transcript.path)","status":{"type":"active","activeFlags":[]}}}}
            """.utf8
        )))
        appState.handleCodexAppServerMessage(started)

        XCTAssertEqual(Set(appState.sessions.keys), [sessionId])
        XCTAssertNil(appState.sessions[rawId])
        XCTAssertEqual(appState.sessions[sessionId]?.providerSessionId, rawId)
    }

    func testStopMigratesLegacyDesktopCardInsteadOfLeavingItRunning() throws {
        let state = AppState()
        let rawID = "legacy-desktop"
        var legacy = SessionSnapshot()
        legacy.source = "codex"
        legacy.providerSessionId = rawID
        legacy.termBundleId = AppState.codexAppBundleId
        legacy.status = .running
        legacy.currentTool = "Bash"
        legacy.lastUserPrompt = "Preserve the original prompt"
        state.sessions[rawID] = legacy
        let stop = try XCTUnwrap(HookEvent(from: Data(
            #"{"hook_event_name":"Stop","cwd":"/repo","session_id":"legacy-desktop","_source":"codex","_term_bundle":"com.openai.codex","turn_id":"turn-1"}"#.utf8)))
        state.handleEvent(stop)
        XCTAssertNil(state.sessions[rawID])
        XCTAssertEqual(state.sessions["codexapp:" + rawID]?.status, .idle)
        XCTAssertEqual(state.sessions["codexapp:" + rawID]?.lastUserPrompt, legacy.lastUserPrompt)
        XCTAssertEqual(state.activeSessionCount, 0)
        XCTAssertEqual(state.totalSessionCount, 1)
    }

    func testStopWithoutBundleMetadataClosesKnownDesktopCard() throws {
        let state = AppState()
        var session = SessionSnapshot()
        session.source = "codex"
        session.providerSessionId = "known-desktop"
        session.termBundleId = AppState.codexAppBundleId
        session.status = .running
        state.sessions["codexapp:known-desktop"] = session
        let stop = try XCTUnwrap(HookEvent(from: Data(
            #"{"hook_event_name":"Stop","cwd":"/repo","session_id":"known-desktop","_source":"codex","turn_id":"turn-1"}"#.utf8)))
        state.handleEvent(stop)
        XCTAssertNil(state.sessions["known-desktop"])
        XCTAssertEqual(state.sessions["codexapp:known-desktop"]?.status, .idle)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testExplicitTerminalHookDoesNotCloseDesktopWithSameProviderID() throws {
        let state = AppState()
        var desktop = SessionSnapshot()
        desktop.source = "codex"
        desktop.termBundleId = AppState.codexAppBundleId
        desktop.status = .running
        state.sessions["codexapp:shared-thread"] = desktop
        let stop = try XCTUnwrap(HookEvent(from: Data(
            #"{"hook_event_name":"Stop","cwd":"/repo","session_id":"shared-thread","_source":"codex","_term_bundle":"com.apple.Terminal"}"#.utf8)))
        state.handleEvent(stop)
        XCTAssertEqual(state.sessions["codexapp:shared-thread"]?.status, .running)
        XCTAssertEqual(state.sessions["shared-thread"]?.status, .idle)
    }

    func testRemoteStopCannotCloseLocalDesktopWithSameProviderID() throws {
        let state = AppState()
        var desktop = SessionSnapshot()
        desktop.source = "codex"
        desktop.termBundleId = AppState.codexAppBundleId
        desktop.status = .running
        state.sessions["codexapp:shared-thread"] = desktop
        let stop = try XCTUnwrap(HookEvent(from: Data(
            #"{"hook_event_name":"Stop","cwd":"/repo","session_id":"shared-thread","_source":"codex","_remote_host_id":"host-a"}"#.utf8)))
        state.handleEvent(stop)
        XCTAssertEqual(state.sessions["codexapp:shared-thread"]?.status, .running)
        XCTAssertEqual(state.sessions["remote:host-a:shared-thread"]?.status, .idle)
    }

    func testAppServerIdleSettlesLegacyDesktopIdentity() throws {
        let state = AppState()
        var legacy = SessionSnapshot()
        legacy.source = "codex"
        legacy.termBundleId = AppState.codexAppBundleId
        legacy.status = .running
        state.sessions["legacy-idle"] = legacy
        let idle = try XCTUnwrap(CodexAppServerClient.parseMessage(Data(
            #"{"jsonrpc":"2.0","method":"thread/status/changed","params":{"threadId":"legacy-idle","status":{"type":"idle"}}}"#.utf8)))
        state.handleCodexAppServerMessage(idle)
        XCTAssertNil(state.sessions["legacy-idle"])
        XCTAssertEqual(state.sessions["codexapp:legacy-idle"]?.status, .idle)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testCodexCLIHookKeepsRawSessionId() throws {
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "cli-thread",
            "_source": "codex",
            "_term_bundle": "com.apple.Terminal",
            "cwd": "/repo",
        ]
        let event = try XCTUnwrap(HookEvent(
            from: JSONSerialization.data(withJSONObject: payload)
        ))
        XCTAssertEqual(event.sessionId, "cli-thread")
    }

    func testAlreadyPrefixedDesktopHookKeepsRawProviderIdentifier() throws {
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "codexapp:desktop-thread",
            "_source": "codex",
            "_term_bundle": AppState.codexAppBundleId,
            "cwd": "/repo",
        ]
        let event = try XCTUnwrap(HookEvent(
            from: JSONSerialization.data(withJSONObject: payload)
        ))
        let appState = AppState()
        appState.handleEvent(event)

        XCTAssertEqual(event.sessionId, "codexapp:desktop-thread")
        XCTAssertEqual(
            appState.sessions["codexapp:desktop-thread"]?.providerSessionId,
            "desktop-thread"
        )
    }

    func testCodexTranscriptCwdReadsLargeSessionMetaLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-meta-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let payload: [String: Any] = [
            "cwd": "/Users/haoo/Documents/project",
            "instructions": String(repeating: "x", count: 10_000),
        ]
        let object: [String: Any] = ["type": "session_meta", "payload": payload]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.write(to: url)

        XCTAssertEqual(
            AppState.codexSessionCwd(path: url.path),
            "/Users/haoo/Documents/project"
        )
    }

    func testCodexAppServerExecutablePrefersRunningBundlePath() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("codeisland-codex-app-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("Nested/Codex.app", isDirectory: true)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let bundledExecutable = resourcesURL.appendingPathComponent("codex")
        try makeExecutable(at: bundledExecutable)

        let fallbackExecutable = tempDir.appendingPathComponent("fallback-codex")
        try makeExecutable(at: fallbackExecutable)

        let resolved = AppState.codexAppServerExecutableURL(
            runningBundleURLs: [bundleURL],
            fallbackPaths: [fallbackExecutable.path],
            fileManager: fm
        )

        XCTAssertEqual(resolved?.path, bundledExecutable.path)
    }

    func testCodexAppServerExecutableFallsBackWhenNoRunningBundlePathExists() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("codeisland-codex-app-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let fallbackExecutable = tempDir.appendingPathComponent("fallback-codex")
        try makeExecutable(at: fallbackExecutable)

        let resolved = AppState.codexAppServerExecutableURL(
            runningBundleURLs: [],
            fallbackPaths: [fallbackExecutable.path],
            fileManager: fm
        )

        XCTAssertEqual(resolved?.path, fallbackExecutable.path)
    }

    func testCodexAppServerExitReconnectsOnlyWhileHostAndWatcherRemainActive() {
        XCTAssertEqual(
            AppState.codexAppServerExitStrategy(hostRunning: true, watcherActive: true),
            .reconnectPreservingSessions
        )
        XCTAssertEqual(
            AppState.codexAppServerExitStrategy(hostRunning: false, watcherActive: true),
            .stopAndRemoveSessions
        )
        XCTAssertEqual(
            AppState.codexAppServerExitStrategy(hostRunning: true, watcherActive: false),
            .stopAndRemoveSessions
        )
    }

    func testAppServerDisconnectDropsDeadChannelQuestionAndResumesCard() throws {
        let appState = AppState()
        let request = try XCTUnwrap(CodexAppServerClient.parseMessage(Data(
            """
            {"jsonrpc":"2.0","id":"request-1","method":"item/tool/requestUserInput","params":{"threadId":"disconnect-thread","questions":[{"id":"q1","question":"Continue?"}]}}
            """.utf8
        )))
        appState.handleCodexAppServerMessage(request)
        let sessionId = AppState.codexAppSessionPrefix + "disconnect-thread"
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingQuestion)

        appState.invalidateCodexAppServerQuestionsAfterDisconnect()

        XCTAssertTrue(appState.questionQueue.isEmpty)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .processing)
    }

    func testThreadClosedUsesUnifiedSessionCleanup() throws {
        let appState = AppState()
        let threadId = "closed-thread"
        let sessionId = AppState.codexAppSessionPrefix + threadId
        let request = try XCTUnwrap(CodexAppServerClient.parseMessage(Data(
            """
            {"jsonrpc":"2.0","id":"request-1","method":"item/tool/requestUserInput","params":{"threadId":"\(threadId)","questions":[{"id":"q1","question":"Continue?"}]}}
            """.utf8
        )))
        appState.handleCodexAppServerMessage(request)

        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-close-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }
        appState.sessions[sessionId]?.transcriptPath = transcript.path
        appState.attachTranscriptTailerIfNeeded(sessionId: sessionId)

        XCTAssertNotNil(appState.sessions[sessionId])
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.attachedTranscriptPaths[sessionId], transcript.path)

        let closed = try XCTUnwrap(CodexAppServerClient.parseMessage(Data(
            #"{"jsonrpc":"2.0","method":"thread/closed","params":{"threadId":"closed-thread"}}"#.utf8
        )))
        appState.handleCodexAppServerMessage(closed)

        XCTAssertNil(appState.sessions[sessionId])
        XCTAssertTrue(appState.questionQueue.isEmpty)
        XCTAssertNil(appState.attachedTranscriptPaths[sessionId])

        // A result already captured by the independent DB poll must not recreate
        // the just-closed card.
        appState.integrateDiscovered([AppState.DiscoveredSession(
            sessionId: sessionId,
            cwd: "/repo",
            tty: nil,
            model: nil,
            pid: nil,
            modifiedAt: Date().addingTimeInterval(-60),
            recentMessages: [],
            source: "codex",
            transcriptPath: transcript.path,
            status: .idle,
            termBundleId: AppState.codexAppBundleId,
            providerSessionId: threadId
        )])
        XCTAssertNil(appState.sessions[sessionId])

        // A final terminal DB/file flush can be newer than the close callback;
        // idle is not evidence of a resumed generation.
        appState.integrateDiscovered([AppState.DiscoveredSession(
            sessionId: sessionId,
            cwd: "/repo",
            tty: nil,
            model: nil,
            pid: nil,
            modifiedAt: Date().addingTimeInterval(60),
            recentMessages: [],
            source: "codex",
            transcriptPath: transcript.path,
            status: .idle,
            termBundleId: AppState.codexAppBundleId,
            providerSessionId: threadId
        )])
        XCTAssertNil(appState.sessions[sessionId])

        let lateHookPayload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "session_id": threadId,
            "_source": "codex",
            "_term_bundle": AppState.codexAppBundleId,
            "cwd": "/repo",
            "transcript_path": transcript.path,
        ]
        let lateHook = try XCTUnwrap(HookEvent(
            from: JSONSerialization.data(withJSONObject: lateHookPayload)
        ))
        appState.handleEvent(lateHook)
        XCTAssertNil(appState.sessions[sessionId])

        // A real app-server start is a new generation and clears the tombstone.
        let restarted = try XCTUnwrap(CodexAppServerClient.parseMessage(Data(
            """
            {"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"\(threadId)","cwd":"/repo","path":"\(transcript.path)","status":{"type":"active","activeFlags":[]}}}}
            """.utf8
        )))
        appState.handleCodexAppServerMessage(restarted)
        XCTAssertNotNil(appState.sessions[sessionId])
    }

    func testActiveWithApprovalFlagMapsToWaitingApproval() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval")])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testActiveWithUserInputFlagMapsToWaitingQuestion() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnUserInput")])
        ])

        XCTAssertEqual(snapshot.status, .waitingQuestion)
    }

    func testActiveWithoutFlagsMapsToRunningAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .waitingApproval
        snapshot.currentTool = "Bash"
        snapshot.toolDescription = "pending"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([])
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testIdleMapsToIdleAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Read"
        snapshot.toolDescription = "foo.swift"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("idle")
        ])

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testNotLoadedAndSystemErrorMapToIdle() {
        var s1 = SessionSnapshot()
        s1.status = .running
        AppState.applyCodexThreadStatus(&s1, status: ["type": .string("notLoaded")])
        XCTAssertEqual(s1.status, .idle)

        var s2 = SessionSnapshot()
        s2.status = .running
        AppState.applyCodexThreadStatus(&s2, status: ["type": .string("systemError")])
        XCTAssertEqual(s2.status, .idle)
    }

    func testUnknownStatusTypeIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Bash"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("futureEnumCaseTBD")
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.currentTool, "Bash")
    }

    func testNilStatusIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        AppState.applyCodexThreadStatus(&snapshot, status: nil)
        XCTAssertEqual(snapshot.status, .running)
    }

    func testApprovalFlagTakesPrecedenceOverUserInputFlag() {
        // Codex can theoretically emit both flags at once; approval is strictly
        // more actionable, so we should route to .waitingApproval.
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([
                .string("waitingOnUserInput"),
                .string("waitingOnApproval")
            ])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    private func makeExecutable(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
