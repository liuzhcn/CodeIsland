import XCTest
import CodeIslandCore
@testable import CodeIsland

/// Drives a private `RemoteManager` with stand-ins for ssh: no process is
/// started and no host is contacted. The reconnect rules themselves are
/// covered by `RemoteReconnectPolicyTests`; these check the wiring — the
/// socket-path probe awaited before ssh starts, the debounced recovery pass,
/// and late reports from a tunnel that was already replaced.
@MainActor
final class RemoteManagerTests: XCTestCase {
    private let suiteName = "RemoteManagerTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRemoteCodexScanAddsAndRetainsEndedSession() {
        let state = AppState()
        let session = RemoteCodexSession(
            id: "remote-codex-test", cwd: "/home/leo/projects/hr", model: "gpt-6-astra",
            title: "Investigate hr", modifiedAt: Date().timeIntervalSince1970,
            startedAt: Date().timeIntervalSince1970
        )
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.remoteHostId, "remote-test")

        state.reconcileRemoteCodexSessions([], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.status, .idle)
        XCTAssertEqual(state.totalSessionCount, 1)
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testRemoteCodexTitleRecoversAfterAttachmentMetadata() {
        let state = AppState()
        let now = Date().timeIntervalSince1970
        let session = RemoteCodexSession(
            id: "remote-title-test", cwd: "/home/leo/projects/hr", model: nil,
            title: "# Files mentioned by the user:\nimage.png", modifiedAt: now, startedAt: now
        )
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertNil(state.sessions["remote:remote-test:\(session.id)"]?.sessionLabel)

        let renamed = RemoteCodexSession(
            id: session.id, cwd: session.cwd, model: nil,
            title: "评估前端兼容方案", modifiedAt: now + 1, startedAt: now
        )
        state.reconcileRemoteCodexSessions([renamed], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.sessionLabel, "评估前端兼容方案")
    }

    func testFailedRemoteTurnIsNotRevivedByScan() {
        let state = AppState()
        let started = Date().timeIntervalSince1970 - 10
        let session = RemoteCodexSession(
            id: "failed-remote", cwd: "/home/leo/projects/hr", model: nil,
            title: nil, modifiedAt: started + 5, startedAt: started
        )
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        state.reconcileCodexFailure(sessionId: "remote:remote-test:\(session.id)", ended: Date(timeIntervalSince1970: started + 6))
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.status, .idle)
        XCTAssertEqual(state.activeSessionCount, 0)

        let nextTurn = RemoteCodexSession(
            id: session.id, cwd: session.cwd, model: nil, title: nil,
            modifiedAt: started + 9, startedAt: started + 8
        )
        state.reconcileRemoteCodexSessions([nextTurn], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.status, .running)
        XCTAssertEqual(state.activeSessionCount, 1)
    }

    func testRemoteScanAndHooksShareOneRunningCardInEitherOrder() throws {
        for hookFirst in [false, true] {
            let state = AppState()
            let now = Date().timeIntervalSince1970
            let record = RemoteCodexSession(
                id: "same-thread", cwd: "/remote/project", model: nil,
                title: "Remote task", modifiedAt: now, startedAt: now
            )
            func hook(_ name: String) throws -> HookEvent {
                let data = try JSONSerialization.data(withJSONObject: [
                    "hook_event_name": name, "session_id": record.id,
                    "_source": "codex", "_remote_host_id": "remote-test",
                    "cwd": record.cwd
                ])
                return try XCTUnwrap(HookEvent(from: data))
            }
            if hookFirst { state.handleEvent(try hook("UserPromptSubmit")) }
            state.reconcileRemoteCodexSessions([record], hostId: "remote-test", hostName: "server", cwdFilter: "")
            if !hookFirst { state.handleEvent(try hook("UserPromptSubmit")) }
            XCTAssertEqual(state.sessions.count, 1)
            XCTAssertEqual(state.activeSessionCount, 1)
            XCTAssertEqual(state.sessions["remote:remote-test:same-thread"]?.providerSessionId, record.id)
            // A missed Stop hook must still be reconciled by the next scan.
            state.reconcileRemoteCodexSessions([], hostId: "remote-test", hostName: "server", cwdFilter: "")
            XCTAssertEqual(state.activeSessionCount, 0)
        }
    }

    func testRemoteScanSettlesHookOnlyCardWithoutStop() throws {
        let state = AppState()
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "ended-thread",
            "_source": "codex", "_remote_host_id": "remote-test",
            "cwd": "/remote/project"
        ])
        state.handleEvent(try XCTUnwrap(HookEvent(from: data)))
        XCTAssertEqual(state.activeSessionCount, 1)
        // An unknown hook may be a CLI task, so an empty desktop scan keeps it.
        state.reconcileRemoteCodexSessions([], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 1)
        let cliData = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "cli-thread",
            "_source": "codex", "_remote_host_id": "remote-test",
            "cwd": "/remote/project"
        ])
        state.handleEvent(try XCTUnwrap(HookEvent(from: cliData)))
        let ended = RemoteCodexSession(id: "ended-thread", cwd: "/remote/project", model: nil,
                                       title: nil, modifiedAt: Date().timeIntervalSince1970,
                                       startedAt: 0, isActive: false)
        state.reconcileRemoteCodexSessions([ended], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.sessions["remote:remote-test:ended-thread"]?.status, .idle)
        XCTAssertNotNil(state.sessions["remote:remote-test:cli-thread"])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Stands in for `SSHForwarder`: counts connects and reports whatever the
    /// test tells it to.
    @MainActor
    private final class FakeTunnel: RemoteTunnel {
        var onStatusChange: ((SSHForwarder.Status) -> Void)?
        private(set) var connects = 0

        func connect(host: RemoteHost, localSocketPath: String, remoteSocketPath: String) {
            connects += 1
            onStatusChange?(.connecting)
        }

        func disconnect() {
            onStatusChange?(.disconnected)
        }

        func report(_ status: SSHForwarder.Status) {
            onStatusChange?(status)
        }
    }

    @MainActor
    private final class Tunnels {
        private(set) var made: [FakeTunnel] = []
        var connects: Int { made.reduce(0) { $0 + $1.connects } }

        func make() -> any RemoteTunnel {
            let tunnel = FakeTunnel()
            made.append(tunnel)
            return tunnel
        }
    }

    /// The remote socket-path probe that runs before ssh starts. While
    /// `holding`, each probe waits for `release()`.
    @MainActor
    private final class ProbeGate {
        var holding = false
        private(set) var started = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        func probe() async -> String {
            started += 1
            if holding {
                await withCheckedContinuation { held.append($0) }
            }
            return "/tmp/codeisland-501.sock"
        }

        func release() {
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }
    }

    private func makeManager(
        _ configure: (inout RemoteReconnectPolicy.Config) -> Void = { _ in }
    ) -> (RemoteManager, ProbeGate, Tunnels) {
        var config = RemoteReconnectPolicy.Config()
        config.wakeSettle = 0
        config.networkSettle = 0
        configure(&config)
        let gate = ProbeGate()
        let tunnels = Tunnels()
        let manager = RemoteManager(
            defaults: defaults,
            reconnectPolicy: RemoteReconnectPolicy(config: config),
            makeTunnel: { tunnels.make() },
            probeSocketPath: { _ in await gate.probe() },
            installRemoteHooks: { _, _ in RemoteInstallResult(ok: true, message: "installed") }
        )
        return (manager, gate, tunnels)
    }

    private func addHost(to manager: RemoteManager, autoConnect: Bool = true) -> RemoteHost {
        let host = RemoteHost(name: "devbox", host: "devbox.invalid", user: "me", autoConnect: autoConnect)
        manager.addHost(host)
        return host
    }

    /// Connects `host` and waits until its tunnel has started.
    private func connect(_ host: RemoteHost, on manager: RemoteManager, tunnels: Tunnels) async {
        let before = tunnels.connects
        manager.connect(id: host.id)
        await waitUntil("the tunnel never started") { tunnels.connects == before + 1 }
    }

    /// Lets queued main-actor work (status reports, a zero-delay recovery
    /// pass, a released probe) run, for asserting that something did not
    /// happen.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Probe re-entrancy

    /// Disconnect while the socket-path probe is still running: once the
    /// probe returns, ssh must not start — nothing could stop that tunnel.
    func testDisconnectDuringTheProbeNeverStartsSSH() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        gate.holding = true

        manager.connect(id: host.id)
        await waitUntil { gate.started == 1 }
        manager.disconnect(id: host.id)
        gate.release()
        await settle()

        XCTAssertEqual(tunnels.connects, 0)
        XCTAssertEqual(manager.connectionStatus[host.id], .disconnected)
        XCTAssertFalse(manager.wantsConnection(id: host.id))
    }

    /// Two connects overlapping across the probe: only the newer starts ssh.
    func testOnlyTheNewerOfTwoOverlappingConnectsStartsSSH() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        gate.holding = true

        manager.connect(id: host.id)
        manager.connect(id: host.id)
        await waitUntil { gate.started == 2 }
        gate.release()
        await waitUntil { tunnels.connects == 1 }
        await settle()

        XCTAssertEqual(tunnels.connects, 1)
        XCTAssertEqual(tunnels.made.count, 1)
    }

    // MARK: - Wake and network (#375)

    /// The lid case: the host is down with a retry pending when the wake, a
    /// network flap and the displays waking arrive together. That makes one
    /// connect, and more of the same while it is still probing make none.
    func testWakeAndNetworkBurstReconnectsOnce() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        manager.networkPathChanged(satisfied: true)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }

        gate.holding = true
        manager.systemDidWake()
        manager.networkPathChanged(satisfied: false)
        manager.networkPathChanged(satisfied: true)
        manager.systemDidWake()
        await waitUntil { gate.started == 2 }

        manager.systemDidWake()
        manager.networkPathChanged(satisfied: false)
        manager.networkPathChanged(satisfied: true)
        await settle()
        XCTAssertEqual(gate.started, 2, "a connect still probing is not started again")

        gate.release()
        await waitUntil { tunnels.connects == 2 }
        await settle()
        XCTAssertEqual(tunnels.connects, 2)
        XCTAssertEqual(tunnels.made.count, 1, "the host keeps its one tunnel")
    }

    /// Every fast retry failed while the lid was closed; waking brings the
    /// host back instead of leaving it on the slow schedule.
    func testWakeReconnectsAHostPastItsFastRetries() async {
        let (manager, _, tunnels) = makeManager { $0.fastAttempts = 0 }
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }
        XCTAssertEqual(
            manager.lastMessage[host.id],
            String(format: L10n.shared["remote_retry_slow"], 1, 15)
        )

        manager.systemDidWake()
        await waitUntil { tunnels.connects == 2 }
        tunnels.made[0].report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }
    }

    /// Offline at wake: nothing is tried until the path is back.
    func testOfflineAtWakeConnectsWhenTheNetworkReturns() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        manager.networkPathChanged(satisfied: true)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }

        manager.networkPathChanged(satisfied: false)
        manager.systemDidWake()
        await waitUntil { manager.reconnectPhase(id: host.id) == .waitingForNetwork }
        XCTAssertEqual(manager.lastMessage[host.id], L10n.shared["remote_waiting_network"])
        XCTAssertEqual(gate.started, 1)

        manager.networkPathChanged(satisfied: true)
        await waitUntil { tunnels.connects == 2 }
        XCTAssertEqual(gate.started, 2)
    }

    /// Disconnect is the user's call: no wake or network event undoes it.
    func testUserDisconnectSurvivesWakeAndNetworkReturning() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        manager.networkPathChanged(satisfied: true)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }

        manager.disconnect(id: host.id)
        manager.systemDidWake()
        manager.networkPathChanged(satisfied: false)
        manager.networkPathChanged(satisfied: true)
        await settle()

        XCTAssertEqual(gate.started, 1)
        XCTAssertEqual(tunnels.connects, 1)
        XCTAssertEqual(manager.connectionStatus[host.id], .disconnected)
        XCTAssertFalse(manager.wantsConnection(id: host.id))
    }

    /// A host connected by hand (Auto-connect off) is restored after a wake,
    /// though its failure alone schedules no retry.
    func testManualHostIsRestoredOnWake() async {
        let (manager, _, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager, autoConnect: false)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.connectionStatus[host.id] == .failed("ssh exited (255)") }
        XCTAssertEqual(manager.reconnectPhase(id: host.id), .idle)
        XCTAssertTrue(manager.wantsConnection(id: host.id))

        manager.systemDidWake()
        await waitUntil { tunnels.connects == 2 }
    }

    // MARK: - Stale reports

    /// Reinstall swaps the tunnel; a late failure from the old one must not
    /// mark the host failed or schedule a retry.
    func testLateReportFromAReplacedTunnelIsIgnored() async {
        let (manager, _, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        let old = tunnels.made[0]
        old.report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }

        manager.reconnect(id: host.id)
        await waitUntil { tunnels.made.count == 2 && tunnels.made[1].connects == 1 }
        old.report(.failed("late"))
        await settle()

        XCTAssertNotEqual(manager.connectionStatus[host.id], .failed("late"))
        XCTAssertEqual(manager.reconnectPhase(id: host.id), .connecting)
    }
}
