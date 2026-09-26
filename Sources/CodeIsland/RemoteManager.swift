import Foundation
import AppKit
import Network
import CodeIslandCore

@MainActor
final class RemoteManager: ObservableObject {
    static let shared = RemoteManager()

    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var connectionStatus: [String: SSHForwarder.Status] = [:]
    @Published private(set) var installRunning: [String: Bool] = [:]
    @Published private(set) var lastMessage: [String: String] = [:]

    var onDisconnect: ((String) -> Void)?
    var onCodexSessions: ((String, String, String, [RemoteCodexSession]) -> Void)?

    private var forwarders: [String: SSHForwarder] = [:]
    private var codexReconnectTasks: [String: Task<Void, Never>] = [:]
    private var codexClients: [String: CodexAppServerClient] = [:]
    private var codexRecords: [String: [String: RemoteCodexSession]] = [:]
    // Per-user remote socket path resolved at connect time (#193). Keyed by host id;
    // reused by installHooks so the SSH -R forward and the remote hooks agree.
    private var remoteSocketPaths: [String: String] = [:]
    private let defaults = UserDefaults.standard
    private let hostsKey = "remoteHosts"

    // Auto-reconnect (#92): when an ssh tunnel drops without the user asking for
    // it (laptop sleep / network blip / server bounce), schedule a retry with
    // exponential backoff instead of leaving the host silently disconnected.
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var reconnectAttempts: [String: Int] = [:]

    private static let reconnectBackoffSeconds: [Int] = [5, 15, 45, 120, 300]
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var manuallyDisconnected: Set<String> = []

    /// Delay (seconds) before the nth reconnect attempt (1-based). Clamped to the
    /// last entry for attempts beyond the table.
    static func reconnectDelay(attempt: Int) -> Int {
        guard attempt >= 1 else { return reconnectBackoffSeconds[0] }
        let idx = min(attempt - 1, reconnectBackoffSeconds.count - 1)
        return reconnectBackoffSeconds[idx]
    }

    private init() {
        load()
    }

