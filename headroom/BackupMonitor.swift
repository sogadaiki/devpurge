import Combine
import Foundation

enum BackupPhase: Equatable {
    case checking, unknown, idle, preparing, copying, finishing, stopping, running

    init(_ status: BackupStatusSample) {
        guard let running = status.running else { self = .unknown; return }
        guard running else { self = .idle; return }
        switch status.phase?.lowercased() {
        case "starting", "preparing", "mountingbackupvol", "preparingvolumes",
             "findingchanges", "sizing", "thinningprebackup", "connecting",
             "mountingbackupvolume", "creatingsnapshot": self = .preparing
        case "copying", "copyingfiles": self = .copying
        case "finishing", "finalizing", "thinningpostbackup", "cleaningup",
             "verifying", "unmountingbackupvol": self = .finishing
        case "canceling", "cancelling", "stopping": self = .stopping
        default: self = .running
        }
    }

    var label: String {
        switch self {
        case .checking: return "確認中"
        case .unknown: return "状態を確認できません"
        case .idle: return "待機中"
        case .preparing: return "準備中"
        case .copying: return "コピー中"
        case .finishing: return "仕上げ中"
        case .stopping: return "中止処理中"
        case .running: return "バックアップ中"
        }
    }
}

struct BackupRun: Codable, Equatable {
    var destinationID: String?
    var destinationName: String?
    var sessionStart: Date?
    var firstAt: Date
    var lastActiveAt: Date
    var endedAt: Date?
    var firstFree: Int64?
    var minimumFree: Int64?
    var finalFree: Int64?
    var confirmedAt: Date?
    var isClosed: Bool

    // Three 30-second samples. After sleep or a stopped app, current free space
    // cannot stand in for the (missed) end of an earlier backup.
    private static let observationGap: TimeInterval = 90

    fileprivate func continues(_ status: BackupStatusSample, at time: Date) -> Bool {
        guard !isClosed, time >= lastActiveAt else { return false }
        if let old = destinationID, let new = status.destinationID,
           old.caseInsensitiveCompare(new) != .orderedSame { return false }
        if let before = sessionStart, let now = status.sessionStart { return before == now }
        return time.timeIntervalSince(lastActiveAt) <= Self.observationGap
    }

    fileprivate mutating func observeFree(_ bytes: Int64?) {
        if let bytes { minimumFree = min(minimumFree ?? bytes, bytes) }
    }

    fileprivate mutating func close(at time: Date, free: Int64?) {
        isClosed = true
        let sinceActive = time.timeIntervalSince(lastActiveAt)
        guard (0...Self.observationGap).contains(sinceActive) else { return }
        endedAt = time
        finalFree = free
        observeFree(free)
    }

    fileprivate func matches(_ evidence: BackupSaveEvidence) -> Bool {
        guard isClosed,
              destinationID?.caseInsensitiveCompare(evidence.destinationID) == .orderedSame,
              evidence.completedAt >= (sessionStart ?? firstAt) else { return false }
        let upperBound = endedAt ?? lastActiveAt.addingTimeInterval(Self.observationGap)
        return evidence.completedAt <= upperBound
    }
}

// Persist only the latest independently verified save and the last observed run.
// The instantaneous phase must be queried again after an app restart.
struct BackupTracking: Codable, Equatable {
    var latest: BackupSaveEvidence?
    var run: BackupRun?

    mutating func observe(_ status: BackupStatusSample, at time: Date, freeBytes: Int64?) {
        guard let running = status.running else { return }
        let free = freeBytes.flatMap { $0 >= 0 ? $0 : nil }
        guard running else {
            if run?.isClosed == false { run?.close(at: time, free: free) }
            return
        }
        if run?.continues(status, at: time) == true {
            if let id = status.destinationID { run?.destinationID = id }
            if let name = status.destinationName { run?.destinationName = name }
            if let start = status.sessionStart { run?.sessionStart = start }
            run?.lastActiveAt = time
            run?.observeFree(free)
        } else {
            run = BackupRun(destinationID: status.destinationID, destinationName: status.destinationName,
                            sessionStart: status.sessionStart, firstAt: time, lastActiveAt: time,
                            firstFree: free, minimumFree: free, isClosed: false)
        }
    }

    mutating func verify(_ evidence: BackupSaveEvidence) {
        if latest.map({ evidence.completedAt >= $0.completedAt }) ?? true { latest = evidence }
        if run?.matches(evidence) == true { run?.confirmedAt = evidence.completedAt }
    }
}

final class BackupMonitor: ObservableObject {
    @Published private(set) var phase = BackupPhase.checking
    @Published private var tracking: BackupTracking
    var latest: BackupSaveEvidence? { tracking.latest }
    var run: BackupRun? { tracking.run }

    private let queue = DispatchQueue(label: "jp.devpurge.headroom.backup", qos: .utility)
    private let defaults: UserDefaults
    private static let key = "timeMachineObservations.v1"
    private let probe = BackupProbe()
    private let history: ((BackupSaveEvidence) -> BackupRun?)?
    private var inFlight = false
    private var lastRefresh: Date?
    private var lastVerification: Date?
    private var attemptedImport: Date?

    init(defaults: UserDefaults = .standard, history: ((BackupSaveEvidence) -> BackupRun?)? = nil) {
        self.defaults = defaults
        self.history = history
        tracking = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(BackupTracking.self, from: $0) } ?? BackupTracking()
    }

    // Called on the main queue by the app's existing timer and menu action.
    func refresh(freeBytes: Int64?) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = Date()
        guard !inFlight else { return }
        if let lastRefresh, (0..<2).contains(now.timeIntervalSince(lastRefresh)) { return }
        inFlight = true
        lastRefresh = now
        let previous = tracking
        let previousCheck = lastVerification
        let imported = attemptedImport
        queue.async {
            let status = self.probe.status()
            let phase = BackupPhase(status)
            var next = previous
            next.observe(status, at: now, freeBytes: freeBytes)
            let justClosed = previous.run?.isClosed == false && next.run?.isClosed == true
            let waiting = next.run?.confirmedAt == nil && next.run?.endedAt.map { now.timeIntervalSince($0) < 300 } == true
            let elapsed = previousCheck.map { now.timeIntervalSince($0) } ?? .infinity
            let verify = previousCheck == nil || justClosed || (status.running != true &&
                (elapsed < 0 || elapsed >= (waiting ? 45 : 300)))
            var importDate = imported
            if verify {
                // A log or disk read can take several seconds. Publish the known
                // phase now; verification only refines the receipt for this run.
                let observed = next
                DispatchQueue.main.async { self.publish(phase: phase, tracking: observed) }
                let target = (waiting || status.running == true) ? next.run?.destinationID : nil
                if let receipt = self.probe.latest(destinationID: target) {
                    next.verify(receipt)
                    if next.run == nil, imported != receipt.completedAt {
                        importDate = receipt.completedAt
                        if let recovered = self.history?(receipt), recovered.matches(receipt),
                           recovered.confirmedAt == receipt.completedAt {
                            next.run = recovered
                        }
                    }
                }
            }
            let updated = next
            let attempted = importDate
            DispatchQueue.main.async {
                self.publish(phase: phase, tracking: updated)
                if verify { self.lastVerification = now }
                self.attemptedImport = attempted
                self.inFlight = false
            }
        }
    }

    private func publish(phase: BackupPhase, tracking: BackupTracking) {
        if self.phase != phase { self.phase = phase }
        guard self.tracking != tracking else { return }
        self.tracking = tracking
        if let encoded = try? JSONEncoder().encode(tracking) {
            defaults.set(encoded, forKey: Self.key)
        }
    }
}
