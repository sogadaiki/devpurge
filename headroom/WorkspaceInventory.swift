import Darwin
import Foundation

struct InventoryReport: Decodable {
    let time: String
    let projects: [InventoryProject]
    let folders: [InventoryFolder]
    let warnings: [String]
    let failedProjects: Int
}

struct InventoryProject: Decodable, Identifiable {
    let repo: String
    let base: String?
    let metadataOnly: Bool
    let worktrees: [InventoryWorktree]
    let branches: [InventoryBranch]
    let warnings: [String]
    var id: String { repo }
}

struct InventoryWorktree: Decodable, Identifiable {
    let path: String
    let branch: String?
    let head: String?
    let primary: Bool
    let present: Bool?
    let locked: Bool
    let prunable: Bool
    let status: String
    let location: String
    let reviewForRetirement: Bool
    var id: String { path }
}

enum InventoryBranchCategory: String, CaseIterable {
    case checkedOut, protected, candidate, upstreamReview, unmerged, unknown
}

struct InventoryBranch: Decodable, Identifiable {
    let name: String
    let head: String
    let checkedOut: Bool
    let merged: Bool?
    let upstream: String?
    let upstreamMerged: Bool?
    let upstreamConfigured: Bool?
    let protected: Bool
    var id: String { name }

    var category: InventoryBranchCategory {
        if checkedOut { return .checkedOut }
        if protected { return .protected }
        guard let merged else { return .unknown }
        guard merged else { return .unmerged }
        return upstreamConfigured == false || upstreamMerged == true ? .candidate : .upstreamReview
    }
}

struct InventoryFolder: Decodable, Identifiable {
    let path: String
    let project: String?
    let kind: String
    let reason: String
    var id: String { path }
}

struct InventoryReceipt: Decodable {
    let status: String
    let reason: String
    let restoreCommand: String?
    let record: String?
    let head: String?
    let branch: String?
}

struct InventoryComparison: Decodable {
    let status: String
    let matchedFiles: Int
    let matchedBytes: Int64
    let differences: [String]
    let differenceCount: Int
    let warnings: [String]
    let scope: String
}

private struct InventoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct InventoryReadToken {
    fileprivate let generation: UInt64
    fileprivate let scope: InventoryScope
}

enum InventoryScope { case workspaces, projectIndex }

final class InventoryProcesses {
    private let lock = NSLock()
    private var jobs: [ObjectIdentifier: (process: Process, readScope: InventoryScope?)] = [:]
    private var generations: [InventoryScope: UInt64] = [:]
    private var quitting = false
    private var afterWrites: (() -> Void)?

    func readToken(_ scope: InventoryScope = .workspaces) -> InventoryReadToken {
        lock.lock()
        defer { lock.unlock() }
        return InventoryReadToken(generation: generations[scope, default: 0], scope: scope)
    }

    func check(_ token: InventoryReadToken) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked(token)
    }

    private func checkLocked(_ token: InventoryReadToken?) throws {
        guard !quitting else { throw InventoryError(message: "余白の終了処理中です。") }
        if let token, token.generation != generations[token.scope, default: 0] { throw InventoryError(message: "読み取りを中止しました。") }
    }

    func start(_ process: Process, readToken: InventoryReadToken?) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked(readToken)
        do { try process.run() } catch {
            throw InventoryError(message: "調査機能を起動できません。Xcode Command Line Tools の Python 3 を確認してください。")
        }
        jobs[ObjectIdentifier(process)] = (process, readToken?.scope)
    }

    func finish(_ process: Process) {
        lock.lock()
        jobs.removeValue(forKey: ObjectIdentifier(process))
        let notify = jobs.values.contains(where: { $0.readScope == nil }) ? nil : afterWrites
        if notify != nil { afterWrites = nil }
        lock.unlock()
        if let notify { DispatchQueue.main.async(execute: notify) }
    }

    private func cancelReadsLocked(_ scope: InventoryScope? = nil) {
        if let scope { generations[scope, default: 0] &+= 1 }
        for job in jobs.values where job.readScope != nil && (scope == nil || job.readScope == scope) && job.process.isRunning {
            let pid = job.process.processIdentifier
            guard pid > 1 else { continue }
            // Darwin Foundation launches Process in its own process group. Check ownership
            // before signalling the helper and its Git/inspection children, including
            // helpers blocked on a macOS privacy prompt.
            if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
        }
    }

    func cancelReads() {
        lock.lock()
        defer { lock.unlock() }
        cancelReadsLocked(.workspaces)
    }

    func prepareForQuit(afterWrites: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        quitting = true
        cancelReadsLocked()
        guard jobs.values.contains(where: { $0.readScope == nil }) else { return true }
        if self.afterWrites == nil { self.afterWrites = afterWrites }
        return false
    }
}

