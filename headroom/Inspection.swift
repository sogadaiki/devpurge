import Foundation

// Compare only consecutive, complete measurements of the same scope.
struct ScanBaseline: Codable {
    var date: Date
    var values: [String: Int64]
    var complete: Bool
}

struct Baselines {
    private let defaults: UserDefaults
    private let key = "scanBaselines.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(scope: String, values: [String: Int64], complete: Bool = true) -> ScanBaseline? {
        var history = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: ScanBaseline].self, from: $0) } ?? [:]
        let previous = history[scope]
        history[scope] = ScanBaseline(date: Date(), values: values, complete: complete)
        if history.count > 12, let oldest = history.min(by: { $0.value.date < $1.value.date }) {
            history.removeValue(forKey: oldest.key)
        }
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: key) }
        return previous
    }
}

enum Inspection {
    static func localSnapshots() -> Int? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "listSnapshots", "/System/Volumes/Data", "-plist"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let snapshots = plist["Snapshots"] as? [[String: Any]] else { return nil }
            return snapshots.compactMap { $0["SnapshotName"] as? String }.filter {
                $0.hasPrefix("com.apple.TimeMachine.") && $0.hasSuffix(".local")
            }.count
        } catch { return nil }
    }
}

func quantity(_ bytes: Int64?) -> String {
    guard let bytes else { return "未計測" }
    let size = Double(bytes)
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", size / 1e9) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", size / 1e6) }
    if bytes >= 1_000 { return String(format: "%.0f KB", size / 1e3) }
    return "\(bytes) B"
}

func change(_ new: Int64?, _ old: Int64?) -> String? {
    guard let new, let old else { return nil }
    let difference = new - old
    return difference == 0 ? "増減なし" : (difference > 0 ? "＋" : "−") + quantity(abs(difference))
}
