import Foundation
import Network
import os.log
import CodeIslandCore

/// Subscribe to the running desktop's live state. No transcript inference.
/// Local hooks provide discovery; IPC snapshots recover silent/failed turns.
@MainActor
final class CodexFailureWatcher {
    struct Turn {
        var status = ""
        var started: Double = 0
        var duration: Double = -1
        init(_ raw: [String: Any]) {
            status = raw["status"] as? String ?? ""
            started = (raw["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0
            duration = (raw["durationMs"] as? NSNumber)?.doubleValue ?? -1
        }
        var ended: Date? {
            guard ["failed", "interrupted"].contains(status), started > 0, duration >= 0 else { return nil }
            return Date(timeIntervalSince1970: (started + duration) / 1000)
        }
    }
    private let log = Logger(subsystem: "com.codeisland", category: "CodexFailureWatcher")
    private weak var state: AppState?
    private var connection: NWConnection?
    private var clientId: String?
    private var buffer = Data()
    private var timer: Timer?
    private var subscriptions: [String: (host: String, thread: String)] = [:]
    private var turns: [String: [String: Turn]] = [:]

    init(state: AppState) { self.state = state }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        sync()
    }
    private func sync() {
        guard let state else { return }
        if connection == nil {
            let path = NSHomeDirectory() + "/.codex/ipc/ipc.sock"
            guard FileManager.default.fileExists(atPath: path) else { return }
            let c = NWConnection(to: .unix(path: path), using: .tcp)
            connection = c
            c.stateUpdateHandler = { [weak self, weak c] status in
                Task { @MainActor in
                    guard let self, let c, self.connection === c else { return }
                    switch status {
                    case .ready:
                        self.send(["type": "request", "requestId": UUID().uuidString, "sourceClientId": "codeisland-failure", "version": 0, "method": "initialize", "params": ["clientType": "codeisland-failure"]])
                        self.receive(c)
                    case .failed, .cancelled: self.reset()
                    default: break
                    }
                }
            }
            c.start(queue: .main)
        }
        guard clientId != nil else { return }
        let wanted = state.sessions.filter { _, s in
            s.source == "codex" && (s.termBundleId == AppState.codexAppBundleId
                || s.remoteHostId?.hasPrefix("remote-ssh-codex-managed:") == true)
        }
        for id in Array(subscriptions.keys) where wanted[id] == nil {
            follow(id, false)
            subscriptions[id] = nil
            turns[id] = nil
        }
        for (id, s) in wanted where subscriptions[id] == nil {
            guard let thread = s.providerSessionId else { continue }
            observe(sessionId: id, host: s.remoteHostId ?? "local", thread: thread)
        }
    }
    func observe(sessionId: String, host: String, thread: String) {
        subscriptions[sessionId] = (host, thread)
        follow(sessionId, true)
    }

    private func follow(_ id: String, _ following: Bool) {
        guard let clientId, let sub = subscriptions[id] else { return }
        send(["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": clientId, "version": 1,
              "params": ["conversationId": sub.thread, "hostId": sub.host, "following": following]])
    }
    private func reset() {
        let old = connection
        connection = nil
        old?.cancel()
        clientId = nil
        buffer.removeAll()
        subscriptions.removeAll()
        turns.removeAll()
    }
    private func send(_ value: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return }
        var length = UInt32(bytes.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(bytes)
        connection?.send(content: frame, completion: .contentProcessed { _ in })
    }
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, error in
            Task { @MainActor in
                guard let self, let c, self.connection === c else { return }
                if let data { self.buffer.append(data) }
                do {
                    while let frame = try Self.takeFrame(from: &self.buffer) {
                        if let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] { self.accept(value) }
                    }
                } catch { self.reset(); return }
                if done || error != nil { self.reset() } else { self.receive(c) }
            }
        }
    }
    static func takeFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let count = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard count <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        guard buffer.count >= count + 4 else { return nil }
        let start = buffer.startIndex
        let frame = buffer.subdata(in: (start + 4)..<(start + count + 4))
        buffer = buffer.subdata(in: (start + count + 4)..<buffer.endIndex)
        return frame
    }

    func accept(_ value: [String: Any]) {
        if value["method"] as? String == "initialize", let result = value["result"] as? [String: Any] {
            clientId = result["clientId"] as? String
            sync()
        }
        if value["type"] as? String == "client-discovery-request", let id = value["requestId"] {
            send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
        }
        guard value["method"] as? String == "thread-stream-state-changed",
              let p = value["params"] as? [String: Any],
              let id = subscriptions.first(where: { $0.value.host == p["hostId"] as? String && $0.value.thread == p["conversationId"] as? String })?.key,
              let change = p["change"] as? [String: Any] else { return }
        if subscriptions[id]?.host == "local" {
            if let snapshot = change["conversationState"] as? [String: Any],
               let runtime = snapshot["threadRuntimeStatus"] as? [String: Any] {
                state?.applyCodexRuntimeSnapshot(sessionId: id, runtime: runtime)
            }
            for patch in change["patches"] as? [[String: Any]] ?? [] {
                if patch["path"] as? [String] == ["threadRuntimeStatus"],
                   let runtime = patch["value"] as? [String: Any] {
                    state?.applyCodexRuntimeSnapshot(sessionId: id, runtime: runtime)
                }
            }
        }
        if let snapshot = change["conversationState"] as? [String: Any],
           let history = snapshot["turnHistory"] as? [String: Any],
           let items = history["history"] as? [String: Any], let entities = items["entitiesByKey"] as? [String: [String: Any]] {
            turns[id] = entities.mapValues(Turn.init)
            log.notice("failure_watch snapshot session=\(id, privacy: .public) turns=\(entities.count)")
        }
        for patch in change["patches"] as? [[String: Any]] ?? [] {
            guard let path = patch["path"] as? [String], path.count >= 4,
                  Array(path.prefix(3)) == ["turnHistory", "history", "entitiesByKey"] else { continue }
            let key = path[3]
            if path.count == 4 {
                if patch["op"] as? String == "remove" { turns[id]?[key] = nil }
                else if let raw = patch["value"] as? [String: Any] { turns[id, default: [:]][key] = Turn(raw) }
            } else if path.count == 5 {
                var turn = turns[id]?[key] ?? Turn([:])
                switch path[4] {
                case "status": turn.status = patch["value"] as? String ?? ""
                case "turnStartedAtMs": turn.started = (patch["value"] as? NSNumber)?.doubleValue ?? 0
                case "durationMs": turn.duration = (patch["value"] as? NSNumber)?.doubleValue ?? -1
                default: break
                }
                turns[id, default: [:]][key] = turn
            }
        }
        guard let latest = turns[id]?.values.max(by: { $0.started < $1.started }), let ended = latest.ended else { return }
        state?.reconcileCodexFailure(sessionId: id, ended: ended)
    }
}

extension AppState {
    func applyCodexRuntimeSnapshot(sessionId: String, runtime: [String: Any]) {
        guard var session = sessions[sessionId], session.source == "codex",
              let status = AnyCodableLike.from(runtime).asObject else { return }
        Self.applyCodexThreadStatus(&session, status: status)
        sessions[sessionId] = session
        refreshDerivedState()
    }

    func reconcileCodexFailure(sessionId: String, ended: Date) {
        guard let session = sessions[sessionId], session.source == "codex",
              session.status == .running || session.status == .processing,
              session.lastActivity <= ended else { return }
        sessions[sessionId]?.status = .idle
        sessions[sessionId]?.interrupted = true
        sessions[sessionId]?.lastActivity = ended
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        refreshDerivedState()
    }
}
