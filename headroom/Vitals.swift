import AppKit
import Darwin

enum MemoryState: Equatable {
    case normal, warning, critical, unknown

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "注意"
        case .critical: return "逼迫"
        case .unknown: return "不明"
        }
    }
}

struct MachineVitals {
    let diskFree: Int64?
    let diskAvailableForImportantUsage: Int64?
    let pressure: MemoryState
    let swapUsed: Int64?
    let physicalMemory: Int64
    /// System-wide free pages at the instant of sampling, including speculative pages.
    let freeMemory: Int64?
}

struct MemoryApp {
    let pid: pid_t
    let name: String
    /// Observed physical footprint of this process and attributable descendants.
    let bytes: Int64?
    let bundleURL: URL
    let canQuit: Bool
    fileprivate let instance: NSRunningApplication
    fileprivate let start: UInt64?
}

struct QuitObservation {
    let message: String
    let didExit: Bool
    let before: MachineVitals
    let after: MachineVitals
}

enum Vitals {
    private static func freeRAM() -> Int64? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard code == KERN_SUCCESS else { return nil }
        return Int64(vm.free_count) * Int64(vm_kernel_page_size)
    }

    static func read() -> MachineVitals {
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        var fs = statfs()
        let free = statfs(dataVolume.path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil
        let capacity = try? dataVolume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let estimate = capacity?.volumeAvailableCapacityForImportantUsage.flatMap { $0 >= 0 ? $0 : nil }
        var level: Int32 = 0
        var levelSize = MemoryLayout.size(ofValue: level)
        var pressure = MemoryState.unknown
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            switch level {
            case 1: pressure = .normal
            case 2: pressure = .warning
            case 4: pressure = .critical
            default: break
            }
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout.size(ofValue: swap)
        let used = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? Int64(swap.xsu_used) : nil
        return MachineVitals(diskFree: free, diskAvailableForImportantUsage: estimate, pressure: pressure, swapUsed: used,
                             physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory), freeMemory: freeRAM())
    }

    private static func usage(_ pid: pid_t) -> rusage_info_v0? {
        var info = rusage_info_v0()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    private static func parents() -> [pid_t: pid_t] {
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: count + 128)
        let found = pids.withUnsafeMutableBytes {
            Int(proc_listallpids($0.baseAddress, Int32($0.count)))
        }
        var result: [pid_t: pid_t] = [:]
        let uid = getuid()
        for pid in pids.prefix(max(0, found)) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid {
                result[pid] = pid_t(info.pbi_ppid)
            }
        }
        return result
    }

    private static func allowsQuit(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, app.processIdentifier > 1,
              app.processIdentifier != getpid(), !app.isTerminated, app.isFinishedLaunching,
              let id = app.bundleIdentifier, let url = app.bundleURL,
              !url.path.hasPrefix("/System/Library/") else { return false }
        return !["com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
                 "com.apple.systemuiserver", Bundle.main.bundleIdentifier].contains(id)
    }

    static func apps() -> [MemoryApp] {
        let roots = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleURL != nil && $0.processIdentifier > 1
        }
        let rootPIDs = Set(roots.map(\.processIdentifier))
        var totals: [pid_t: Int64] = [:]
        var starts: [pid_t: UInt64] = [:]
        for app in roots {
            let pid = app.processIdentifier
            if let info = usage(pid) {
                totals[pid] = Int64(info.ri_phys_footprint)
                starts[pid] = info.ri_proc_start_abstime
            }
        }
        let tree = parents()
        for pid in tree.keys where !rootPIDs.contains(pid) {
            var seen: Set<pid_t> = [pid]
            var next = tree[pid]
            while let ancestor = next, seen.insert(ancestor).inserted {
                if rootPIDs.contains(ancestor) {
                    if totals[ancestor] != nil, let info = usage(pid) {
                        totals[ancestor, default: 0] += Int64(info.ri_phys_footprint)
                    }
                    break
                }
                next = tree[ancestor]
            }
        }
        return roots.compactMap { app -> MemoryApp? in
            guard let url = app.bundleURL else { return nil }
            let pid = app.processIdentifier
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            return MemoryApp(pid: pid, name: name, bytes: totals[pid], bundleURL: url,
                             canQuit: starts[pid] != nil && allowsQuit(app),
                             instance: app, start: starts[pid])
        }.sorted {
            if $0.bytes == $1.bytes { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return ($0.bytes ?? -1) > ($1.bytes ?? -1)
        }
    }

    /// Call on the main thread, from an explicit user selection. Never signals a PID.
    static func requestQuit(_ app: MemoryApp, completion: @escaping (QuitObservation) -> Void) {
        precondition(Thread.isMainThread)
        let before = read()
        func finish(_ didExit: Bool, _ message: String) {
            let after = read()
            var text = message
            if didExit {
                if let first = before.freeMemory, let last = after.freeMemory {
                    text += String(format: "　Mac全体の空きRAM %.0f → %.0f MB。", Double(first) / 1e6, Double(last) / 1e6)
                }
                text += "　メモリ負荷 \(before.pressure.label) → \(after.pressure.label)"
                if let first = before.swapUsed, let last = after.swapUsed {
                    text += String(format: "、スワップ %.1f → %.1f GB", Double(first) / 1e9, Double(last) / 1e9)
                }
            }
            completion(QuitObservation(message: text, didExit: didExit, before: before, after: after))
        }
        guard app.canQuit, let savedStart = app.start,
              let current = NSRunningApplication(processIdentifier: app.pid),
              app.instance.isEqual(current), allowsQuit(current),
              let atRequest = usage(app.pid), atRequest.ri_proc_start_abstime == savedStart else {
            finish(false, "アプリの状態が変わりました。一覧を更新してください。")
            return
        }
        guard current.terminate() else {
            finish(false, "\(app.name) に終了を依頼できませんでした。")
            return
        }
        let deadline = DispatchTime.now() + 30
        func observe() {
            if current.isTerminated {
                let footprint = String(format: "%.0f MB", Double(atRequest.ri_phys_footprint) / 1e6)
                finish(true, "\(app.name) の終了を確認しました。終了依頼時のアプリ本体は \(footprint)。")
            } else if DispatchTime.now() >= deadline {
                finish(false, "\(app.name) はまだ起動中です。保存の確認画面が開いている場合があります。")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { observe() }
            }
        }
        observe()
    }
}
