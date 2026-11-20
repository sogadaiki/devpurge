import Foundation

struct BackupStatusSample {
    let running: Bool?
    let phase: String?
    let destinationID: String?
    let destinationName: String?
    let sessionStart: Date?
}

struct BackupSaveEvidence: Codable, Equatable {
    let destinationID: String
    let destinationName: String
    let completedAt: Date
    let snapshotDate: Date?
}

/// These synchronous reads belong on the monitor's serial background queue.
final class BackupProbe {
    private var cached: (volumes: Set<UUID>, save: BackupSaveEvidence)?

    private static func formatter(_ format: String, zone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    // Both fixed queries have small output: one status or a single generation's success events.
    private static func output(_ executable: String, _ arguments: [String], timeout: Int) -> Data? {
        let process = Process()
        let pipe = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + .seconds(timeout)) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    func status() -> BackupStatusSample {
        Self.parseStatus(Self.output("/usr/bin/tmutil", ["status"], timeout: 5))
    }

    static func parseStatus(_ data: Data?) -> BackupStatusSample {
        // tmutil prepends a human-readable heading to the OpenStep property list.
        var fields: [String: Any] = [:]
        if let data, let start = data.firstIndex(of: 0x7b),
           let parsed = try? PropertyListSerialization.propertyList(from: data[start...], format: nil) {
            fields = parsed as? [String: Any] ?? [:]
        }
        let running: Bool?
        switch (fields["Running"] as? NSNumber)?.stringValue ?? fields["Running"] as? String {
        case "1": running = true
        case "0": running = false
        default: running = nil
        }
        let destination = (fields["DestinationMountPoint"] as? String)
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
        let date = (fields["DateOfStateChange"] as? Date) ?? (fields["DateOfStateChange"] as? String)
            .flatMap { formatter("yyyy-MM-dd HH:mm:ss Z").date(from: $0) }
        return BackupStatusSample(running: running, phase: fields["BackupPhase"] as? String,
                                  destinationID: fields["DestinationID"] as? String,
                                  destinationName: destination, sessionStart: date)
    }

    struct Generation {
        let id: String
        let name: String
        let volumes: Set<UUID>
        let date: Date

        init?(_ record: [String: Any]) {
            guard let id = record["DestinationID"] as? String, !id.isEmpty,
                  let identifiers = record["DestinationUUIDs"] as? [String],
                  let date = (record["SnapshotDates"] as? [Date])?.max() else { return nil }
            self.id = id
            name = record["LastKnownVolumeName"] as? String ?? "バックアップ先"
            volumes = Set(identifiers.compactMap(UUID.init(uuidString:)))
            guard !volumes.isEmpty else { return nil }
            self.date = date
        }
    }

    func latest(destinationID: String?) -> BackupSaveEvidence? {
        let records = CFPreferencesCopyValue("Destinations" as CFString, "com.apple.TimeMachine" as CFString,
                                             kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [[String: Any]] ?? []
        let generations = records.compactMap(Generation.init).filter { generation in
            destinationID.map { $0.caseInsensitiveCompare(generation.id) == .orderedSame } ?? true
        }
        guard let generation = generations.max(by: { $0.date < $1.date }) else { return nil }
        if let cached, cached.volumes == generation.volumes, cached.save.destinationID == generation.id,
           cached.save.destinationName == generation.name, cached.save.snapshotDate == generation.date {
            return cached.save
        }
        // SnapshotDates identifies a restore point, not the moment backupd finished saving it.
        let generationName = Self.formatter("yyyy-MM-dd-HHmmss").string(from: generation.date) + ".backup"
        let predicate = "process == \"backupd\" AND subsystem == \"com.apple.TimeMachine\" AND " +
            "eventMessage BEGINSWITH \"Successfully completed backing up \" AND eventMessage CONTAINS \"/\(generationName)\""
        let args = ["show", "--info", "--style", "ndjson", "--start", "@\(Int(generation.date.timeIntervalSince1970) - 1)",
                    "--predicate", predicate]
        guard let data = Self.output("/usr/bin/log", args, timeout: 12),
              let evidence = Self.matchSuccess(data, generation: generation, name: generationName) else { return nil }
        cached = (generation.volumes, evidence)
        return evidence
    }

    static func matchSuccess(_ events: Data, generation: Generation, name: String) -> BackupSaveEvidence? {
        let timestamps = formatter("yyyy-MM-dd HH:mm:ss.SSSSSSZ")
        var latest: Date?
        for line in events.split(separator: 0x0a) {
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let message = event["eventMessage"] as? String,
                  message.hasPrefix("Successfully completed backing up "), message.hasSuffix("'"),
                  let separator = message.range(of: " to '/Volumes/.timemachine/"),
                  let timestamp = event["timestamp"] as? String, let date = timestamps.date(from: timestamp),
                  date >= generation.date else { continue }
            let path = message[separator.upperBound...].dropLast().split(separator: "/")
            guard path.count >= 2, let volume = UUID(uuidString: String(path[0])), generation.volumes.contains(volume),
                  path.dropFirst().allSatisfy({ $0 == name }) else { continue }
            latest = max(latest ?? date, date)
        }
        return latest.map { BackupSaveEvidence(destinationID: generation.id, destinationName: generation.name,
                                              completedAt: $0, snapshotDate: generation.date) }
    }
}
