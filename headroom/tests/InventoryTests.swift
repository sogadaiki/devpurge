import Foundation

@main
struct InventoryTests {
    static func checkLifecycle(home: URL) throws {
        let fixture = home.appendingPathComponent("lifecycle.py")
        try """
        import json, os, pathlib, subprocess, sys, time
        mode, marker = sys.argv[1], pathlib.Path(sys.argv[2])
        if mode == "read":
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(12)"])
            marker.write_text(str(child.pid))
            child.wait()
        elif mode == "write":
            marker.write_text(str(os.getpid()))
            deadline = time.monotonic() + 10
            while not marker.with_suffix(".release").exists() and time.monotonic() < deadline:
                time.sleep(.02)
        print(json.dumps({"status":mode,"reason":"test"}))
        """.write(to: fixture, atomically: true, encoding: .utf8)

        func waitFor(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(5)
            while !condition() && Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            return condition()
        }
        func launch(_ mode: String, tracker: InventoryProcesses, marker: URL) -> DispatchGroup {
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                do {
                    let receipt: InventoryReceipt = try WorkspaceInventory.run([mode, marker.path], accepting: [0],
                        writing: mode == "write", tracker: tracker, script: fixture, home: home)
                    precondition(mode == "write" && receipt.status == mode, "Read was not cancelled")
                } catch {
                    precondition(mode == "read", "A started write was interrupted")
                }
            }
            return group
        }

        let manual = InventoryProcesses()
        let old = manual.readToken()
        let indexRead = manual.readToken(.projectIndex)
        let marker = home.appendingPathComponent("manual-job")
        let reading = launch("read", tracker: manual, marker: marker)
        precondition(waitFor { (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int32.init) != nil })
        let child = try Int32(String(contentsOf: marker, encoding: .utf8))!
        manual.cancelReads()
        try manual.check(indexRead)
        precondition(reading.wait(timeout: .now() + 4) == .success)
        precondition(waitFor { kill(child, 0) == -1 && errno == ESRCH })
        do {
            let _: InventoryReceipt = try WorkspaceInventory.run(["done", marker.path], accepting: [0],
                readToken: old, tracker: manual, script: fixture, home: home)
            preconditionFailure("A queued read survived cancellation")
        } catch { precondition(error.localizedDescription.contains("中止")) }
        let restarted: InventoryReceipt = try WorkspaceInventory.run(["done", marker.path], accepting: [0],
            readToken: manual.readToken(), tracker: manual, script: fixture, home: home)
        precondition(restarted.status == "done")

