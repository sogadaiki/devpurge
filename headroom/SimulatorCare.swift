import Foundation

struct SimulatorItem: Equatable {
    let id: String
    let runtime: String
    let build: String
    let name: String
    let bytes: Int64
    let detail: String
    let canRemove: Bool
}

struct SimulatorReport {
    let items: [SimulatorItem]
    let message: String
    let complete: Bool
}

enum SimulatorCare {
    typealias Command = (_ path: String, _ arguments: [String]) -> Data?
    private struct Image: Decodable {
        let identifier, runtimeIdentifier, version, build, state: String
        let sizeBytes: Int64
        let deletable: Bool
    }
    private struct DeviceList: Decodable {
        struct Device: Decodable { let state: String }
        let devices: [String: [Device]]
    }
    private static let xcrun = "/usr/bin/xcrun"

    private static func execute(_ path: String, _ arguments: [String]) -> Data? {
        let tool = Process()
        let output = Pipe()
        tool.executableURL = URL(fileURLWithPath: path)
        tool.arguments = arguments
        tool.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        tool.standardInput = FileHandle.nullDevice
        tool.standardOutput = output
        tool.standardError = FileHandle.nullDevice
        do { try tool.run() } catch { return nil }
        let timeout = DispatchWorkItem { if tool.isRunning { tool.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (arguments.contains("delete") ? 90 : 12), execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        return tool.terminationStatus == 0 ? data : nil
    }

    static func inspect() -> SimulatorReport { inspect(using: execute) }

    static func inspect(using run: Command) -> SimulatorReport {
        let failed = SimulatorReport(items: [], message: "Xcodeのランタイムと登録端末を照合できません。Xcodeの設定 → Components で確認してください。", complete: false)
        guard let data = run(xcrun, ["simctl", "runtime", "list", "-j"]),
              let images = try? JSONDecoder().decode([String: Image].self, from: data),
              let deviceData = run(xcrun, ["simctl", "list", "devices", "-j"]),
              let devices = try? JSONDecoder().decode(DeviceList.self, from: deviceData) else { return failed }
        let processes = run("/bin/ps", ["-axo", "comm="]).flatMap { String(data: $0, encoding: .utf8) }
        let building = processes.map { text in
            text.split(separator: "\n").contains { ($0.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent == "xcodebuild" }
        }
        var items: [SimulatorItem] = []
        for (key, image) in images {
            guard let uuid = UUID(uuidString: image.identifier), uuid == UUID(uuidString: key),
                  image.sizeBytes >= 0, image.runtimeIdentifier.hasPrefix("com.apple.CoreSimulator.SimRuntime.") else { return failed }
            let registered = devices.devices[image.runtimeIdentifier]
            let count = registered?.count
            let name = String(image.runtimeIdentifier.dropFirst("com.apple.CoreSimulator.SimRuntime.".count))
            let state = registered.map { entries in
                "このユーザーの登録端末 \(entries.count) 台（起動中・移行中 \(entries.filter { $0.state != "Shutdown" }.count) 台）"
            } ?? "登録端末数を確認できません"
            let eligible = image.deletable && image.state == "Ready" && count == 0 && building == false
            var detail = state
            if building == true { detail += "　·　Xcodeでビルド中" }
            if building == nil { detail += "　·　ビルド状況は不明" }
            if image.state != "Ready" || !image.deletable { detail += "　·　Xcodeの管理対象（\(image.state)）" }
            items.append(SimulatorItem(id: uuid.uuidString, runtime: image.runtimeIdentifier, build: image.build,
                name: "\(name)（\(image.build)）", bytes: image.sizeBytes, detail: detail, canRemove: eligible))
        }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return SimulatorReport(items: items, message: items.isEmpty ? "Xcodeの登録ランタイムは0件です。" :
            "Xcodeの登録は \(items.count) 件です。端末が残っているランタイムはXcodeの設定 → Components で確認できます。", complete: true)
    }

    static func remove(_ item: SimulatorItem) -> String { remove(item, using: execute) }

    static func remove(_ item: SimulatorItem, using run: Command) -> String {
        guard item.canRemove, UUID(uuidString: item.id) != nil,
              inspect(using: run).items.first(where: { $0.id == item.id }) == item else {
            return "端末・ビルド・ランタイムの状態を再確認した結果、削除を保留しました。"
        }
        let success = run(xcrun, ["simctl", "runtime", "delete", item.id]) != nil
        let current = inspect(using: run)
        if current.complete && !current.items.contains(where: { $0.id == item.id }) {
            return "\(item.name) が登録から外れたことを確認しました。"
        }
        return success ? "Xcodeに削除を依頼しました。登録から外れたことはまだ確認できません。" :
            "ランタイムの削除完了を確認できません。Xcodeの設定 → Components で状態を確認してください。"
    }
}