// Drain both pipes while the helper is running. Either stream can exceed the pipe buffer.
private final class InventoryDiagnostics {
    private var tail = Data()

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            tail.append(chunk)
            if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
        }
    }

    // Called only after the background drain finishes. Surface the engine's own argument
    // errors (including invalid configuration), not arbitrary subprocess output.
    var message: String? {
        let last = String(decoding: tail, as: UTF8.self).split(whereSeparator: \.isNewline).last ?? ""
        let prefix = "workspaces.py: error: "
        guard last.hasPrefix(prefix) else { return nil }
        return String(last.dropFirst(prefix.count).prefix(500))
    }
}

enum WorkspaceInventory {
    private static let processes = InventoryProcesses()

    static func readToken(_ scope: InventoryScope = .workspaces) -> InventoryReadToken { processes.readToken(scope) }
    static func cancelReads() { processes.cancelReads() }
    static func prepareForQuit(afterWrites: @escaping () -> Void) -> Bool {
        processes.prepareForQuit(afterWrites: afterWrites)
    }

    static func scan(projects: [String] = [], readToken: InventoryReadToken? = nil) throws -> InventoryReport {
        try run(["--json"] + (projects.isEmpty ? ["--configured-only"] : ["--"] + projects),
                accepting: [0, 1], readToken: readToken)
    }

    static func check(project: String, worktree: String, readToken: InventoryReadToken? = nil) throws -> InventoryReceipt {
        try run(["--json", "--check-worktree", worktree, "--", project], accepting: [0, 1], readToken: readToken)
    }

    static func retire(project: String, worktree: String, branch: String, head: String) throws -> InventoryReceipt {
        try run(["--json", "--retire", worktree, "--expect-worktree", branch, head, "--", project],
                accepting: [0, 1], writing: true)
    }

    static func retireBranch(project: String, branch: String, head: String) throws -> InventoryReceipt {
        try run(["--json", "--retire-branch", branch, head, "--", project], accepting: [0, 1], writing: true)
    }

    static func compare(copy: String, keeper: String, readToken: InventoryReadToken? = nil) throws -> InventoryComparison {
        try run(["--json", "--compare", copy, keeper], accepting: [0, 1, 2], readToken: readToken)
    }

    static func run<T: Decodable>(_ arguments: [String], accepting statuses: Set<Int32>,
                                  writing: Bool = false, readToken: InventoryReadToken? = nil,
                                  tracker: InventoryProcesses = processes,
                                  script: URL? = Bundle.main.url(forResource: "workspaces", withExtension: "py", subdirectory: "devpurge/lib"),
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> T {
        let token = writing ? nil : readToken ?? tracker.readToken()
        if let token { try tracker.check(token) }
        guard let script else { throw InventoryError(message: "調査機能が見つかりません。余白を再インストールしてください。") }
        let policy = home.appendingPathComponent(".devpurgerc").path
        var info = stat()
        if lstat(policy, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, access(policy, R_OK) == 0 else {
                throw InventoryError(message: "除外設定 ~/.devpurgerc を通常のファイルとして読み取れません。")
            }
        } else if errno != ENOENT {
            throw InventoryError(message: "除外設定 ~/.devpurgerc の所在を確認できません。")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-E", "-s", "-B", "-S", "-X", "utf8", script.path] + arguments
        process.currentDirectoryURL = home
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try tracker.start(process, readToken: token)
        defer { tracker.finish(process) }
        let diagnostics = InventoryDiagnostics()
        let reader = DispatchWorkItem { diagnostics.drain(errors.fileHandleForReading) }
        DispatchQueue.global(qos: .utility).async(execute: reader)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reader.wait()
        if let token { try tracker.check(token) }
        guard process.terminationReason == .exit, statuses.contains(process.terminationStatus) else {
            if script.lastPathComponent == "project_index.py", let report = try? JSONDecoder().decode([String: String].self, from: data),
               let message = report["error"], !message.isEmpty {
                throw InventoryError(message: String(message.prefix(800)))
            }
            throw InventoryError(message: diagnostics.message ?? "操作の結果を取得できません。案件を再読み込みして状態を確認してください。")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) } catch {
            throw InventoryError(message: diagnostics.message ?? "操作の結果を読み取れません。案件を再読み込みして状態を確認してください。")
        }
    }
}