        for withWrite in [false, true] {
            let tracker = InventoryProcesses()
            let readMarker = home.appendingPathComponent("read-\(withWrite)")
            let writeMarker = home.appendingPathComponent("write-\(withWrite)")
            let read = launch("read", tracker: tracker, marker: readMarker)
            let write = withWrite ? launch("write", tracker: tracker, marker: writeMarker) : nil
            precondition(waitFor { (try? String(contentsOf: readMarker, encoding: .utf8)).flatMap(Int32.init) != nil &&
                (!withWrite || FileManager.default.fileExists(atPath: writeMarker.path)) })
            let child = try Int32(String(contentsOf: readMarker, encoding: .utf8))!
            var notified = false
            let quitNow = tracker.prepareForQuit { precondition(Thread.isMainThread); notified = true }
            precondition(quitNow == !withWrite && !notified)
            precondition(read.wait(timeout: .now() + 4) == .success)
            precondition(waitFor { kill(child, 0) == -1 && errno == ESRCH })
            for writing in [false, true] {
                do {
                    let _: InventoryReceipt = try WorkspaceInventory.run(["done", readMarker.path], accepting: [0],
                        writing: writing, tracker: tracker, script: fixture, home: home)
                    preconditionFailure("A new job started during quit")
                } catch { precondition(error.localizedDescription.contains("終了")) }
            }
            if let write {
                precondition(write.wait(timeout: .now()) == .timedOut && !notified)
                try Data().write(to: writeMarker.appendingPathExtension("release"))
                precondition(write.wait(timeout: .now() + 4) == .success)
                precondition(waitFor { notified })
            }
        }
    }

    static func main() throws {
        let files = FileManager.default
        guard let resolved = realpath(files.temporaryDirectory.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        let home = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/workspaces.py")
        let repo = home.appendingPathComponent("ゲーム $(example) 1")
        try files.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            command.arguments = ["-C", repo.path] + arguments
            command.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
            command.standardOutput = FileHandle.nullDevice
            try command.run()
            command.waitUntilExit()
            precondition(command.terminationStatus == 0)
        }
        try git(["init", "-qb", "main"])
        try git(["-c", "user.email=example@invalid", "-c", "user.name=Fixture", "commit", "--allow-empty", "-m", "initial"])
        try git(["branch", "finished"])

        let empty: InventoryReport = try WorkspaceInventory.run(["--json", "--configured-only"],
            accepting: [0, 1], script: source, home: home)
        precondition(empty.projects.isEmpty && empty.failedProjects == 0)
        let policy = home.appendingPathComponent(".devpurgerc")
        try "workspace_project=\(repo.path)\n".write(to: policy, atomically: true, encoding: .utf8)
        let inventory: InventoryReport = try WorkspaceInventory.run(["--json", "--configured-only"],
            accepting: [0, 1], script: source, home: home)
        precondition(inventory.projects.count == 1 && inventory.projects[0].repo == repo.path,
                     inventory.warnings.joined(separator: "\n"))
        let project = inventory.projects[0]
        precondition(!project.metadataOnly && project.worktrees.count == 1 && project.worktrees[0].primary)
        precondition(project.branches.first { $0.name == "main" }?.category == .checkedOut)
        precondition(project.branches.first { $0.name == "finished" }?.category == .candidate)
        let partial: InventoryReport = try WorkspaceInventory.run(["--json", "--", repo.path, home.appendingPathComponent("missing").path],
            accepting: [0, 1], script: source, home: home)
        precondition(partial.projects.count == 1 && partial.failedProjects == 1 && !partial.warnings.isEmpty)
        let held: InventoryReceipt = try WorkspaceInventory.run(["--json", "--check-worktree", repo.path, "--", repo.path],
            accepting: [0, 1], script: source, home: home)
        precondition(held.status == "held" && !held.reason.isEmpty)

        let a = home.appendingPathComponent("コピー A.txt"), b = home.appendingPathComponent("残す B.txt")
        try "alpha".write(to: a, atomically: true, encoding: .utf8)
        try "other".write(to: b, atomically: true, encoding: .utf8)
        let different: InventoryComparison = try WorkspaceInventory.run(["--json", "--compare", a.path, b.path],
            accepting: [0, 1, 2], script: source, home: home)
        precondition(different.status == "different" && different.differenceCount == 1)
        try files.removeItem(at: b)
        let incomplete: InventoryComparison = try WorkspaceInventory.run(["--json", "--compare", a.path, b.path],
            accepting: [0, 1, 2], script: source, home: home)
        precondition(incomplete.status == "incomplete" && !incomplete.warnings.isEmpty)

        // A CLT process can fill both pipes before exiting. Keep detailed valid partial
        // output and reject a valid-looking payload when the process itself failed.
        let script = home.appendingPathComponent("output.py")
        try """
        import json, sys
        sys.stderr.write("x" * 200000)
        print(json.dumps({"status":"held","reason":"y"*300000}))
        sys.exit(int(sys.argv[1]))
        """.write(to: script, atomically: true, encoding: .utf8)
        let large: InventoryReceipt = try WorkspaceInventory.run(["1"], accepting: [0, 1], script: script, home: home)
        precondition(large.status == "held" && large.reason.count == 300000)
        do {
            let _: InventoryReceipt = try WorkspaceInventory.run(["3"], accepting: [0, 1], script: script, home: home)
            preconditionFailure("Invalid exit code accepted")
        } catch { precondition(!error.localizedDescription.isEmpty) }

        try checkLifecycle(home: home)
        try files.removeItem(at: policy)
        try files.createSymbolicLink(at: policy, withDestinationURL: home.appendingPathComponent("missing"))
        do {
            let _: InventoryReport = try WorkspaceInventory.run(["--json", "--", repo.path],
                accepting: [0, 1], script: source, home: home)
            preconditionFailure("Dangling policy link accepted")
        } catch { precondition(error.localizedDescription.contains(".devpurgerc")) }
        print("PASS inventories, receipts, comparisons, process output, cancellation and safe quit")
    }
}
