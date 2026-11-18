import Foundation

@main
struct SimulatorTests {
    static func main() {
        let id = UUID().uuidString
        let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-Example"
        var installed = true
        var imageBuild = "A1"
        var registered: [[String: String]]? = []
        var runningBuild = false
        var permitted = true
        var requests = [[String]]()
        var removeWorks = true
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let run: SimulatorCare.Command = { path, args in
            if path == "/bin/ps" { return Data((runningBuild ? "/some/Xcode/usr/bin/xcodebuild" : "/usr/libexec/example").utf8) }
            precondition(path == "/usr/bin/xcrun")
            if args == ["simctl", "list", "devices", "-j"] {
                let byRuntime: [String: [[String: String]]] = registered.map { [runtime: $0] } ?? [:]
                return json(["devices": byRuntime])
            }
            if args == ["simctl", "runtime", "list", "-j"] {
                let image: [String: Any] = ["identifier": id, "build": imageBuild, "version": "1.2",
                    "runtimeIdentifier": runtime, "sizeBytes": 8_000_000_000, "state": "Ready", "deletable": permitted]
                return json(installed ? [id: image] : [:])
            }
            precondition(args == ["simctl", "runtime", "delete", id])
            requests.append(args)
            if removeWorks { installed = false }
            return Data()
        }
        let candidate = SimulatorCare.inspect(using: run).items[0]
        precondition(candidate.canRemove)
        for devices in [nil, [["state": "Shutdown"]], [["state": "Booted"]]] as [[[String: String]]?] {
            registered = devices
            precondition(!SimulatorCare.inspect(using: run).items[0].canRemove)
            _ = SimulatorCare.remove(candidate, using: run)
        }
        registered = []
        runningBuild = true
        _ = SimulatorCare.remove(candidate, using: run)
        runningBuild = false
        permitted = false
        _ = SimulatorCare.remove(candidate, using: run)
        permitted = true
        imageBuild = "B2"
        _ = SimulatorCare.remove(candidate, using: run)
        precondition(requests.isEmpty)
        imageBuild = "A1"
        removeWorks = false
        precondition(SimulatorCare.remove(candidate, using: run).contains("まだ確認できません"))
        removeWorks = true
        precondition(SimulatorCare.remove(candidate, using: run).contains("登録から外れた"))
        precondition(requests.count == 2 && SimulatorCare.inspect(using: run).items.isEmpty)
        precondition(!SimulatorCare.inspect(using: { _, _ in nil }).complete)
        print("PASS selected runtime UUID, devices, changed state, active build and deletion readback")
    }
}
