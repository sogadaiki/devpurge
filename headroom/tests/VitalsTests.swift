// Run in a logged-in macOS GUI session. Only the unique fixture app receives a quit request.
import AppKit

private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let working = Bundle.main.bundleURL.deletingLastPathComponent()
    var memory = Data(repeating: 0x5a, count: 32 * 1024 * 1024)

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? Data().write(to: working.appendingPathComponent("launched"))
        // Release a fixture left behind by an interrupted test.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            try? Data().write(to: self.working.appendingPathComponent("allow-exit"))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        try? Data().write(to: working.appendingPathComponent("asked-to-quit"))
        return FileManager.default.fileExists(atPath: working.appendingPathComponent("allow-exit").path)
            ? .terminateNow : .terminateCancel
    }
}

@main
private enum VitalsTests {
    struct Failure: Error { let reason: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(reason: message) }
    }

    static func wait(_ seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return predicate()
    }

    static func main() throws {
        let application = NSApplication.shared
        if Bundle.main.object(forInfoDictionaryKey: "HeadroomTestFixture") as? Bool == true {
            let delegate = FixtureDelegate()
            application.setActivationPolicy(.regular)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
            return
        }

        application.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("headroom-vitals-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("MemoryFixture.app")
        let executableDirectory = bundle.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let copied = executableDirectory.appendingPathComponent("VitalsTests")
        guard let binary = Bundle.main.executableURL else { throw Failure(reason: "Missing test executable") }
        try fm.copyItem(at: binary, to: copied)
        let id = "local.devpurge.headroom.fixture." + UUID().uuidString
        let plist: [String: Any] = ["CFBundleExecutable": "VitalsTests", "CFBundleIdentifier": id,
                                    "CFBundlePackageType": "APPL", "CFBundleName": "MemoryFixture",
                                    "HeadroomTestFixture": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        var fixture: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { app, error in
            fixture = app
            launchError = error
        }
        try check(wait(15) { launchError != nil || fm.fileExists(atPath: root.appendingPathComponent("launched").path) },
                  "Fixture did not launch")
        if let launchError { throw launchError }
        guard let running = fixture, running.bundleIdentifier == id,
              running.bundleURL?.resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath()
        else { throw Failure(reason: "Fixture identity mismatch") }
        let permit = root.appendingPathComponent("allow-exit")
        defer {
            if !running.isTerminated {
                try? Data().write(to: permit)
                _ = running.terminate()
                _ = wait(5) { running.isTerminated }
            }
        }
        let sample = Vitals.read()
        try check(sample.diskFree != nil && sample.swapUsed != nil && sample.physicalMemory > 0 &&
                  sample.freeMemory != nil, "Native metrics missing")
        let apps = Vitals.apps()
        guard let target = apps.first(where: { $0.pid == running.processIdentifier && $0.bundleURL == running.bundleURL })
        else { throw Failure(reason: "Fixture not found in normal app listing") }
        try check(target.canQuit && (target.bytes ?? 0) > 32 * 1024 * 1024, "Fixture memory not observed")
        try check(!apps.contains(where: { $0.bundleURL.lastPathComponent == "Finder.app" && $0.canQuit }), "Finder targetable")

        var observation: QuitObservation?
        Vitals.requestQuit(target) { observation = $0 }
        try check(wait(35) { observation != nil }, "Declined request did not complete")
        try check(observation?.didExit == false && !running.isTerminated &&
                  fm.fileExists(atPath: root.appendingPathComponent("asked-to-quit").path),
                  "Declined quit counted as exit")

        try Data().write(to: permit)
        observation = nil
        Vitals.requestQuit(target) { observation = $0 }
        try check(wait(15) { observation != nil }, "Permitted request did not complete")
        try check(observation?.didExit == true && running.isTerminated, "Actual exit missing")
        print("Fixture footprint \(target.bytes ?? 0) B. \(observation?.message ?? "")")
        observation = nil
        Vitals.requestQuit(target) { observation = $0 }
        try check(observation?.didExit == false, "Stale selection accepted")
        print("PASS: machine metrics, app footprint, protected app, declined quit, confirmed normal exit, stale selection.")
    }
}