    func startup() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.retryAvailableHosts() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "CodeIsland.remote-network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryAvailableHosts() }
        }
        for host in hosts where host.autoConnect {
            connect(id: host.id)
        }
    }

    private func retryAvailableHosts() {
        for host in hosts where Self.shouldRetry(
            autoConnect: host.autoConnect, manuallyDisconnected: manuallyDisconnected.contains(host.id),
            status: connectionStatus[host.id] ?? .disconnected
        ) {
            connect(id: host.id)
        }
    }

    static func shouldRetry(autoConnect: Bool, manuallyDisconnected: Bool, status: SSHForwarder.Status) -> Bool {
        autoConnect && !manuallyDisconnected && status != .connected && status != .connecting
    }

    func shutdown() {
        pathMonitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        for host in hosts {
            disconnect(id: host.id)
        }
    }

    func addHost(_ host: RemoteHost) {
        hosts.append(host)
        save()
    }

    func updateHost(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let previous = hosts[index]
        let wasConnected = (connectionStatus[host.id] == .connected)
        hosts[index] = host
        save()
        // Only bounce the tunnel when a field the SSH connection depends on
        // changed. Local-only fields (name, cwdFilter — filtering happens in
        // HookServer, #240) must not interrupt live sessions.
        let connectionChanged = previous.host != host.host
            || previous.user != host.user
            || previous.port != host.port
            || previous.identityFile != host.identityFile
            || previous.authSocket != host.authSocket
        if wasConnected && connectionChanged {
            reconnect(id: host.id)
        }
    }

    func removeHost(id: String) {
        disconnect(id: id)
        hosts.removeAll { $0.id == id }
        connectionStatus[id] = .disconnected
        installRunning[id] = false
        lastMessage[id] = nil
        save()
    }

    func reconnect(id: String) {
        disconnect(id: id)
        connect(id: id)
    }

    func connect(id: String) {
        manuallyDisconnected.remove(id)
        guard connectionStatus[id] != .connecting else { return }
        // User-initiated connect (or autoConnect at startup): clear any pending
        // reconnect countdown and reset the backoff attempt counter.
        cancelScheduledReconnect(id: id)
        reconnectAttempts[id] = nil
        connectInternal(id: id)
    }

    private func connectInternal(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        guard !host.sshTarget.isEmpty else {
            connectionStatus[id] = .failed("invalid host")
            lastMessage[id] = "invalid host"
            return
        }

        let forwarder = forwarders[id] ?? SSHForwarder()
        forwarders[id] = forwarder
        forwarder.onStatusChange = { [weak self, weak forwarder] status in
            Task { @MainActor in
                guard let self, self.forwarders[host.id] === forwarder else { return }
                self.handleStatusChange(status, for: host)
            }
        }

        connectionStatus[id] = .connecting
        lastMessage[id] = host.displayAddress

        Task {
            let remoteSocketPath = await RemoteInstaller.prepareRemoteSocketPath(host: host)
            await MainActor.run {
                guard self.forwarders[host.id] === forwarder else { return }
                guard let remoteSocketPath else {
                    self.handleStatusChange(.failed("remote UID probe failed"), for: host)
                    return
                }
                self.remoteSocketPaths[host.id] = remoteSocketPath
                forwarder.connect(host: host, localSocketPath: HookServer.socketPath, remoteSocketPath: remoteSocketPath)
            }
        }
    }

    func disconnect(id: String) {
        manuallyDisconnected.insert(id)
        stopCodexEvents(hostId: id)
        forwarders[id]?.onStatusChange = nil
        cancelScheduledReconnect(id: id)
        reconnectAttempts[id] = nil
        forwarders[id]?.disconnect()
        forwarders[id] = nil
        remoteSocketPaths[id] = nil
        connectionStatus[id] = .disconnected
        installRunning[id] = false
        onDisconnect?(id)
    }

    private func stopCodexEvents(hostId: String) {
        codexReconnectTasks.removeValue(forKey: hostId)?.cancel()
        let client = codexClients.removeValue(forKey: hostId)
        client?.onExit = nil
        client?.stop()
        codexRecords[hostId] = nil
    }

    private func startCodexEvents(host: RemoteHost) {
        stopCodexEvents(hostId: host.id)
        guard let url = Bundle.appModule.url(forResource: "codex-event-transport", withExtension: "py", subdirectory: "Resources"),
              let script = try? Data(contentsOf: url) else { return }
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(script.base64EncodedString())\"))'"
        let client = CodexAppServerClient(executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: RemoteInstaller.sshArguments(host: host) + [command])
        codexClients[host.id] = client
        client.onMessage = { [weak self, weak client] message in
            Task { @MainActor in
                guard let self, let client, self.codexClients[host.id] === client else { return }
                self.handleCodexEventMessage(message, host: host, client: client)
            }
        }
        client.onExit = { [weak self, weak client] _ in
            Task { @MainActor in
                guard let self, let client, self.codexClients[host.id] === client else { return }
                self.codexClients[host.id] = nil
                self.lastMessage[host.id] = "Codex event stream disconnected; reconnecting"
                self.onCodexSessions?(host.id, host.name, host.cwdFilter, [])
                self.codexReconnectTasks[host.id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self, self.connectionStatus[host.id] == .connected else { return }
                    self.startCodexEvents(host: host)
                }
            }
        }
        do {
            try client.start()
            try client.initializeHandshake(clientName: "CodeIsland", clientVersion: "1")
        } catch {
            lastMessage[host.id] = "Codex event connection failed: \(error.localizedDescription)"
            stopCodexEvents(hostId: host.id)
        }
    }

    private func handleCodexEventMessage(_ message: CodexJSONRPCMessage, host: RemoteHost, client: CodexAppServerClient) {
        let result = message.raw["result"]?.asObject ?? [:]
        let params = message.raw["params"]?.asObject ?? [:]
        do {
            if case .response(id: .int(1)) = message.kind {
                try client.sendNotification(method: "initialized")
                try client.sendRequest(method: "thread/loaded/list", params: [:])
            } else if case .array(let ids)? = result["data"] {
                for id in ids.compactMap(\.asString) {
                    try client.sendRequest(method: "thread/read", params: ["threadId": id, "includeTurns": false])
                }
                if let cursor = result["nextCursor"]?.asString {
                    try client.sendRequest(method: "thread/loaded/list", params: ["cursor": cursor])
                }
            }
            if let thread = result["thread"]?.asObject ?? params["thread"]?.asObject {
                updateRemoteCodexThread(thread, host: host)
            } else if case .notification(let method) = message.kind,
                      ["thread/status/changed", "thread/closed", "thread/archived"].contains(method),
                      let id = params["threadId"]?.asString {
                // Read the current authoritative snapshot after each notification.
                // Concurrent responses can never replay an older notification status.
                if method == "thread/status/changed" {
                    try client.sendRequest(method: "thread/read", params: ["threadId": id, "includeTurns": false])
                } else {
                    codexRecords[host.id]?[id] = nil
                    onCodexSessions?(host.id, host.name, host.cwdFilter, Array((codexRecords[host.id] ?? [:]).values))
                }
            }
        } catch {
            lastMessage[host.id] = "Codex event request failed: \(error.localizedDescription)"
        }
    }

    private func updateRemoteCodexThread(_ thread: [String: AnyCodableLike], host: RemoteHost) {
        guard let id = thread["id"]?.asString, let cwd = thread["cwd"]?.asString else { return }
        // Child agents are represented by their parent task, not extra sidebar tasks.
        guard thread["source"]?.asObject == nil else { return }
        let active = thread["status"]?.asObject?["type"]?.asString == "active"
        let now = Date().timeIntervalSince1970
        codexRecords[host.id, default: [:]][id] = RemoteCodexSession(
            id: id, cwd: cwd, model: nil, title: thread["name"]?.asString ?? thread["preview"]?.asString,
            modifiedAt: now, startedAt: now, isActive: active)
        onCodexSessions?(host.id, host.name, host.cwdFilter, Array((codexRecords[host.id] ?? [:]).values))
    }

    private func handleStatusChange(_ status: SSHForwarder.Status, for host: RemoteHost) {
        connectionStatus[host.id] = status

        switch status {
        case .connected:
            // Tunnel is up again — forget previous failure counter.
            reconnectAttempts[host.id] = nil
            cancelScheduledReconnect(id: host.id)
            Task { await installHooks(for: host) }
            startCodexEvents(host: host)
        case .failed(let message):
            stopCodexEvents(hostId: host.id)
            installRunning[host.id] = false
            lastMessage[host.id] = message
            onDisconnect?(host.id)
            scheduleReconnect(for: host)
        case .disconnected:
            stopCodexEvents(hostId: host.id)
            // User-initiated disconnects go through disconnect(id:) which already
            // cleared reconnect state before we get here.
            installRunning[host.id] = false
            onDisconnect?(host.id)
        case .connecting:
            break
        }
    }

    private func scheduleReconnect(for host: RemoteHost) {
        // Only auto-reconnect hosts the user opted into; otherwise a failing
        // manually-triggered connect would keep retrying forever.
        guard host.autoConnect, !manuallyDisconnected.contains(host.id) else { return }

        cancelScheduledReconnect(id: host.id)
        let nextAttempt = (reconnectAttempts[host.id] ?? 0) + 1
        reconnectAttempts[host.id] = nextAttempt
        let delay = Self.reconnectDelay(attempt: nextAttempt)
        lastMessage[host.id] = "Reconnecting in \(delay)s (attempt \(nextAttempt))"

        let hostId = host.id
        reconnectTasks[hostId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Task may have been cancelled after the sleep; double-check.
                guard self.reconnectTasks[hostId] != nil else { return }
                self.reconnectTasks[hostId] = nil
                self.connectInternal(id: hostId)
            }
        }
    }

    private func cancelScheduledReconnect(id: String) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
    }

    private func installHooks(for host: RemoteHost) async {
        installRunning[host.id] = true
        let remoteSocketPath = remoteSocketPaths[host.id] ?? host.remoteSocketPath
        let result = await RemoteInstaller.installAll(host: host, remoteSocketPath: remoteSocketPath)
        installRunning[host.id] = false
        lastMessage[host.id] = result.message
        if !result.ok {
            connectionStatus[host.id] = .failed(result.message)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: hostsKey),
              let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) else {
            hosts = []
            return
        }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: hostsKey)
    }
}
