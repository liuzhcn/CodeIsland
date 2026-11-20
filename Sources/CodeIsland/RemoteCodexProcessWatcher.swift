import Foundation
import CodeIslandCore

/// A hook-backed CLI may exit without Stop/SessionEnd. Check ownership of its
/// known transcript, rather than treating a quiet turn as a finished turn.
@MainActor
final class RemoteCodexProcessWatcher {
    struct Candidate: Equatable {
        let sessionID: String
        let hostID: String
        let transcriptPath: String
        let lastActivity: Date
        let startTime: Date
    }

    var candidates: (String) -> [Candidate] = { _ in [] }
    var onEnded: (Candidate) -> Void = { _ in }
    private let probe: (RemoteHost, [String]) async -> Set<String>?
    private let now: () -> Date
    private var tasks: [String: Task<Void, Never>] = [:]
    private var missing: [String: [String: Candidate]] = [:]

    init(now: @escaping () -> Date = Date.init,
         probe: @escaping (RemoteHost, [String]) async -> Set<String>?) {
        self.now = now
        self.probe = probe
    }

    func start(host: RemoteHost) {
        stop(hostID: host.id)
        tasks[host.id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.check(host: host)
            }
        }
    }

    func stop(hostID: String) {
        tasks.removeValue(forKey: hostID)?.cancel()
        missing[hostID] = nil
    }

    func check(host: RemoteHost) async {
        // Hooks handle normal activity. Only quiet cards need a remote
        // process check; silence alone never settles a session.
        let checkedAt = now()
        let batch = candidates(host.id).filter {
            checkedAt.timeIntervalSince($0.lastActivity) >= 120
        }
        guard !batch.isEmpty else {
            missing[host.id] = nil
            return
        }
        let live = await probe(host, batch.map(\.transcriptPath))
        guard !Task.isCancelled else { return }
        guard let live else {
            // A transport/permission error is not evidence of process exit.
            missing[host.id] = nil
            return
        }
        let current = candidates(host.id)
        var next: [String: Candidate] = [:]
        for candidate in batch where !live.contains(candidate.transcriptPath) && current.contains(candidate) {
            if missing[host.id]?[candidate.sessionID] == candidate {
                onEnded(candidate)
            } else {
                next[candidate.sessionID] = candidate
            }
        }
        missing[host.id] = next
    }

    deinit { tasks.values.forEach { $0.cancel() } }
}

extension AppState {
    func remoteCodexProcessCandidates(hostID: String) -> [RemoteCodexProcessWatcher.Candidate] {
        sessions.compactMap { id, session in
            guard session.source == "codex", session.remoteHostId == hostID,
                  session.status != .idle, !session.connectionLost,
                  let path = session.transcriptPath, path.hasPrefix("/") else { return nil }
            return .init(sessionID: id, hostID: hostID, transcriptPath: path,
                         lastActivity: session.lastActivity, startTime: session.startTime)
        }
    }

    func settleExitedRemoteCodexProcess(_ candidate: RemoteCodexProcessWatcher.Candidate) {
        guard remoteCodexProcessCandidates(hostID: candidate.hostID).contains(candidate) else { return }
        retainEndedSession(candidate.sessionID)
    }
}
