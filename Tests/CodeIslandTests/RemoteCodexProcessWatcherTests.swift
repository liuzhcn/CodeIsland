import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class RemoteCodexProcessWatcherTests: XCTestCase {
    private let host = RemoteHost(id: "remote-test", name: "server", host: "unused.invalid")
    private let sessionID = "remote:remote-test:cli-thread"
    private let path = "/home/me/.codex/sessions/rollout-cli-thread.jsonl"
    private let checkTime = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeState() throws -> AppState {
        let state = AppState()
        let hook = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "cli-thread",
            "_source": "codex", "_remote_host_id": host.id,
            "cwd": "/remote/project", "transcript_path": path,
        ])))
        state.handleEvent(hook)
        state.sessions[sessionID]?.lastActivity = checkTime.addingTimeInterval(-121)
        return state
    }

    private func watcher(_ state: AppState, now: (() -> Date)? = nil,
                         probe: @escaping (RemoteHost, [String]) async -> Set<String>?) -> RemoteCodexProcessWatcher {
        let watcher = RemoteCodexProcessWatcher(now: now ?? { self.checkTime }, probe: probe)
        watcher.candidates = { state.remoteCodexProcessCandidates(hostID: $0) }
        watcher.onEnded = { state.settleExitedRemoteCodexProcess($0) }
        return watcher
    }

    func testExitedCLIWithoutStopSettlesAfterTwoProcessChecksAndKeepsRecentCard() async throws {
        let state = try makeState()
        let watcher = watcher(state) { _, paths in
            XCTAssertEqual(paths, [self.path])
            return []
        }
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 1, "One missing observation is not enough")
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 0, "An exited CLI must not think forever awaiting archive")
        XCTAssertEqual(state.sessions[sessionID]?.status, .idle)
        XCTAssertEqual(state.totalSessionCount, 1)
    }

    func testLiveButSilentCLIStaysActive() async throws {
        let state = try makeState()
        state.sessions[sessionID]?.lastActivity = checkTime.addingTimeInterval(-21 * 3600)
        let watcher = watcher(state) { _, paths in Set(paths) }
        await watcher.check(host: host)
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 1)
    }

    func testFailedProbeBreaksConsecutiveMissingObservations() async throws {
        let state = try makeState()
        var result: Set<String>? = []
        let watcher = watcher(state) { _, _ in result }
        await watcher.check(host: host)
        result = nil
        await watcher.check(host: host)
        result = []
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 1)
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testLateProbeCannotSettleNewerHookActivity() async throws {
        let state = try makeState()
        var updateDuringProbe = false
        let watcher = watcher(state) { _, _ in
            if updateDuringProbe { state.sessions[self.sessionID]?.lastActivity.addTimeInterval(1) }
            return []
        }
        await watcher.check(host: host)
        updateDuringProbe = true
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 1)
    }

    func testNewTurnRequiresItsOwnTwoMissingObservations() async throws {
        let state = try makeState()
        let watcher = watcher(state) { _, _ in [] }
        await watcher.check(host: host)
        state.sessions[sessionID]?.lastActivity.addTimeInterval(1)
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 1)
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testLiveObservationAndDisconnectResetMissingHistory() async throws {
        let state = try makeState()
        var live: Set<String> = []
        let watcher = watcher(state) { _, _ in live }
        await watcher.check(host: host)
        live = [path]
        await watcher.check(host: host)
        live = []
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 1)
        watcher.stop(hostID: host.id)
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 1)
        await watcher.check(host: host)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testCancelledProbeCannotSettleACard() async throws {
        let state = try makeState()
        var hold = false
        var continuation: CheckedContinuation<Set<String>?, Never>?
        let watcher = watcher(state) { _, _ in
            if hold { return await withCheckedContinuation { continuation = $0 } }
            return []
        }
        await watcher.check(host: host)
        hold = true
        let pending = Task { await watcher.check(host: host) }
        while continuation == nil { await Task.yield() }
        pending.cancel()
        continuation?.resume(returning: [])
        await pending.value
        XCTAssertEqual(state.activeSessionCount, 1)
    }

    func testCandidatesExcludeOtherHostsProvidersIdleAndMissingPaths() throws {
        let state = try makeState()
        var other = try XCTUnwrap(state.sessions[sessionID])
        other.remoteHostId = "other-host"
        state.sessions["other-host"] = other
        other.remoteHostId = host.id
        other.source = "claude"
        state.sessions["claude"] = other
        other.source = "codex"
        other.status = .idle
        state.sessions["idle"] = other
        other.status = .processing
        other.transcriptPath = nil
        state.sessions["no-path"] = other
        XCTAssertEqual(state.remoteCodexProcessCandidates(hostID: host.id).map(\.sessionID), [sessionID])
    }

    func testRecentActivityDoesNotLaunchAnSSHProbe() async throws {
        let state = try makeState()
        state.sessions[sessionID]?.lastActivity = checkTime.addingTimeInterval(-119)
        var probes = 0
        let watcher = watcher(state) { _, _ in
            probes += 1
            return []
        }
        await watcher.check(host: host)
        await watcher.check(host: host)
        XCTAssertEqual(probes, 0, "Recently active cards must be handled by hooks without SSH polling")
        XCTAssertEqual(state.activeSessionCount, 1)
    }

    func testTwoMinutesOfSilenceEnablesTwoMissingProcessChecks() async throws {
        let state = try makeState()
        state.sessions[sessionID]?.lastActivity = checkTime
        var time = checkTime.addingTimeInterval(119)
        var probes = 0
        let watcher = watcher(state, now: { time }) { _, _ in
            probes += 1
            return []
        }
        await watcher.check(host: host)
        XCTAssertEqual(probes, 0)
        time = checkTime.addingTimeInterval(120)
        await watcher.check(host: host)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(state.activeSessionCount, 1)
        time = checkTime.addingTimeInterval(180)
        await watcher.check(host: host)
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testNewHookRestartsTheSilenceWindowAndMissingHistory() async throws {
        let state = try makeState()
        var time = checkTime
        var probes = 0
        let watcher = watcher(state, now: { time }) { _, _ in
            probes += 1
            return []
        }
        await watcher.check(host: host)
        XCTAssertEqual(probes, 1)
        state.sessions[sessionID]?.lastActivity = time
        time.addTimeInterval(60)
        await watcher.check(host: host)
        XCTAssertEqual(probes, 1, "A fresh hook must suspend remote checks")
        time.addTimeInterval(60)
        await watcher.check(host: host)
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(state.activeSessionCount, 1, "The old missing observation must not carry into a new silence window")
        time.addTimeInterval(60)
        await watcher.check(host: host)
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testHostProbeOnlyIncludesSilentCards() async throws {
        let state = try makeState()
        var recent = try XCTUnwrap(state.sessions[sessionID])
        recent.providerSessionId = "recent"
        recent.lastActivity = checkTime
        recent.transcriptPath = "/home/me/.codex/sessions/recent.jsonl"
        state.sessions["remote:remote-test:recent"] = recent
        let watcher = watcher(state) { _, paths in
            XCTAssertEqual(paths, [self.path])
            return Set(paths)
        }
        await watcher.check(host: host)
        XCTAssertEqual(state.sessions[sessionID]?.status, .processing)
        XCTAssertEqual(state.sessions["remote:remote-test:recent"]?.status, .processing)
    }
}
