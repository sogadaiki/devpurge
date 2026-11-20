import Foundation

/// The earlier disk-space watch wrote samples, but only backupd can confirm a save.
enum BackupHistory {
    private struct Sample: Decodable {
        struct Status: Decodable {
            let Running: String?
            let DestinationID: String?
        }
        let time: Date
        let actual: Int64?
        let state: Status
    }

    static func run(for save: BackupSaveEvidence) -> BackupRun? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent("devpurge/logs", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return nil }
        let logs = urls.filter { $0.lastPathComponent.hasPrefix("time-machine-watch-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in logs.prefix(5) {
            guard let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true,
                  info.isSymbolicLink == false, let size = info.fileSize, size > 0, size <= 8_000_000,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: size + 1), data.count == size,
               let run = matchedRun(data, save: save) { return run }
        }
        return nil
    }

    static func matchedRun(_ data: Data, save: BackupSaveEvidence) -> BackupRun? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var first: Sample?
        var lastActive: Date?
        var ended: Sample?
        var previous: Date?
        var minimum: Int64?
        for line in data.split(separator: 10) {
            guard let sample = try? decoder.decode(Sample.self, from: Data(line)),
                  previous.map({ sample.time > $0 && sample.time.timeIntervalSince($0) <= 120 }) ?? true,
                  sample.actual.map({ $0 >= 0 }) ?? true else { return nil }
            previous = sample.time
            switch sample.state.Running {
            case "1":
                guard ended == nil, sample.state.DestinationID?.caseInsensitiveCompare(save.destinationID) == .orderedSame
                else { return nil }
                if first == nil { first = sample }
                lastActive = sample.time
            case "0":
                guard first != nil else { return nil }
                if ended != nil { continue }
                ended = sample
            default:
                return nil
            }
            if let value = sample.actual { minimum = min(minimum ?? value, value) }
        }
        guard let first, let lastActive, let ended, first.time <= save.completedAt,
              abs(lastActive.timeIntervalSince(save.completedAt)) <= 120,
              (0...120).contains(ended.time.timeIntervalSince(save.completedAt)) else { return nil }
        return BackupRun(destinationID: save.destinationID, destinationName: save.destinationName,
                         sessionStart: nil, firstAt: first.time, lastActiveAt: lastActive,
                         endedAt: ended.time, firstFree: first.actual, minimumFree: minimum,
                         finalFree: ended.actual, confirmedAt: save.completedAt, isClosed: true)
    }
}
