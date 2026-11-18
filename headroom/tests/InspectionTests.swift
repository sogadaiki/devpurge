import Foundation

@main
struct InspectionTests {
    static func main() {
        let suite = "jp.devpurge.headroom.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scans = Baselines(defaults: defaults)
        precondition(scans.record(scope: "/planA", values: ["build": 70]) == nil)
        precondition(scans.record(scope: "/planB", values: ["build": 200]) == nil)
        let previous = Baselines(defaults: defaults).record(scope: "/planA", values: [:], complete: false)
        precondition(previous?.complete == true && previous?.values["build"] == 70)
        let partial = scans.record(scope: "/planA", values: ["new-build": 10])
        precondition(partial?.complete == false)
        precondition(change(100, nil) == nil && change(100, 100) == "増減なし")
        precondition(change(120, 100) == "＋20 B" && change(90, 100) == "−10 B")
        print("PASS independent project baselines, persistence, unknown and signed change")
    }
}
